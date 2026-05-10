# CodexQuotaBar

语言： [English](../../README.md) | **简体中文** | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md)

CodexQuotaBar 是一个原生 macOS 状态栏应用，用于展示 Codex 的 5 小时额度和周额度。

## 关于 / About

CodexQuotaBar 是一个轻量的原生 macOS 状态栏应用，用来在不打开 Codex 或 ChatGPT 界面的情况下查看 Codex 额度。它会静默读取本机 Codex 登录状态，同时展示 5 小时额度和周额度，并提供一个精致的下拉仪表盘。

CodexQuotaBar is a small native macOS menu bar app for monitoring Codex quota without opening the Codex or ChatGPT UI. It silently imports your local Codex login, shows both the 5-hour and weekly windows, and keeps the detailed dashboard one click away.

## 截图 / Screenshots

![CodexQuotaBar 下拉仪表盘](../assets/screenshot-panel.png)

![CodexQuotaBar 状态栏紧凑显示](../assets/screenshot-menubar.png)

## 功能

- 在 macOS 状态栏紧凑显示 `5h` 与 `W` 两个额度。
- 毛玻璃风格下拉面板，展示账号、套餐、刷新时间和重置时间。
- API Key 管理器，支持一键复制、余额展示，以及 DeepSeek/MiniMax 使用统计。
- 提供 macOS 桌面组件，小尺寸和中尺寸都能显示 5 小时额度与周额度。
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

## 桌面组件

CodexQuotaBar 提供两种桌面组件方式：

- 内置悬浮桌面组件：从状态栏下拉面板点击 `桌面` 即可显示或隐藏，当前 DMG 可直接使用。
- 实验性 WidgetKit 系统组件：已打包进 App，但 macOS 可能要求 Xcode/Developer ID 正式签名后才会显示在系统组件库里。

悬浮桌面组件：

1. 启动 CodexQuotaBar。
2. 打开状态栏下拉面板。
3. 点击 `桌面` 显示或隐藏桌面组件。

WidgetKit 系统组件：

1. 将 `CodexQuotaBar.app` 安装到 `/Applications`。
2. 启动一次应用，让它写入最新额度快照。
3. 在桌面或通知中心打开 macOS 组件面板。
4. 搜索 `Codex 额度` 或 `CodexQuotaBar`。
5. 添加小尺寸或中尺寸组件。

组件读取状态栏应用写入的本地快照。如果本地未签名构建安装后没有立刻出现在组件列表中，请退出并重新打开 CodexQuotaBar，或注销后重新登录，让 macOS 刷新组件扩展缓存。

## 运行数据

- 额度快照：`~/Library/Application Support/CodexQuotaBar/codex_slots.json`
- 导入的账号档案：`~/Library/Application Support/CodexQuotaBar/codex_profiles.json`
- API Key 配置：`~/Library/Application Support/CodexQuotaBar/api_keys.json`
- 钥匙串镜像：macOS Keychain service `com.codexquotabar.secrets`

`导入当前账号` 会读取 `~/.codex/auth.json`，本地 profile 只保存账号身份字段、slot id 和 credential fingerprint。访问令牌会同步到钥匙串，普通 JSON 文件不再保存原始 auth JSON。

API Key 配置文件只保存平台模板、非敏感字段和最后一次余额快照。DeepSeek/MiniMax 的 API key、Comfly token 会保存到 Keychain，不会写入普通 JSON。

`codex_profiles.json` 现在按元数据文件设计；它仍然会暴露本机账号标识，建议只保存在自己的 macOS 用户账号下，不要上传或分享。

如果你有 Developer ID 证书，可以用稳定签名身份构建 DMG，减少 macOS 钥匙串反复弹窗：

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make dmg
```

## Provider 配置

Codex 额度刷新逻辑封装在 `OfficialCodexProvider`。如需覆盖接口：

```sh
CODEX_QUOTA_ENDPOINT="https://chatgpt.com/backend-api/wham/usage" \
OPENAI_OAUTH_TOKEN_ENDPOINT="https://auth.openai.com/oauth/token" \
swift run CodexQuotaBar
```
