# Contributing

Thanks for helping! Reports from printers other than the Canon MF750C II are especially useful.

## Reporting a printer

Open an issue with the output of:

```bash
swift run skener-cli info <printer-ip>
swift run skener-cli caps <printer-ip>
```

If scanning or printing fails, add `-v` to the failing command (or copy the in-app log, ⌘L).

## Development

```bash
make test        # swift test
make lint        # swift format lint --strict
make format      # swift format --in-place
make app         # build/Skener.app
make snapshots   # screenshots + demo.gif with sample data
```

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first — it is short.

## Pull requests

- One topic per PR; `main` only accepts squash merges with green CI (Lint, Test (Linux), Build & test (macOS)).
- New protocol behaviour comes with a test against a fake transport.
- Keep UI strings in `Shared/Text.swift` or next to their view.
