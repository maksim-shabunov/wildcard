# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — 2026-08-16

First public release.

### Added

- Assign default applications by category: 1,135 file extensions and link
  schemes across 29 curated categories.
- Rules — a standing intent that reports drift when something else changes a
  binding, rather than silently accepting it.
- Proposals: every change from the window, the command line or an agent is a
  diff a person approves before anything is written.
- History with per-change undo, and automatic snapshots before every apply.
- "Needs a decision" inbox, so a newly appeared file type is never handed to
  whichever application claimed it first.
- `wildcard` command-line tool with fifteen commands.
- MCP server with eighteen tools, off by default, with one-click installation
  into Claude Code, Claude Desktop and Codex.
- Universal build for Apple Silicon and Intel, a checksum-verifying install
  script, and a Homebrew cask.

[1.0.0]: https://github.com/maksim-shabunov/wildcard/releases/tag/v1.0.0
