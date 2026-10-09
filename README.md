# Bilingual Chat for Helldivers 2 · 绝地潜兵 2 双语聊天

发一条中文，约一秒后英文译文作为**第二条真实聊天消息**自动发出——队友同样看得见，你一个多余的键都不用按。

```
你：       前方有敌人
你：[EN]   Enemies ahead!
```

第二行是 mod 自动发出去的，署名和你自己的消息相同（走的正是游戏自己的发送流程）。

## 它是怎么做到的

mod 把译文写进游戏的聊天输入框，然后把游戏内部「聊天面板激活」和「提交」这两个状态字节置 1。
游戏自己的聊天代码随即取走输入框内容、调用它自己的发送函数、清空输入框——也就是**按回车实际做的事**。
全程**没有任何按键注入**（SendInput / PostMessage 这类合成输入会被反作弊过滤，那条路走不通），
所以既不会被拦，也不会掉帧；译文由一个独立的常驻助手进程请求，渲染线程不被阻塞。

## 1.2.0：把「翻译队友消息」这条链路重做了一遍

原来一条消息端到端约 1.2 秒。拆开量，是三个来源，就分别修了三层：

| 来源 | 实测 | 处置 |
| --- | --- | --- |
| **模型在推理**：译文只有 1 个 token，却先烧掉 95–184 个 reasoning token | "hello" 1070 ms / 95 token；一整句 1491 ms / 184 token | 请求里关掉思考（`thinking:{type:"disabled"}` + `reasoning_effort:"none"`），同样两条降到 **496 / 455 ms，1 / 10 token** |
| **每条消息新起 `curl.exe` + 新建 TLS**（到服务器的实测：冷启 285 ms，复用连接 67–88 ms） | 约 200 ms | 改成**一个常驻助手进程**（`node`，脚本 `helper/hd2bc_helper.js`）：整个游戏会话只建立一个连接，之后每条消息都复用它 |
| **那一行要等结果回来才变** | 体感 = 整段延迟 | 消息一被发现就先在那行写上 `译文：…`，答案回来替换；失败或超时就**撤回**，整行恢复原样 |

助手进程在游戏进程之外，只做文件交换：mod 写 `%LOCALAPPDATA%\HD2BilingualChat\helper\job.json`
（先写 `.tmp` 再改名，避免对方读到半个文件），助手把响应原样写进 `raw.txt`，并在 `out.txt` 里带上
`ms=` / `reused=`。日志中的 `HELPER answered ms=… reused=1` 就是"连接确实被复用"的证据。

**没装 node 也不会坏**：找不到 `node.exe`、助手退出、或显式 `HD2BC_TRANSPORT=curl`，都会自动回到
1.1.0 的 curl 路线，只是慢一点。另外 `HD2BC_INBOUND_MAX` 原来的 12 条上限（静默不再翻译）已改成默认无上限。

## 1.3.0：把「卡顿」量出来，再把游戏线程上的开销砍掉

先说结论：这条链路的**纯 Lua 部分不可能卡**。热点都在游戏自带的 `lua51.dll`（LuaJIT 2.1）上实测过
（`tmp/bench_hot.lua` + `tmp/run_lua.py`）：整行定位 `find_slot_for`（扫 64 个控件槽）**36 µs**，
单槽扫描 0.5 µs，`text()` 0.5 µs、`json_escape(200 B)` 3 µs。每次写入的 Lua 成本在 0.1 ms 量级，
掉不了帧。真会掉帧的是另外两类：

| 来源 | 证据 | 处置 |
| --- | --- | --- |
| **每次请求都新起一个 `curl.exe`**（`CreateProcessW` 在游戏线程上，还要重建 TLS） | 2026-10-08 那局日志：助手在 t=900 s 空闲退出，之后**每条**消息都是 `lane=curl` | 助手活着或正在启动时**只用助手**：请求进队列等它就绪（日志 `INBOUND deferred … reason=helper_booting`），只有"根本没有助手"（没 node、重启次数用完）才回退 curl |
| **每帧的文件 I/O** | `out.txt` 原来每帧开/读/关一次（≈60 次/秒），助手启动期 `helper.ready` 也是每帧测一次 | 都改成定频轮询（12 Hz / 10 Hz）；答案本来就要几百毫秒，肉眼看不出差别 |

写入路径还少了一次全槽扫描：记住这一行上次所在的槽，重写时只校验那一个槽（**1 次** `ReadProcessMemory`
而不是 64 次），值对不上就退回全扫。

**留了一个测量口**，用来判断剩下的开销在谁身上。游戏每帧调一次 `_G.update`，所以「进钩子到出钩子」是
本 mod 的成本，「出钩子到下一帧进钩子」是游戏自己的成本——它的聊天面板重排就落在后一段：

