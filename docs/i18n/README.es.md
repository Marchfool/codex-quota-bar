# CodexQuotaBar

Language: [English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | **Español** | [Français](README.fr.md) | [Deutsch](README.de.md)

CodexQuotaBar es una app nativa de barra de menús para macOS que muestra la cuota de Codex de 5 horas y semanal.

## Funciones

- Lectura compacta en la barra de menús para `5h` y `W`.
- Panel desplegable con estilo de cristal para cuenta, plan, actualización y reinicio.
- Importación silenciosa del inicio de sesión local de Codex desde `~/.codex/auth.json`.
- Archivos locales de profile y snapshot compatibles con el estilo de AIPlanMonitor.
- Script para crear DMG e iconos generados.

## Compilar

```sh
make build
make test
make app
```

El paquete se genera en:

```text
.build/CodexQuotaBar.app
```

## Instalar

```sh
make dmg
open .build/CodexQuotaBar.dmg
```

Después arrastra `CodexQuotaBar.app` a `Applications`.

Si macOS bloquea la app por no estar firmada:

```sh
xattr -dr com.apple.quarantine /Applications/CodexQuotaBar.app
open /Applications/CodexQuotaBar.app
```

## Datos locales

- Snapshot: `~/Library/Application Support/CodexQuotaBar/codex_slots.json`
- Profile importado: `~/Library/Application Support/CodexQuotaBar/codex_profiles.json`
- Copia en Keychain: `com.codexquotabar.secrets`

`codex_profiles.json` contiene el auth JSON importado. No lo compartas ni lo subas.

## Configuración del provider

```sh
CODEX_QUOTA_ENDPOINT="https://chatgpt.com/backend-api/wham/usage" \
OPENAI_OAUTH_TOKEN_ENDPOINT="https://auth.openai.com/oauth/token" \
swift run CodexQuotaBar
```
