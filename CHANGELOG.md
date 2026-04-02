# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.0.1]: https://github.com/dergigi/naan/releases/tag/v0.0.1
