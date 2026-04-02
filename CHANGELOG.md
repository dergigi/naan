# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.0.2] - 2026-04-03

### Added

- SingleFile as default web archiver — headless Chrome captures JS-rendered pages with full fidelity. Monolith remains as fallback (`--monolith` flag).
- NIP-03 OpenTimestamps integration — archive events are automatically submitted to OTS calendars after publishing. New scripts: `ots-stamp.sh` and `ots-upgrade.sh --publish` for upgrading pending proofs and publishing kind 1040 events.
- Archiver profile resolution via `eventStore.profile()` — the "archived by" field now shows profile names instead of truncated pubkeys.
- Implementation plan (`IMPLEMENTATION.md`) covering the full roadmap from v0.1.0 to v1.0.0.

### Changed

- Refactored site to use `toEventStore()` operator and reactive `eventStore.timeline()` subscription (applesauce best practices via MCP server).
- Added `index.hzrd149.com` as additional lookup relay for profile resolution.

### Fixed

- Use correct applesauce API (`getTimeline` instead of non-existent `getAll`), which was causing the site to hang on the loading spinner.

## [0.0.1] - 2026-04-02

### Added

- Archive pipeline script (`archive-url.sh`) — download, upload to Blossom, publish kind 4554 to Nostr
- Blossom upload script (`blossom-upload.sh`) with NIP-98 authorization
- Archive lookup script (`lookup-archive.sh`) — query relays for existing archives
- Web-based archive index site built with [Applesauce](https://applesauce.build) SDK + Vite
- NIP-66 relay discovery for finding archives across the network
- Deployed as an [nsite](https://nsyte.run) on Nostr + Blossom
- Research document with architecture, event spec, and building blocks
- README with usage docs

### Archive Event Format

- Uses kind 4554 (extending [fiatjaf's Nostr Web Archiver](https://github.com/fiatjaf/nostr-web-archiver))
- Tags: `url`, `r`, `x` (SHA-256), `m` (MIME), `format`, `size`, `title`, `archived-at`, `tool`
- Uploads to multiple Blossom servers for redundancy

[0.0.2]: https://github.com/dergigi/naan/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/dergigi/naan/releases/tag/v0.0.1
