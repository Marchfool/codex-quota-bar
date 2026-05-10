.PHONY: build test app dmg run clean

build:
	swift build

test:
	swift run CodexQuotaCoreTestRunner

app:
	./scripts/bundle-app.sh release

dmg:
	./scripts/create-dmg.sh release

run:
	swift run CodexQuotaBar

clean:
	rm -rf .build
