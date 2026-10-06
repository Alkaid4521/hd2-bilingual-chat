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
所以既不会被拦，也不会掉帧；译文由独立的 `curl.exe` 子进程请求，渲染线程不被阻塞。

## 安装

1. 先装 **Bingus Shared Loader**（本 mod 依赖它的 Lua 加载器）：<https://github.com/CowboyBingus/BingusSharedLoader>
2. 用 **Arsenal**（HD2 的 mod 管理器）导入 `dist/BilingualChat-1.0.0.zip`，然后 Deploy。
3. 安装前请删掉同类的旧包（例如 `mods/dsh/bilingual_chat*`），避免两个 mod 抢同一个输入框。
4. 启动游戏，日志 `%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\HD2BilingualChat.log`
   第一行应出现 `START version=1.0.0 addon=mods/alkaid/bilingual_chat`。

## 配置（用户级环境变量，`HKCU\Environment`）

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `HD2CT_API_URL` | `https://api.deepseek.com/v1` | OpenAI 兼容端点（会请求 `/chat/completions`） |
| `HD2CT_MODEL` | `deepseek-chat` | 模型名 |
| `HD2CT_API_KEY` | — | **必填**。只写进 curl 的配置文件，不会出现在命令行上 |
| `HD2BC_MODE` | `mem` | `mem` 全自动 / `prefill` 只把译文填进输入框、由你按回车 / `auto` 旧的注入路线 / `dry` 只翻译不发 / `off` 关闭 |
| `HD2BC_PREFIX` | `auto` | 译文前缀。`auto`＝中文源加 `[EN] `、英文源加 `[CN] `；`0` 不加；也可写成任意字面量 |
| `HD2BC_TRANSPORT` | `curl` | 翻译在独立 `curl.exe` 里跑；`dll` 是可选的实验路线 |

设置后重启游戏生效（环境变量在进程启动时读取）。

## 与「HD2 Chat Translate」这类翻译插件共存

本 mod 发出的译文带 `[EN]` / `[CN]` 前缀。如果你还装了会把英文消息自动翻成中文的插件，请让它跳过这两个前缀，
否则译文会被再翻一次、聊天里层层叠加。给 `hd2-chat-translate` 打补丁的做法见 `docs/how-it-works.md` 末尾。

## 已知限制

- 需要联网与可用的模型额度；每条消息一次请求，端到端约 0.6–1.5 秒。
- 游戏大版本更新可能移动那几个内存偏移。此时 mod 会自动退化成
  「译文留在输入框，你自己按回车」——**只会降级，不会失效**，日志里会出现 `MSEND failed`。
  偏移量在 `src/bilingual_chat.lua` 顶部（`PANEL_STATE_OFFSET` / `SUBMIT_FLAG_OFFSET` /
  `MANAGER_OFFSET` / `INPUT_OFFSET` / `ROOT_GLOBAL_A`），重新定位的方法见 `docs/how-it-works.md`。
- 只在 Windows + 官方反作弊环境下测试过；本 mod 不做任何绕过反作弊的动作，也不会修改游戏文件。

## 开发

```bash
python tools/lua_syntax_check.py     # 用游戏自带的 bin/lua51.dll 做编译检查
python tests/mem_send_test.py        # 离线自测：假游戏会消费那两个状态字节，覆盖成功与降级两条路径
python tools/pack_addon.py --src src/bilingual_chat.lua --path mods/<you>/bilingual_chat \
       --name "Bilingual Chat" --guid <uuid> --version 1.0.0 --delivery BilingualChat
```

## 目录

| 路径 | 内容 |
| --- | --- |
| `src/bilingual_chat.lua` | 全部逻辑（Lua，跑在游戏进程内的 LuaJIT 里） |
| `tools/` | 打包器、编译检查 |
| `tests/` | 离线自测（不需要开游戏） |
| `docs/how-it-works.md` | 内存布局、发送配方、取证记录、调试开关 |
| `dist/` | 分发包（同时挂在 Release 上） |

## License

MIT，见 `LICENSE`。

---

### English

**Bilingual Chat for Helldivers 2** — your own chat line goes out untouched; about a second later the
translation is sent as a *second real chat message*, so teammates can read it too, and you press nothing.

The mod hands the text to the game's own send routine: it writes the translation into the chat input box
and sets the two state bytes (panel-active + submit) that the chat panel update consumes. No synthetic
input is used — `SendInput`/`PostMessage` are filtered by the anti-cheat and do not work here. The
translation itself runs in a separate `curl.exe` process, so the render thread never blocks.

Install: Bingus Shared Loader + Arsenal, import `dist/BilingualChat-1.0.0.zip`, Deploy. Configure
`HD2CT_API_URL`, `HD2CT_MODEL`, `HD2CT_API_KEY` in your user environment. See `docs/how-it-works.md`
for the memory layout and the fallback behaviour after a game update (MIT licensed).
