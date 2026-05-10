# CodexQuotaBar

Language: [English](../../README.md) | [简体中文](README.zh-CN.md) | **日本語** | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md)

CodexQuotaBar は、Codex の 5 時間枠と週間枠の残量を表示するネイティブ macOS メニューバーアプリです。

## 主な機能

- メニューバーに `5h` と `W` の残量をコンパクトに表示。
- ガラス風のポップオーバーでアカウント、プラン、更新時刻、リセット時刻を確認。
- 初回起動時にローカルの Codex ログイン `~/.codex/auth.json` を自動インポート。
- AIPlanMonitor 互換の profile と slot スナップショットを保存。
- DMG 作成スクリプトと自動生成アイコンを同梱。

## ビルド

```sh
make build
make test
make app
```

アプリは次に出力されます。

```text
.build/CodexQuotaBar.app
```

## インストール

```sh
make dmg
open .build/CodexQuotaBar.dmg
```

DMG を開き、`CodexQuotaBar.app` を `Applications` にドラッグしてください。

未署名アプリとしてブロックされた場合：

```sh
xattr -dr com.apple.quarantine /Applications/CodexQuotaBar.app
open /Applications/CodexQuotaBar.app
```

## ランタイムデータ

- スナップショット：`~/Library/Application Support/CodexQuotaBar/codex_slots.json`
- インポート済み profile：`~/Library/Application Support/CodexQuotaBar/codex_profiles.json`
- Keychain ミラー：`com.codexquotabar.secrets`

`codex_profiles.json` にはインポートした auth JSON が含まれるため、共有しないでください。

## Provider 設定

```sh
CODEX_QUOTA_ENDPOINT="https://chatgpt.com/backend-api/wham/usage" \
OPENAI_OAUTH_TOKEN_ENDPOINT="https://auth.openai.com/oauth/token" \
swift run CodexQuotaBar
```
