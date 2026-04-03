# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-04-03

### Added

- Global archive activity timeline on the browse view. A horizontal bar chart shows archive density over time, always visible above the feed. Granularity auto-adapts based on data span: daily bars for spans under 2 months, weekly for under a year, monthly beyond that. Clicking a bar filters the feed to that period. Respects the active type filter (All/Pages/Videos).

### Changed

- Unified the Browse and Lookup URL tabs into a single search bar that auto-detects intent. Typing a URL and pressing Enter shows the calendar/timeline view; typing plain text filters the archive feed in real time; clearing the input returns to the full feed.
- Added type filter buttons (All / Pages / Videos) below the search bar, replacing the old tab toggle. Defaults to Pages.

## [0.3.0] - 2026-04-03

### Added

- Hashtree integration for chunked storage and video streaming. Files over 50MB are automatically split into a Merkle tree of chunks via `htree`, pushed to Blossom servers, and the tree root hash is included in kind 4554 archive events (`hashtree` tag) and NIP-71 video event `imeta` tags. This enables chunk-based P2P streaming through Hashtree-aware clients without downloading the entire file.
- New `hashtree-upload.sh` script for chunking files and pushing chunks to multiple Blossom servers.
- `--hashtree` flag on `archive-url.sh` to force Hashtree chunking regardless of file size.
- Archive index site now shows a green "🌲 chunked" badge and Hashtree viewer links (files.iris.to) for archives and videos with Hashtree data, in both browse and URL lookup views.

## [0.2.0] - 2026-04-03

### Added

- OpenClaw skill (`naan-archiver/`) that packages the full NAAN archival pipeline as a portable, installable skill. Any OpenClaw agent can become an archival node by installing it. Includes parameterized scripts for URL archiving, Blossom uploads, archive lookups, OTS stamping and upgrading, and WoT-gated mention monitoring. Configuration is driven by a single `naan.conf` file, with auto-discovery of Blossom servers (kind 10063) and relays (kind 10002) from the operator's Nostr metadata.

## [0.1.1] - 2026-04-03

### Added

- Auto-archive from public mentions (WoT-gated). New `monitor-mentions.sh` script subscribes to kind 1 events tagging NAAN's pubkey, checks the sender against Gigi's follow list (kind 3 contact list), extracts URLs, runs the full archive pipeline, and replies publicly with Blossom links and SHA-256 hashes. Includes rate limiting (max 3 per run), deduplication via persistent state, follow list caching, and a 10-minute age cutoff to avoid processing historical backlog.

## [0.1.0] - 2026-04-03

### Added

- Wayback Machine-style URL lookup view. A new "Lookup URL" tab lets users search for a specific URL and see its full archive history: a timeline bar chart showing monthly archive density, a 12-month calendar grid with colored snapshot dots (intensity scales with snapshot count), and a clickable snapshot list. Clicking a calendar day filters to that date's snapshots.
- Calendar year navigation with previous/next buttons.
- URL variant matching (http/https, trailing slash) for broader lookup results.
- Responsive calendar grid: 4 columns on desktop, 3 on tablet, 2 on mobile.

### Changed

- Controls section now has a Browse/Lookup tab toggle and a unified search bar that filters archives in browse mode or triggers URL lookup in lookup mode.
- Bumped version to 0.1.0 (first feature milestone).

## [0.0.4] - 2026-04-03

### Added

- NIP-71 video event publishing. When archiving a video, a kind 34235 (landscape) or 34236 (vertical) event is published alongside the kind 4554 archive event. Archived videos now appear in nostube, Amethyst, and other NIP-71-aware clients.
- New `publish-nip71.sh` script handles video metadata extraction from yt-dlp's `info.json`, builds `imeta` tags with Blossom URLs and fallback mirrors, and adds `origin`, `duration`, `published_at`, and hashtag tags.
- Archive index site now queries and displays NIP-71 video events with thumbnail previews, duration overlays, dimensions, hashtags, and origin platform links.
- Search in the archive index now also filters by hashtags.
- Stats display now distinguishes between archives and videos.

## [0.0.3] - 2026-04-03

### Added

- Bitcoin timestamp badge (`₿ timestamped`) on archives with NIP-03 OTS proofs. Queries relays for kind 1040 events referencing archive events, updates badges in-place.
- Two new Blossom mirrors: `blossom.sovereignengineering.io` and `haven.dergigi.com`. Archives now upload to 4 servers.

### Fixed

- Blossom links now show the server hostname (e.g. `blossom.primal.net`) instead of generic "Blossom / Mirror 1 / Mirror 2" labels.

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

[0.4.0]: https://github.com/dergigi/naan/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/dergigi/naan/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/dergigi/naan/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/dergigi/naan/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/dergigi/naan/compare/v0.0.4...v0.1.0
[0.0.4]: https://github.com/dergigi/naan/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/dergigi/naan/compare/v0.0.2...v0.0.3
[0.0.2]: https://github.com/dergigi/naan/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/dergigi/naan/releases/tag/v0.0.1
