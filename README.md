# CodexQuotaBar

Language: **English** | [简体中文](docs/i18n/README.zh-CN.md) | [日本語](docs/i18n/README.ja.md) | [한국어](docs/i18n/README.ko.md) | [Español](docs/i18n/README.es.md) | [Français](docs/i18n/README.fr.md) | [Deutsch](docs/i18n/README.de.md)

Native macOS menu bar app for showing Codex quota snapshots across one or more account slots.

## Features

- Compact macOS menu bar readout for 5-hour and weekly Codex quota.
- Glass-style popover dashboard with account, plan, refresh, and reset details.
- Silent import from the local Codex login at `~/.codex/auth.json`.
- AIPlanMonitor-style profile and slot snapshot files for local inspection.
- DMG packaging script and generated app icons.

## Build

```sh
make build
make test
make app
```

The app bundle is written to:

```text
.build/CodexQuotaBar.app
```

## Runtime data

- Snapshot JSON: `~/Library/Application Support/CodexQuotaBar/codex_slots.json`
- Imported profile JSON: `~/Library/Application Support/CodexQuotaBar/codex_profiles.json`
- Keychain mirror: macOS Keychain service `com.codexquotabar.secrets`

`Import Current Codex Account` reads `~/.codex/auth.json` and stores an AIPlanMonitor-style profile containing `authJSON`, account identity fields, slot id, and credential fingerprint. Tokens are also mirrored into Keychain so the provider can refresh without reparsing the profile file.

Because `codex_profiles.json` contains imported auth JSON, keep the file private to your macOS user account.

## Install

```sh
make app
cp -R .build/CodexQuotaBar.app /Applications/
open /Applications/CodexQuotaBar.app
```

Or build a DMG installer:

```sh
make dmg
open .build/CodexQuotaBar.dmg
```

Then drag `CodexQuotaBar.app` into `Applications`.

If macOS blocks the unsigned app, open **System Settings -> Privacy & Security** and allow it, or run:

```sh
xattr -dr com.apple.quarantine /Applications/CodexQuotaBar.app
open /Applications/CodexQuotaBar.app
```

## Provider configuration

The official Codex quota endpoint is isolated behind `OfficialCodexProvider` because OpenAI does not document a stable public subscription-quota API for this use case. Override endpoints without touching UI code:

```sh
CODEX_QUOTA_ENDPOINT="https://chatgpt.com/backend-api/wham/usage" \
OPENAI_OAUTH_TOKEN_ENDPOINT="https://auth.openai.com/oauth/token" \
swift run CodexQuotaBar
```
