.PHONY: build test app install dmg run clean

build:
	swift build

test:
	swift run CodexQuotaCoreTestRunner

app:
	./scripts/bundle-app.sh release

install:
	./scripts/install-app.sh release

dmg:
	./scripts/create-dmg.sh release

run:
	./build_and_run.sh

clean:
	rm -rf .build
