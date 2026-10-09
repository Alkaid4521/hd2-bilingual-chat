# 工作原理与维护笔记

本文件记录这个 mod 依赖的游戏内存布局、发送配方，以及游戏更新后该怎么重新定位偏移。
所有偏移都写在 `src/bilingual_chat.lua` 顶部的常量里。

## 1. 用的对象

| 名称 | 位置 | 说明 |
| --- | --- | --- |
| `root` | `*(game.dll + 0x346D538)` | 游戏的主对象指针 |
| `manager` | `root + 0x14498` | 聊天管理器对象 |
| `box` | `manager + 0x16D4` | 聊天输入框：UTF-8、以 `\0` 结尾、容量 0x100 |
| `ring` | `root + 0x4F7080` | 聊天记录环：64 条 × 0x4B4 字节 |
| 环索引 | `ring + 0x12D00` | `{u32 next_index, u32 active}` |
| 单条记录 | `+0x00` 类型（聊天事件 `0x1C12037F`）、`+0x14` 发送者名、`+0xB4` 正文 | |

## 2. 发送配方（就是本 mod 的核心）

```
写 box                     = 译文（UTF-8 + 结尾 \0）
写 manager + 0x139B8 = 1   面板激活状态 → 让聊天面板的每帧更新开始跑
写 manager + 0x1E0F = 1    提交请求
```

随后**游戏自己的代码**完成剩下的事：聊天面板更新（`game.dll+0x0185FFC4`）读 `manager+0x1E0F`、
把它清 0、检查 `manager+0x16D4` 的长度（空或全空格则跳过），然后
`call 0x1097560`，实参 `rcx = *(game.dll+0x347CEF0)+0xC418`、`rdx = 0`、`r8 = 输入框`。
发送后输入框被清空、消息以玩家自己的名义进入聊天环。两个状态字节由游戏自行复位，mod 不需要还原。

**降级路径**：1.5 秒内游戏没有取走（例如游戏更新改了偏移），mod 就把译文留在输入框并记一条
`MSEND failed`——玩家自己按回车照样发得出去。

### 取证记录（发布前实测）

```
聊天环         : 两条记录 type=0x1c12037f，name=<你的玩家名>，body 与写入内容逐字一致
mod 日志       : OWN message ... / MSEND armed state=0x139b8 flag=0x1e0f / MSEND ok sent=1
输入框         : 发送后为空
```

## 3. 试过但走不通的路（不要在它们上面再花时间）

| 路线 | 结果 |
| --- | --- |
| `SendInput`（正确的 40 字节 INPUT） | 返回 2，游戏无反应 |
| `NtUserSendInput` | 返回 `0x2`，无反应 |
| `NtUserPostMessage` WM_CHAR | 返回 `0x1`，无反应 |
| 直接调窗口过程 `WM_KEYDOWN` | 无反应（引擎的按键不走窗口过程） |
| 直接调窗口过程 `WM_CHAR 0x0D` | **仅当聊天面板处于打开状态时**才会提交；关闭时只是重绘输入框 |
| 写 `manager+0x1E0F = 1`（只写这一个） | 无效——消费它的每帧更新当时根本没运行，必须同时置 `0x139B8` |
| 调用每帧更新 `0x0185FFC4` | 会把游戏卡死（它依赖外部状态），**不要盲调大函数** |

结论：合成输入在这款游戏里被反作弊过滤；唯一可行的是**改游戏自己的状态**，让游戏用自己的代码去发。

## 4. 游戏更新后怎么重新定位偏移

1. 让游戏跑起来，用 mod 的调试开关导出内存中解包的镜像：
   `HD2BC_DUMP=1` → `%LOCALAPPDATA%\HD2BilingualChat\img_game.dll.bin`（文件偏移 = RVA）与节表 txt。
   （磁盘上的 `data\game\game.dll` 是加壳的——节名空白、含 `.winlice`/`.vm_sec`，直接反汇编没有意义。）
2. 在镜像里按 4 字节位移粗搜聊天相关的立即数（`0x16D4`、`0x14498`、`0x4F7080`、`0x347CEF0`），
   再用 PE 异常目录（`.pdata`）给出的函数表做对齐校验，避免落在指令中间的假命中。
3. 找到读 `[rdi+0x1E0F]` 并调用发送函数的那段，就是 `0x0185FFC4` 的角色；它前面读写的
   `manager+0x139B8` 就是新的面板状态字节。
4. 改 `src/bilingual_chat.lua` 顶部常量，重打包。

## 5. 调试开关（默认关闭）

| 变量 | 作用 |
| --- | --- |
| `HD2BC_WORKBENCH=1` | 监听 `%LOCALAPPDATA%\HD2BilingualChat\cmd.txt`，每 0.25 秒执行一行：`status`、`hex <off> <len>`、`box <text>`、`cr`、`set <off> <byte>`、`submit <text>`、`scan <s>`、`rank`、`mods`、`dumpimg`、`call <rva>`、`call3 <rva> <rcx> <rdx> <r8>`、`sendbox <text>`；答案写进日志 |
| `HD2BC_DUMP=1` | 启动时把内存中解包的 game.dll 镜像写到上面那个目录（约 75 MB） |

