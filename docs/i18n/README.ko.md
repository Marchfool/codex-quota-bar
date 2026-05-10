# CodexQuotaBar

Language: [English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | **한국어** | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md)

CodexQuotaBar는 Codex의 5시간 사용량과 주간 사용량을 macOS 메뉴 막대에서 보여주는 네이티브 앱입니다.

## 기능

- 메뉴 막대에 `5h`와 `W` 잔여량을 작게 표시합니다.
- 유리 느낌의 팝오버에서 계정, 플랜, 새로고침 시간, 초기화 시간을 확인합니다.
- 첫 실행 시 로컬 Codex 로그인 파일 `~/.codex/auth.json`을 자동으로 가져옵니다.
- AIPlanMonitor 스타일의 profile 및 slot 스냅샷을 저장합니다.
- DMG 패키징 스크립트와 생성된 앱 아이콘을 포함합니다.

## 빌드

```sh
make build
make test
make app
```

앱 번들은 다음 위치에 생성됩니다.

```text
.build/CodexQuotaBar.app
```

## 설치

```sh
make dmg
open .build/CodexQuotaBar.dmg
```

DMG에서 `CodexQuotaBar.app`을 `Applications`로 드래그하세요.

macOS가 미서명 앱을 차단하면 다음을 실행하세요.

```sh
xattr -dr com.apple.quarantine /Applications/CodexQuotaBar.app
open /Applications/CodexQuotaBar.app
```

## 런타임 데이터

- 스냅샷: `~/Library/Application Support/CodexQuotaBar/codex_slots.json`
- 가져온 profile: `~/Library/Application Support/CodexQuotaBar/codex_profiles.json`
- Keychain 미러: `com.codexquotabar.secrets`

`codex_profiles.json`에는 가져온 auth JSON이 포함되므로 공유하지 마세요.

## Provider 설정

```sh
CODEX_QUOTA_ENDPOINT="https://chatgpt.com/backend-api/wham/usage" \
OPENAI_OAUTH_TOKEN_ENDPOINT="https://auth.openai.com/oauth/token" \
swift run CodexQuotaBar
```
