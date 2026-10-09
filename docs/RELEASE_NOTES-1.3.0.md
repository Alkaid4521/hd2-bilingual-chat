# Bilingual Chat 1.3.0

发一条中文，约一秒后英文译文作为**第二条真实聊天消息**自动发出；队友发来的非中文发言，会在这台机器的
聊天窗里、原话下面追一行中文。全程不需要按任何多余的键，也不做任何按键注入。

## 这个版本改了什么

**一句话：把"卡顿"量清楚，然后把游戏线程上的开销砍掉。**

先排除掉"Lua 慢"这个猜测——用**游戏自带**的 `bin\lua51.dll`（就是跑本 mod 的那个 LuaJIT）离线实测：

| 操作 | 实测 |
| --- | --- |
| 扫 64 个控件槽定位那一行 | **36 µs** |
| 单槽扫描 / 246 次 `u32` 循环 | 0.5 / 0.4 µs |
| `text(200 B)` / `json_escape(200 B)` | 0.5 / 3.1 µs |

每次回写的 Lua 成本在 0.1 ms 量级，掉不了帧。真会冻结游戏线程的是另外两件事，这个版本都修了：

1. **游戏线程上不再新起进程。** 之前助手进程一旦退出，每条消息都会在游戏线程上 `CreateProcessW` 一个
   `curl.exe`（外加一次全新的 TLS 握手）。现在助手活着或正在启动时**只用助手**，请求排队等它就绪
   （日志：`INBOUND deferred … reason=helper_booting`）；只有「没装 node / 助手重启次数用完 /
   显式 `HD2BC_TRANSPORT=curl`」才回退 curl。
2. **不再每帧碰文件。** `out.txt` 从每帧开/读/关一次（≈60 次/秒）改成 12 Hz；助手启动期的 `helper.ready`
   探测改成 10 Hz。答案本来就要几百毫秒，肉眼看不出来。

外加两处：行定位记住上一行所在的控件槽，重写时只校验那一个槽（1 次 `ReadProcessMemory` 而不是 64 次）；
新增**帧预算探针**，把"本 mod 的开销"和"游戏自己重排聊天面板的开销"分开报出来。

## 安装

1. 先装 **[Bingus Shared Loader](https://github.com/CowboyBingus/BingusSharedLoader)**（本 mod 依赖它的 Lua 加载器）。
2. 用 **Arsenal** 导入本 Release 附件 `BilingualChat9-1.3.0.zip`，然后 Deploy。
3. 装之前删掉同类旧包（例如 `mods/dsh/bilingual_chat*`），避免两个 mod 抢同一个输入框。
4. 配置三项用户级环境变量（`HKCU\Environment`，改完要**完全重启游戏**）：

| 变量 | 例子 |
| --- | --- |
| `HD2CT_API_URL` | `https://api.deepseek.com/v1`（OpenAI 兼容端点，插件自己拼 `/chat/completions`） |
| `HD2CT_MODEL` | `deepseek-chat` |
| `HD2CT_API_KEY` | 你的 key（只写进 curl 的配置文件和助手的 `helper.cfg`，不会出现在命令行上） |

可选：装 Node.js 会用上常驻助手（快）；没有也行，会自动退回 curl，只是每条都要重建连接。

## 装完怎么确认

日志：`%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\HD2BilingualChat9.log`

```
START version=1.3.0 …
ARMED mode=mem prefix=auto transport=auto tid=…
HELPER ready in 0.29s
OWN message name="…"
TRANSLATE ok tag=CN len=…
MSEND ok sent=1 …
```

要看的反面信号：`ERROR=BSL_API_1_REQUIRED`（没装 loader）、`MSEND failed`（游戏没消费状态字节，
此时是降级——译文留在输入框，按回车即可）、`HELPER never reported ready`（退回 curl）。

## 帧预算探针（新）

游戏每帧调一次 `_G.update`，所以「进钩子→出钩子」是本 mod 的开销，「出钩子→下一帧进钩子」是游戏自己的
开销。超阈值（默认 20 ms）的帧会打一行并带上该帧做过什么：

```
t=… PERF game=38ms tag=set:final        ← 这 38 ms 花在游戏重排那一行上，不是本 mod
t=… PERF 10s frames=601 ours_max=1ms p99~4ms slow=0 game_max=41ms slow=3 tag=set:final
```

`HD2BC_PERF=0` 关闭。怀疑占位行（`tag=set:placeholder`）偏贵时，用 `HD2BC_INBOUND_PLACEHOLDER=0` 做 A/B。

## 已知限制

- 需要联网与可用的模型额度；每条消息一次请求，端到端约 0.3–0.6 秒。
- 游戏大版本更新可能移动内存偏移。此时会自动降级成「译文留在输入框，你自己按回车」——
  **只降级，不失效**，日志出现 `MSEND failed`。
- 只在 Windows + 官方反作弊环境下测试过；不绕过反作弊，也不修改游戏文件。

## 校验

- 构建产物：本 Release 附件与仓库 `dist/BilingualChat9-1.3.0.zip` 同源同哈希。
- 离线自测：`tests/inbound_probe_test.py` 7/7、`tests/mem_send_test.py` 10/10、
  `tests/perf_probe_test.py`（直接加载构建产物验证探针）。
- 装机自检：`python tools/install_live.py --dry`（打包 + 校验 TOC 长度与 Lua 编译）。

MIT 许可，见 `LICENSE`。运行依赖 [Bingus Shared Loader](https://github.com/CowboyBingus/BingusSharedLoader)
（不随本 mod 分发）。与 `hd2-chat-translate` 等第三方翻译插件没有隶属关系，仓库不包含其任何代码或资源。