这两个开关能调用任意游戏函数、写任意内存，**可能让游戏崩溃，仅供开发排查**，公开发行版默认关闭。

## 6. 与 `hd2-chat-translate` 共存的补丁

`hd2-chat-translate` 原本对正文没有任何过滤，会把本 mod 发出的 `[EN] ...` 再翻回中文。
修法是在它的 `game/chat_translate_core.lua` 里加一段：

```lua
local TRANSLATION_ECHO_PREFIXES = { "[EN]", "[CN]" }
local function is_translation_echo(text)
    if type(text) ~= "string" then return false end
    for index = 1, #TRANSLATION_ECHO_PREFIXES do
        local prefix = TRANSLATION_ECHO_PREFIXES[index]
        if text:sub(1, #prefix) == prefix then return true end
    end
    return false
end
```

然后把 `scan_slots()` 里 `if pending and same_identity(pending.message, message) then` 改成：

```lua
if is_translation_echo(message.body) then
    if pending then finish_item(state, pending) end
    mark_seen(state, message)
    bump(state, "skipped_translation_echo")
elseif pending and same_identity(pending.message, message) then
```

并在 `COUNTER_NAMES` 里加上 `"skipped_translation_echo"`（`bump` 对未登记的名字是静默忽略，不加也能跑，
只是清单里看不到计数）。

改完必须重新打包，两条路：

**1. 首选：跑插件自带的 `tools/build_package.py`**，它会把下面所有长度自己算好。

**2. 只改游戏 `data` 目录里那份已部署的补丁**时，必须同步**三处**长度，漏一处会让整个插件
**静默失效**——加载器按 TOC 声明的长度读取，会把 Lua 源码尾部截掉，编译不过，插件一行都不执行、
连日志都不会有：

| 位置 | 含义 | 必须等于 |
| --- | --- | --- |
| 源码起点前方 8 字节 | 资源信封 `u32 source_len, u32 kind=2` | 源码字节数 |
| TOC 条目起点 + 56 | 该资源的 `resource_len` | 源码字节数 + 8 |
| 容器 `+0x20` | 容器总长 | 文件实际长度 |

实测（2026-10-07）：源码加了 779 字节，只更新了信封与容器总长、漏掉 TOC 那处，插件自那次 Deploy 之后完全没反应——
`%LOCALAPPDATA%\HD2ChatTranslate\mailbox\*.json` 与 `probe\*.json` 都不再更新，游戏内也看不到任何翻译。
`tools/fix_archive_toc.py <archive>` 能幂等地把三处长度对齐并复核，比手改安全。

验证要**按 TOC 声明的长度**抽资源再编译（`b[i+8 : i+resource_len]`），**不要一直抽到文件尾**：
抽到文件尾会把被截断的余量也读进来，看着是好的，而加载器只读 TOC 那么多。