```
t=... PERF 10s frames=601 ours_max=1ms p99~4ms slow=0 game_max=41ms slow=3 tag=set:final
```

超过 20 ms 的帧单独打一行 `PERF ours=` / `PERF game=` 并带上该帧做过什么（`set:final` /
`set:placeholder` / `stage` / `answer` / `curl_spawn`），`HD2BC_PERF=0` 关掉。
于是"那一行的重排到底贵不贵"可以被直接读到：看 `tag=set:final` 的 `PERF game=` 是多少。
现成的 A/B 是 `HD2BC_INBOUND_PLACEHOLDER=0`（不再写"译文：…"占位，每条消息少一次重排）。

## 1.1.0：别人说的话也翻，显示在原话下面（只改本机显示）

队友发来非中文的一行，mod 把它翻成中文，追在**那一行下面**——只有你看到，不广播、不改游戏文件：

```
队友：   for democracy
        译文：为了民主
```

- 行的定位不靠索引：拿 64 个 UI 控件槽，逐个读它的属性表（表在槽 +0x220，表内计数在 +0x158，
  条目从 +8 起、每项 0x18 字节），找正文属性（key `0x7518C954`）的字符串指针**等于**聊天环里那条记录的
  正文地址（环项 +0xB4）。指针不匹配就什么都不做。
- `HD2BC_INBOUND` 默认 **`on`**：直接调用游戏的正文 setter 把译文写进那一行。想只看不动，设成 `probe`。
- 你自己的话、`[EN]`/`[CN]` 回显、以及**本来就是中文**的行都不会送去做请求（后者以前会白跑一次 API）。
- 写入前会核对一段代码指纹（`game.dll+0x1860C49` 处 `lea r8,[rbx+0xB4]; mov edx,0x7518C954; call`），
  对不上就拒绝写入——游戏更新挪了布局时不会瞎写内存。

## 安装

1. 先装 **Bingus Shared Loader**（本 mod 依赖它的 Lua 加载器）：<https://github.com/CowboyBingus/BingusSharedLoader>
2. 用 **Arsenal**（HD2 的 mod 管理器）导入 `dist/BilingualChat9-1.3.0.zip`，然后 Deploy。
3. 安装前请删掉同类的旧包（例如 `mods/dsh/bilingual_chat*`），避免两个 mod 抢同一个输入框。
4. 启动游戏，日志 `%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\HD2BilingualChat9.log`
   第一行应出现 `START version=1.3.0`。

## 配置（用户级环境变量，`HKCU\Environment`）

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `HD2CT_API_URL` | `https://api.deepseek.com/v1` | OpenAI 兼容端点（会请求 `/chat/completions`） |
| `HD2CT_MODEL` | `deepseek-chat` | 模型名 |
| `HD2CT_API_KEY` | — | **必填**。只写进 curl 的配置文件与助手的 `helper.cfg`，不会出现在命令行上 |
| `HD2BC_MODE` | `mem` | `mem` 全自动 / `prefill` 只把译文填进输入框、由你按回车 / `auto` 旧的注入路线 / `dry` 只翻译不发 / `off` 关闭 |
| `HD2BC_PREFIX` | `auto` | 译文前缀。`auto`＝中文源加 `[EN] `、英文源加 `[CN] `；`0` 不加；也可写成任意字面量 |
| `HD2BC_TRANSPORT` | `auto` | `auto`＝有 `node.exe` 就用常驻助手、否则 curl；`curl` 强制老路线；`dll` 是可选的实验路线 |
| `HD2BC_THINKING` | `off` | `on` 恢复带推理的请求体（更慢、更贵，只有在端点不认识那两个字段时才设） |
| `HD2BC_INBOUND` | `on` | 入站翻译：`on` 写入本机显示 / `probe` 只报告不写入 / `off` 关闭 |
| `HD2BC_INBOUND_LABEL` | `译文：` | 译文前面那截文字（实际会先换行） |
| `HD2BC_INBOUND_PLACEHOLDER` | `on` | `0` 关闭"先写 `译文：…` 占位、再替换"这一步 |
| `HD2BC_INBOUND_MAX` | `0` | 最多翻多少条，`0`＝不限（旧版硬编码 12 条，超过后静默不再翻译） |
| `HD2BC_INBOUND_ARG` | `0x110` | 传给正文 setter 的第一个参数相对控件槽的偏移；万一布局变了可用 `0`/`0x110` 对调排查 |
| `HD2BC_INBOUND_HEIGHT` | `on` | `0` 关闭写那一行的高度。高度必须写（否则第二行被裁），但它是**额外一次游戏侧重排**，卡顿敏感时可以拿它做实验 |
| `HD2BC_INBOUND_SELF` | — | `1` 打开自测：把自己说的话也当入站消息写一次译文（调试用，正常别开） |
| `HD2BC_HELPER_IDLE` | `900000` | 助手空置多少毫秒后自行退出（游戏关了它也不会留在后台） |
| `HD2BC_HELPER_WARM` | `1` | `0` 关闭助手每 45 秒一次的保活请求（`/models`，不消耗 token） |
| `HD2BC_PERF` | `on` | 帧预算探针：超过阈值（默认 20 ms）的帧打一行 `PERF ours=`/`PERF game=`，每 10 秒一行汇总；`0` 完全关闭 |
| `HD2BC_PERF_SLOW` | `0.020` | 探针单帧阈值（秒） |
| `HD2BC_PERF_EVERY` | `10.0` | 探针汇总间隔（秒） |
| `HD2BC_WORKBENCH` | — | `1` 打开 `cmd.txt` 调试台（开发用） |
| `HD2BC_DUMP` | — | `1` 启动时把内存里的 game.dll 镜像写到 `%LOCALAPPDATA%\HD2BilingualChat`（约 75 MB） |

