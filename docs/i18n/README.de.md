# CodexQuotaBar

Language: [English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | **Deutsch**

CodexQuotaBar ist eine native macOS-Menüleisten-App zur Anzeige des Codex-Kontingents für 5 Stunden und für die Woche.

## Funktionen

- Kompakte Anzeige in der Menüleiste für `5h` und `W`.
- Glasartiges Popover mit Konto, Plan, Aktualisierung und Reset-Zeit.
- Stiller Import des lokalen Codex-Logins aus `~/.codex/auth.json`.
- Lokale Profile- und Snapshot-Dateien im Stil von AIPlanMonitor.
- DMG-Paketierungsskript und generierte App-Icons.

## Build

```sh
make build
make test
make app
```

Das App-Bundle wird hier erzeugt:

```text
.build/CodexQuotaBar.app
```

## Installation

```sh
make dmg
open .build/CodexQuotaBar.dmg
```

Ziehe danach `CodexQuotaBar.app` nach `Applications`.

Falls macOS die unsignierte App blockiert:

```sh
xattr -dr com.apple.quarantine /Applications/CodexQuotaBar.app
open /Applications/CodexQuotaBar.app
```

## Lokale Daten

- Snapshot: `~/Library/Application Support/CodexQuotaBar/codex_slots.json`
- Importiertes Profil: `~/Library/Application Support/CodexQuotaBar/codex_profiles.json`
- Keychain-Spiegel: `com.codexquotabar.secrets`

`codex_profiles.json` enthält das importierte auth JSON. Bitte nicht teilen oder hochladen.

## Provider-Konfiguration

```sh
CODEX_QUOTA_ENDPOINT="https://chatgpt.com/backend-api/wham/usage" \
OPENAI_OAUTH_TOKEN_ENDPOINT="https://auth.openai.com/oauth/token" \
swift run CodexQuotaBar
```
