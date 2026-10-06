# Bilingual Chat 1.0.0

**你的中文照常发出；约一秒后，英文译文作为第二条真实聊天消息自动发出——队友也看得见，你不需要多按任何键。**

```
你：       前方有敌人
你：[EN]   Enemies ahead!
```

## 亮点

- **全自动**：默认模式 `mem`，译文由**游戏自己的聊天代码**发出去。mod 只是把译文写进聊天输入框，
  再置两个内部状态字节（面板激活 + 提交），游戏随即取走内容、走它自己的发送流程、清空输入框。
- **不注入按键、不改游戏文件**：`SendInput` / `PostMessage` 这类合成输入会被反作弊过滤（实测全部"成功"但无效），
  本 mod 完全不依赖它们，因此不会被拦，也不会掉帧。
- **译文独立进程**：翻译由单独的 `curl.exe` 完成，渲染线程不被阻塞；API 密钥只写进 curl 配置文件，
  不会出现在命令行上。
- **只会降级不会失效**：游戏更新若改动了内存偏移，译文就留在输入框里，你自己按回车照样发得出去
  （日志会出现 `MSEND failed`）。
- 前缀可配置（默认中文源加 `[EN] `、英文源加 `[CN] `），与"自动翻译英文消息"的插件共存时，
  让对方跳过这两个前缀即可，不会层层叠译。

## 安装

1. 先装 [Bingus Shared Loader](https://github.com/CowboyBingus/BingusSharedLoader)。
2. 用 Arsenal 导入本附件 `BilingualChat-1.0.0.zip` → Deploy。
3. 删掉旧的同类包（如 `mods/dsh/bilingual_chat*`），避免两个 mod 抢同一个输入框。
4. 配置用户级环境变量：`HD2CT_API_URL`、`HD2CT_MODEL`、`HD2CT_API_KEY`（必填）。
5. 启动游戏；日志 `%LOCALAPPDATA%\CowboyBingus\Helldivers2\Logs\HD2BilingualChat.log` 首行应为
   `START version=1.0.0 addon=mods/alkaid/bilingual_chat`。

## 附件

- `BilingualChat-1.0.0.zip` — Arsenal 分发包
  - addon 路径 `mods/alkaid/bilingual_chat`
  - GUID `caa76616-42f9-4368-8086-c94df065aeff`
  - SHA-256 `0faafb1ae5378720230e5eab97e77353f60a3ea9c57a5dcaf12de89516d7f083`

## 校验

- 离线自测 10/10 通过（`tests/mem_send_test.py`：假游戏会消费那两个状态字节，覆盖"成功发送"与"降级"两条路径）
- 源码用游戏自带的 `bin/lua51.dll` 编译通过
- 真实游戏内实测：聊天环出现两条记录，`type=0x1c12037f`、署名与玩家一致、正文与写入内容逐字相同

## 说明

MIT 许可。本 mod 只在 Windows + 官方反作弊环境下测试过；它不做任何绕过反作弊的动作，也不修改游戏文件。
游戏更新后偏移的重新定位方法见 `docs/how-it-works.md`。