设置后重启游戏生效（环境变量在进程启动时读取）。

## 与「HD2 Chat Translate」这类翻译插件共存

**1.1.0 起不再是必需的**：入站翻译（别人说的话 → 本机显示译文）现在由本 mod 自己做，而且不走进程内原生
模块、不在游戏里跑 WinHTTP。不装那个插件，功能一样齐；装了也不冲突，只要让它跳过 `[EN]` / `[CN]` 前缀
（它原本没有过滤，会把本 mod 发出的译文再翻一次，做法见 `docs/how-it-works.md` 末尾）。

本 mod 与 `hd2-chat-translate` **没有隶属关系**：本仓库不包含、也不分发它的任何代码或资源，那段做法是要你在
**自己那份**上改。该插件是 GPL-3.0-only（见[上游仓库](https://github.com/furina2233/hd2-chat-translate)），
所以**打好补丁的插件包请只自用、不要转发**——转发修改后的 GPL 作品，要按 GPL-3.0 一并提供源码与许可。

## 已知限制

- 需要联网与可用的模型额度；每条消息一次请求，端到端约 0.3–0.6 秒（不入队排队时；第一条约 0.6 秒）。
- 游戏大版本更新可能移动那几个内存偏移。此时 mod 会自动退化成
  「译文留在输入框，你自己按回车」——**只会降级，不会失效**，日志里会出现 `MSEND failed`。
  偏移量在 `src/bilingual_chat.lua` 顶部（`PANEL_STATE_OFFSET` / `SUBMIT_FLAG_OFFSET` /
  `MANAGER_OFFSET` / `INPUT_OFFSET` / `ROOT_GLOBAL_A`），重新定位的方法见 `docs/how-it-works.md`。
- 只在 Windows + 官方反作弊环境下测试过；本 mod 不做任何绕过反作弊的动作，也不会修改游戏文件。

## 常见问题

**日志在哪、怎么确认装上了。** `%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\HD2BilingualChat9.log`，
第一行是 `START version=…`（版本自证），随后 `ARMED mode=mem …`。若第一行是 `ERROR=BSL_API_1_REQUIRED`，
说明没装 Bingus Shared Loader（或版本不匹配）。

**没反应、什么都没发生。** 依次看：
`HELPER ready in 0.29s`（助手起来了；没有则看 `HELPER never reported ready` 或 `CURL config missing`）、
`OWN message name="…"`（它认出了你自己的发言）、`TRANSLATE ok …`（翻译回来了）、
`MSEND ok sent=…`（游戏真的取走了输入框并发出）。任意一步缺失都能一眼看出断在哪。

**译文留在输入框里没发出去。** 日志出现 `MSEND failed`：游戏没在那 1.5 秒内消费状态字节（多半是游戏大版本
更新挪了偏移），此时是**降级**不是失效——按一下回车就能发。重新定位偏移的方法见 `docs/how-it-works.md`。

**开局第一次翻译特别慢。** 第一条要建连接（冷启约 285 ms）；之后 `HELPER answered ms=… reused=1`
就是复用证据。没装 node 会退回每条新起 `curl.exe`，慢且每条都要重建 TLS。

**打起来卡顿。** 看日志里的 `PERF` 行：`PERF game=… tag=set:final` 是**游戏自己**为重排那一行花的时间，
`PERF ours=…` 才是本 mod 的开销。1.3.0 起本 mod 在游戏线程上不再起任何进程、也不再每帧碰文件；
若 `tag=set:placeholder` 的那条偏贵，用 `HD2BC_INBOUND_PLACEHOLDER=0` 关掉占位行做 A/B。

**换模型/换端点。** `HD2CT_API_URL` 要填到 `/v1` 那一层（插件会自己拼 `/chat/completions`）；
改完必须**完全重启游戏**（环境变量只在进程启动时读一次）。

## 开发

```bash
python tools/lua_syntax_check.py src/bilingual_chat.lua      # 用游戏自带的 bin/lua51.dll 做编译检查
python tests/mem_send_test.py          # 离线自测：假游戏消费那两个状态字节，覆盖成功与降级两条路径
python tests/inbound_probe_test.py     # 离线自测：假 UI 里摆一张属性表，验证按指针找到那一行、且 probe 不写入
python tools/embed_helper.py           # 把 helper/hd2bc_helper.js 灌进 Lua 长串（--check 只比对，装机时自动跑）
python tools/helper_offline_test.ps1   # 游戏外实测：常驻助手 vs curl 的端到端延迟与 reused 复用证据
python tools/thinking_bench.js <key> <url>   # 量各请求形态的 reasoning token 与耗时（改提示词前先跑它）
python tools/verify_offsets.py         # 用内存里的 game.dll 镜像核对全部 RVA 与指纹常量
python tools/make_manifest.py          # 重生成 MANIFEST.sha256（发版前跑，再一起提交）
python tools/install_live.py --dry     # 打包 + 装进 Arsenal 库与游戏槽位（--dry 只演练）
python tools/pack_addon.py --src src/bilingual_chat.lua --path mods/<you>/bilingual_chat \
       --name "Bilingual Chat" --guid <uuid> --version 1.3.0 --delivery BilingualChat \
       --rewrite-header              # 同一份源码换 Arsenal 身份：重写第一行而不是要求它匹配
```

## 目录

| 路径 | 内容 |
| --- | --- |
| `src/bilingual_chat.lua` | 全部逻辑（Lua，跑在游戏进程内的 LuaJIT 里） |
| `helper/hd2bc_helper.js` | 常驻助手进程（keep-alive 连接）；装机时由 `tools/embed_helper.py` 灌进 Lua 长串 |
| `tools/` | 打包器、编译检查、延迟实测脚本 |
| `tests/` | 离线自测（不需要开游戏） |
| `docs/how-it-works.md` | 内存布局、发送配方、取证记录、调试开关 |
| `CHANGELOG.md` | 每个版本改了什么、量到了什么 |
| `dist/` | 分发包（同时挂在 Release 上） |

## License

MIT，见 `LICENSE`。

第三方：运行依赖 [Bingus Shared Loader](https://github.com/CowboyBingus/BingusSharedLoader)（不随本 mod 分发）。
`template/patch_header.template` 只是 200 字节的容器格式头（魔数、类型 id、长度字段），不含任何第三方代码或文本；
其中标识用的 file id 字段在仓库里已归零——打包时本来就会被覆盖，构建产物逐字节不变。

---

### English

**Bilingual Chat for Helldivers 2** — your own chat line goes out untouched; about a second later the
translation is sent as a *second real chat message*, so teammates can read it too, and you press nothing.

The mod hands the text to the game's own send routine: it writes the translation into the chat input box
and sets the two state bytes (panel-active + submit) that the chat panel update consumes. No synthetic
input is used — `SendInput`/`PostMessage` are filtered by the anti-cheat and do not work here. Translation
runs outside the game process, so the render thread never blocks.

Since 1.1.0 it also does the other direction: a teammate's non-Chinese line gets a translation written
under it *in this client only*. The row is found by matching the body property's string pointer against
the ring record, never by guessing an index.

Since 1.2.0 the lane itself was rebuilt: thinking is switched off in the request (measured: 95 reasoning
tokens / 1070 ms before, 1 token / 496 ms after), one long-lived helper process (`node`, keep-alive)
replaces a `curl.exe` per line, and the row says "translating…" immediately and is reverted if the answer
never comes. No node on the machine simply falls back to curl.

Since 1.3.0 the game thread never spawns a process (a request that finds the helper booting is queued
instead) and no longer touches a file every frame; the row lookup validates one cached widget slot
instead of scanning all 64. A frame-budget probe (`PERF …`) separates this mod's cost from the game's own
row-relayout cost, which is what the remaining stutter, if any, turns out to be. See `CHANGELOG.md`.

Install: Bingus Shared Loader + Arsenal, import `dist/BilingualChat9-1.3.0.zip`, Deploy. Configure
`HD2CT_API_URL`, `HD2CT_MODEL`, `HD2CT_API_KEY` in your user environment. See `docs/how-it-works.md`
for the memory layout and the fallback behaviour after a game update (MIT licensed).
