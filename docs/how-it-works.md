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
聊天环         : 两条记录 type=0x1c12037f，name=Alkaid摇光，body 与写入内容逐字一致
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
