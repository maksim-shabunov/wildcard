<div align="center">

# Wildcard

**Set which app opens which kind of file — a whole category at a time.**

[![CI](https://github.com/maksim-shabunov/wildcard/actions/workflows/ci.yml/badge.svg)](https://github.com/maksim-shabunov/wildcard/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/maksim-shabunov/wildcard?color=7c5295)](https://github.com/maksim-shabunov/wildcard/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)](https://github.com/maksim-shabunov/wildcard/releases/latest)
[![MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

</div>

macOS lets you change a default application one file extension at a time, through
Get Info → Change All. Moving your code to a new editor that way means finding
`.ts`, `.tsx`, `.rs`, `.toml`, `.gradle`, `.podspec` and three hundred others,
one dialog each, and still missing the ones you have never heard of.

Wildcard works in categories. Pick **Code**, pick your editor, and all 341
extensions move together. Then it stays out of the way and tells you when
something changes them back.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/maksim-shabunov/wildcard/main/install.sh | bash
```

Or with Homebrew:

```sh
brew install --cask maksim-shabunov/tap/wildcard
```

Either one puts `Wildcard.app` in `/Applications`. Run it again to update.
macOS 14 or later; one universal build for Apple Silicon and Intel.

<details>
<summary>Build it yourself instead</summary>

```sh
git clone https://github.com/maksim-shabunov/wildcard
cd wildcard
./build.sh
```

Xcode 16 or a Swift 6 toolchain, and nothing else — Wildcard has no
dependencies. The app lands in `~/Applications`.
</details>

## What it does

**Categories.** 1,135 file extensions and link schemes, curated into 29
categories — Code, Images, Archives, Web links, and so on. You never type an
extension list by hand.

**Rules.** "Code opens with Cursor" as a standing intent. A rule changes nothing
on its own; it exists so Wildcard can tell you when an installer quietly takes
`.json` back, which otherwise only surfaces as the wrong app launching.

**Needs a decision.** A file type that appears on your Mac with nothing deciding
where it should go waits in an inbox instead of being handed to whichever app
claimed it first.

**History and undo.** Every applied change is listed with what it changed. ⌘Z
undoes the last one. A full snapshot is taken before every change, so there is
always a way back.

## Nothing changes without you

Every change — from the window, the command line, or an AI agent — becomes a
**proposal**: a diff you read and approve. There is no auto-apply setting,
because there is no code path that skips the sheet.

```
  you, the CLI, or an agent
            │
            ▼
      a proposal ──────▶ the window shows the full diff
                                    │
                          you press Apply
                                    │
                                    ▼
                  snapshot → write → reload → read back and verify
```

The last step matters: Wildcard reads the change back out of LaunchServices and
reports what actually took effect, rather than assuming the write worked.

## Command line

The app ships a `wildcard` binary. Link it from **Settings → Integrations**, or
call it at `/Applications/Wildcard.app/Contents/Helpers/wildcard`.

```sh
wildcard status                          # what is managed, drifting, unhandled
wildcard list --category code            # what opens what
wildcard search kotlin                   # find types by name or extension
wildcard set --app Zed --category code   # shows the diff, waits for approval
wildcard set --app Zed --types kt,rs --print-only   # just show me
wildcard history
```

Writes queue a proposal and block until you approve it in the window. `--json`
on any command for machine-readable output.

## Agents

Wildcard is an MCP server. **Settings → Integrations** installs it into Claude
Code, Claude Desktop or Codex, or gives you the config block to paste anywhere
else.

Agent access is **off by default**. When it is on, an agent gets eighteen tools:
seventeen that read, and `propose_changes`, which queues a proposal and returns.
An agent cannot approve its own proposal — the switch that would allow that does
not exist, and the check lives in the binary rather than only in the MCP layer,
because an agent with a shell can run the binary directly.

```
› move my code files to Zed but leave markdown in Obsidian

  Wildcard is asking you to approve 337 changes.
```

## Where it keeps things

`~/Library/Application Support/Wildcard/` — plain JSON, readable and editable by
hand. Rules, history, snapshots and the queue of pending proposals.

Wildcard makes no network calls, has no telemetry, and contains no AI of its
own. It writes to exactly one thing besides its own folder: the LaunchServices
preference file that stores your default applications.

## Why macOS may warn about it

Wildcard is signed ad-hoc, not with a paid Apple Developer certificate, so it
cannot be notarised.

The install script and Homebrew both handle this — neither leaves you with a
warning to click through. If you download the `.zip` from the
[Releases](https://github.com/maksim-shabunov/wildcard/releases) page in a
browser, macOS quarantines it and refuses to open it. Clear that with:

```sh
xattr -dr com.apple.quarantine /Applications/Wildcard.app
```

Or avoid the question entirely by building from source: an app you compile
yourself is never quarantined.

Every release publishes a SHA-256 next to its archive, and the install script
checks it before unpacking.

## Contributing

Bug reports and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).
The catalog in
[`catalog.json`](Sources/WildcardKit/Catalog/Resources/catalog.json) is the
easiest place to help: if a file type you use is missing, adding it is one line.

## License

MIT — see [LICENSE](LICENSE).
