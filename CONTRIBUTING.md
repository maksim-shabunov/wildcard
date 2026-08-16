# Contributing

## Getting set up

```sh
git clone https://github.com/maksim-shabunov/wildcard
cd wildcard
swift test         # 23 tests, about a fifth of a second
./build.sh         # assembles Wildcard.app into ~/Applications
```

Xcode 16 or a Swift 6 toolchain. There are no dependencies to fetch — the MCP
server, the argument parser and the TOML editing are all written out longhand,
and it stays that way.

## The one rule

Nothing may reach LaunchServices except through a `Proposal` that a person has
approved in the window. The GUI, the CLI and the MCP server all go through
`Service.propose` / `AppModel.propose` for exactly this reason. A pull request
that adds a second path, a `--yes` flag, or an auto-approve setting will be
declined however convenient it is.

## Adding to the catalog

[`Sources/WildcardKit/Catalog/Resources/catalog.json`](Sources/WildcardKit/Catalog/Resources/catalog.json)
is the curated list of file types. Adding one is a line inside the right
subgroup:

```json
"zig": "Zig source"
```

`swift test` enforces the invariants: extensions are lower-case and undotted, no
extension appears in two categories, and every entry has a real display name —
"Zig source", never "ZIG".

## Style

The codebase is commented heavily and deliberately. Comments explain *why* a
decision was made, especially where the obvious approach does not work — see
`LSDatabase.swift` for why the preference file is written directly instead of
calling `NSWorkspace.setDefaultApplication`. Please match that: a comment
restating what the next line does is noise, and one recording a dead end you hit
is worth more than the code around it.

Four-space indent, no trailing whitespace, no force unwraps outside tests.

## Tests

Tests live where the risk is: concurrency, persistence, and the write path.
There are no view tests.

`ApplyPipelineTests` mutates the real LaunchServices database and is skipped
unless you ask for it:

```sh
WILDCARD_LIVE_TESTS=1 swift test
```

It binds invented `.wcselftest*` extensions and cleans up after itself, but it
is still your machine, so it stays opt-in.

`CatalogTests` reports catalog coverage against the applications installed on
your Mac. To hold it to a floor:

```sh
WILDCARD_COVERAGE_FLOOR=45 swift test
```

## Cutting a release

1. Bump `Sources/WildcardKit/Version.swift` — the only place the version is
   written. `build.sh` and CI both read it from there.
2. Add a section to `CHANGELOG.md`.
3. Tag and push:

   ```sh
   git tag v1.1.0 && git push origin v1.1.0
   ```

The release workflow checks the tag against `Version.swift`, runs the tests,
builds a universal signed bundle, publishes it with its SHA-256, and updates the
Homebrew cask.

The cask lives in a separate `homebrew-tap` repository, which this repository's
`GITHUB_TOKEN` cannot push to. That step needs a `TAP_TOKEN` secret — a
fine-grained personal access token with contents write on `homebrew-tap`. If it
is missing the release still ships and only the cask lags.