⚠️ 只改 `data\` 那份，只在不再 Deploy 的前提下有效：Arsenal 下次 Deploy 会用它库里的副本
（`...\hd2arsenal\mods\<mod>\Addon\...patch_0`）覆盖回去。要么连库里那份一起改，
要么就用路线 1 出个新包重新导入。

> 上面引用的那一行 `elseif ... same_identity(...)` 是对方文件里的**定位锚点**
> （GPL-3.0-only，引自 [furina2233/hd2-chat-translate](https://github.com/furina2233/hd2-chat-translate)），
> 其余几行是本 mod 作者写的补丁。本 mod 与该插件没有隶属关系，也不包含、不分发它的代码；
> 改好的插件包请只自用——转发它属于按 GPL-3.0 传播修改后的第三方作品。

## 7. 入站翻译：把译文写在别人那一行下面（1.1.0）

只改本机显示，不广播、不写游戏文件。开关 `HD2BC_INBOUND`：`on`（默认，写入）/ `probe`（只读）/ `off`。

### 7.1 用到的对象

| 名称 | 位置 | 说明 |
| --- | --- | --- |
| 控件槽 | `manager + 0x4390` 起，64 个，步长 `0x3D8` | 每个槽对应聊天窗的一行 |
| 属性表 | 槽内 `+0x220` | 表内计数在 `+0x158`（**游戏按单字节读**），条目从 `+8` 起、每项 `0x18` 字节 |
| 正文属性 key | `0x7518C954` | 条目 +0 是 key、+8 是类型、`+0x10` 是字符串指针 |
| 正文 setter | `game.dll+0x1441CA0` | 前 12 字节是 `push rbx; sub rsp,0x20; mov rbx,rcx; add rcx,0x110`，与「第一参数用槽 +0x110」一致 |
| 字符串 setter | `game.dll+0x143A1B0` | 入口就有 `movzx r11d, byte [rcx+0x158]`——表内计数偏移的独立佐证 |
| 布局指纹 | `game.dll+0x1860C49` | `lea r8,[rbx+0xB4]; mov edx,0x7518C954; mov rcx,rsi; call`：**游戏自己也用环项的 +0xB4 当字符串指针** |

最后一行是整套做法的依据：控件行的正文属性和聊天环里那条记录是**同一个缓冲区**，
所以「行 ↔ 记录」只要比指针就够，不需要假设两者同索引。

### 7.2 怎么做

1. `ring_step` 里原本只认自己的话（`typed` 与环内正文相同者）。现在多一个 `else`：
   发送者名不等于学到的本机名、正文不是中文、不是 `[EN]`/`[CN]` 回显、也没见过 → 入队。
2. 队列最多 4 条、60 秒过期，条数上限 `HD2BC_INBOUND_MAX`（默认 0＝不限；旧版硬编码 12 条，超了会
   **静默**不再翻译），并且**与出站翻译共用同一条传输通道**（同一时刻只有一个请求在飞）；请求复用
   `request_body`，目标语言写死简体中文。
3. 拿到译文后按 `find_slot_for(环索引, 本行缓冲区指针)` 找行：读 64 个槽的属性表，取 `0x7518C954`
   的指针，与 `ring + (index%64)*0x4B4 + 0xB4` **或我们已经写进这一行的缓冲地址**比较（见 7.3）；
   同时把「槽 → 它当前指向的环索引」的映射打进日志（`INBOUND probe ... map=0>3 1>4 ...`），
   一眼能看出行与记录的对齐关系。
4. `probe` 到此为止；`on` 才把正文复制进一个**按环索引长期持有的 FFI 缓冲**（游戏借用该指针，所以
   不能回收），调用 setter，然后再读一次属性确认指针已经换成我们的缓冲。`write_inbound(index, blob, kind)`
   的 `kind` 是 `placeholder` / `final` / `revert`，三种写入共用同一条路径，只是统计与日志不同。

### 7.3 行高与"写过之后指针不再指向环"

- 行高（`+0x10`）必须相对**我们写入之前的高度**计算：占位符先写一次就是两行（17.0 → 34.0），答案回来
  再写一次，如果此时按"当前高度 × 行数"算就会变成 68.0。所以每个环索引记一份 `in_base_h`，撤回时用它
  恢复原高度。
- **行一旦被写过，它的正文属性就指向我们的缓冲、不再等于环里的地址**，纯按环指针找行会失败（表现是译文
  永远停在 `译文：…`）。因此查找同时接受"该索引的缓冲地址"，并且这个替代值本身就是校验：只有我们写过
  的那一行才可能命中。
- **仍然不做重排**：不移动后续行的位置，也不调用游戏的布局函数（`+0x18610C0` / `+0x1860DA0`，参数未定）。
  现在只保证这一行自己高度正确、不叠到下一行；上游那份实现为此写了一整套测量与重排
  （它还记录了 `纵向缩放 +0x20`、`位置缓存 +0x3CC`）。要试调就用 `HD2BC_WORKBENCH=1` 的 `call3`。

### 7.4 翻译通道：三层（1.2.0）

一条消息端到端原来是 ~1.2 秒，量清楚之后分三层改（数字见 README 的 1.2.0 表）：

1. **请求体关掉思考**：`thinking:{type:"disabled"}` + `reasoning_effort:"none"`。这是最大的一块——
   译文只有 1 个 token，推理却烧掉 95–184 个。`HD2BC_THINKING=on` 可还原。
2. **常驻助手进程**（`helper/hd2bc_helper.js`，由 mod 在 ARM 时用 `CreateProcessW` 起一次）：整个会话
   一个 `https.Agent({keepAlive:true})`。mod ↔ 助手只做文件交换：
   `job.tmp` →（`MoveFileExW` 改名）→ `job.json`（发布即原子，助手永远读不到半个文件）→ 助手写
   `raw.txt` + `out.txt`（含 `id=` / `ms=` / `reused=`）。**id 里带游戏进程 pid**，所以上一局残留的
   `out.txt` 不会被当成这一局的答案；`reused=1` 就是连接复用的证据。助手在父进程消失或空置超时后自杀。
   `MoveFileExW` 用 `GetProcAddress` 取指针（不往共享 cdef 里加声明）。找不到 node → 自动回 curl。
3. **占位符**：`consider_inbound` 里入队的同时就写一次 `原文 + "\n译文：…"`，答案回来替换；失败、超时、
   过期一律 `revert_inbound` 把整行（含行高）恢复。首次写入可能撞上"行还没排出来"，此时进 `in_pending`，
   每 0.2 秒重试一次直到成功。

迭代方式：`HD2BC_WORKBENCH=1` 打开后，`%LOCALAPPDATA%\HD2BilingualChat\cmd.txt` 里写一行就在游戏内执行
（`hex` 看内存、`call3` 试调函数、`scan`/`rank` 找变化的字节），答案回到日志——不用改代码、不用重启。
