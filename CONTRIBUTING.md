# Contributing

Thanks for helping with Roomtone.

## License of contributions

By contributing, you agree your contributions are licensed to the project
under the same PolyForm Noncommercial License 1.0.0, and that the maintainer
may dual-license the project (including your contribution) for commercial deals.

## Developer Certificate of Origin (DCO)

Every commit must include:

```
Signed-off-by: Your Name <you@example.com>
```

Use `git commit -s`.

## Workflow

1. Fork / branch from `main`
2. Keep PRs focused
3. Match existing architecture (protocols over concrete types)
4. Do not commit secrets, API keys, or model weights

## Local setup

- macOS 14+
- Xcode 16+
- `brew install xcodegen` then `xcodegen generate`
- Open `Roomtone.xcodeproj`

## Architecture

See [AGENTS.md](./AGENTS.md).
