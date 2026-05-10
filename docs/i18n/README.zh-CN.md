# CodexQuotaBar

语言： [English](../../README.md) | **简体中文** | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md)

CodexQuotaBar 是一个原生 macOS 状态栏应用，用于展示 Codex 的 5 小时额度和周额度。

## 功能

- 在 macOS 状态栏紧凑显示 `5h` 与 `W` 两个额度。
- 毛玻璃风格下拉面板，展示账号、套餐、刷新时间和重置时间。
- 首次启动静默读取本机 Codex 登录文件 `~/.codex/auth.json`。
- 保存 AIPlanMonitor 风格的本地 profile 和 slot 快照，方便排查。
- 提供 DMG 打包脚本和自动生成的应用图标。

## 构建

```sh
make build
make test
make app
```

应用包输出到：

```text
.build/CodexQuotaBar.app
```

## 安装

```sh
make app
cp -R .build/CodexQuotaBar.app /Applications/
open /Applications/CodexQuotaBar.app
```

也可以生成 DMG：

```sh
make dmg
open .build/CodexQuotaBar.dmg
```

打开 DMG 后，将 `CodexQuotaBar.app` 拖入 `Applications`。

如果 macOS 拦截未签名应用，可以在 **系统设置 -> 隐私与安全性** 中允许，或执行：

```sh
xattr -dr com.apple.quarantine /Applications/CodexQuotaBar.app
open /Applications/CodexQuotaBar.app
```

## 运行数据

- 额度快照：`~/Library/Application Support/CodexQuotaBar/codex_slots.json`
- 导入的账号档案：`~/Library/Application Support/CodexQuotaBar/codex_profiles.json`
- 钥匙串镜像：macOS Keychain service `com.codexquotabar.secrets`

`导入当前账号` 会读取 `~/.codex/auth.json`，保存包含 `authJSON`、账号身份字段、slot id 和 credential fingerprint 的本地 profile。令牌也会同步到钥匙串，供刷新额度使用。

因为 `codex_profiles.json` 包含导入的 auth JSON，请只保存在自己的 macOS 用户账号下，不要上传或分享。

## Provider 配置

Codex 额度刷新逻辑封装在 `OfficialCodexProvider`。如需覆盖接口：

```sh
CODEX_QUOTA_ENDPOINT="https://chatgpt.com/backend-api/wham/usage" \
OPENAI_OAUTH_TOKEN_ENDPOINT="https://auth.openai.com/oauth/token" \
swift run CodexQuotaBar
```
