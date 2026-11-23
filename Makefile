.PHONY: test lint format app snapshots run

test:
	swift test --parallel

lint:
	swift format lint --strict --recursive Package.swift Sources Tests

format:
	swift format --in-place --recursive Package.swift Sources Tests

app:
	./scripts/build-app.sh

snapshots:
	swift run snapshots build/snapshots

run:
	swift run Skener
