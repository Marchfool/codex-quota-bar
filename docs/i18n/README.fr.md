# CodexQuotaBar

Language: [English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | **Français** | [Deutsch](README.de.md)

CodexQuotaBar est une application native macOS de barre de menus qui affiche les quotas Codex sur 5 heures et sur la semaine.

## Fonctionnalités

- Affichage compact dans la barre de menus pour `5h` et `W`.
- Panneau déroulant façon verre avec compte, offre, heure de mise à jour et réinitialisation.
- Import silencieux de la session Codex locale depuis `~/.codex/auth.json`.
- Fichiers locaux de profile et de snapshot au format proche d'AIPlanMonitor.
- Script de création DMG et icônes générées.

## Compilation

```sh
make build
make test
make app
```

Le bundle est généré ici :

```text
.build/CodexQuotaBar.app
```

## Installation

```sh
make dmg
open .build/CodexQuotaBar.dmg
```

Glissez ensuite `CodexQuotaBar.app` dans `Applications`.

Si macOS bloque l'application non signée :

```sh
xattr -dr com.apple.quarantine /Applications/CodexQuotaBar.app
open /Applications/CodexQuotaBar.app
```

## Données locales

- Snapshot : `~/Library/Application Support/CodexQuotaBar/codex_slots.json`
- Profile importé : `~/Library/Application Support/CodexQuotaBar/codex_profiles.json`
- Miroir Keychain : `com.codexquotabar.secrets`

`codex_profiles.json` contient le auth JSON importé. Ne le partagez pas.

## Configuration du provider

```sh
CODEX_QUOTA_ENDPOINT="https://chatgpt.com/backend-api/wham/usage" \
OPENAI_OAUTH_TOKEN_ENDPOINT="https://auth.openai.com/oauth/token" \
swift run CodexQuotaBar
```
