---
name: naan-archiver
description: "Decentralized web archiving on Nostr + Blossom. Archive URLs (web pages, videos, documents) to content-addressed Blossom storage and index them as kind 4554 events on Nostr with OpenTimestamps proofs. Use when: (1) archiving a URL or web page, (2) looking up existing archives of a URL, (3) uploading files to Blossom, (4) upgrading pending OpenTimestamps proofs, (5) monitoring Nostr mentions for archive requests, (6) setting up a new NAAN archival node. Triggers on: archive, blossom, kind 4554, web archive, preserve, snapshot, wayback, OTS, OpenTimestamps."
---

# NAAN Archiver

Turn any OpenClaw agent into a Nostr Agentic Archiving Node. Archives web content to Blossom (content-addressed blob storage) and indexes it on Nostr via kind 4554 events, with optional Bitcoin-anchored timestamps via OpenTimestamps.

## Setup

### 1. Configuration

Create `naan.conf` in the workspace root:

```bash
# Required: path to Nostr secret key (nsec1... or hex)
NSEC_FILE="/path/to/.nostr-nsec.key"

# Optional: operator's npub (hex). If set, relays and Blossom servers
# are auto-discovered from kind 10002 and kind 10063 events.
OPERATOR_PUBKEY=""

# Optional: owner pubkey for WoT gating (who can request archives via mentions)
OWNER_PUBKEY=""

# Overrides (used if auto-discovery fails or OPERATOR_PUBKEY is unset)
BLOSSOM_SERVERS="https://blossom.primal.net https://cdn.hzrd149.com"
RELAYS="wss://relay.damus.io wss://relay.primal.net wss://nos.lol"

# Archive storage
ARCHIVE_DIR="./archives"

# Chrome path for SingleFile
CHROME_PATH="/usr/bin/chromium"
```

If `OPERATOR_PUBKEY` is set, the skill queries relays for:
- **Kind 10063** (Blossom server list) to discover upload targets
- **Kind 10002** (NIP-65 relay list) to discover publish relays
- **Kind 3** (contacts) for WoT-gated access control

Falls back to `BLOSSOM_SERVERS` and `RELAYS` if discovery returns nothing.

### 2. Dependencies

Required: `nak`, `curl`, `jq`, `sha256sum`
Web archiving: `single-file-cli` + Chromium (primary), `monolith` (fallback)
Video archiving: `yt-dlp`
Timestamping: `ots` (github.com/fiatjaf/ots)

## Commands

### Archive a URL

```bash
bash scripts/archive-url.sh <url> [--video] [--monolith] [--dry-run]
```

Full pipeline: download content, compute SHA-256, upload to Blossom servers, publish kind 4554 event, submit to OpenTimestamps. Auto-detects video URLs (YouTube, Vimeo, Twitter/X, TikTok, Rumble).

### Look up existing archives

```bash
bash scripts/lookup-archive.sh <url>
```

Queries relays for kind 4554 events matching the URL. Use before archiving to avoid duplicates.

### Upload a file to Blossom

```bash
bash scripts/blossom-upload.sh <file> [blossom_server_url]
```

Uploads with NIP-98 (kind 24242) authorization. Returns JSON with `url`, `sha256`, `size`.

### Stamp a Nostr event with OpenTimestamps

```bash
bash scripts/ots-stamp.sh <event_id>
```

### Upgrade pending OTS proofs

```bash
bash scripts/ots-upgrade.sh [--publish]
```

Scans for pending `.ots` files, upgrades them when Bitcoin attestation is available, and (with `--publish`) publishes kind 1040 events.

### Monitor mentions for archive requests

```bash
bash scripts/monitor-mentions.sh [--dry-run] [--since <unix_ts>]
```

Queries kind 1 events tagging the node's pubkey, filters by WoT (owner's follow list), extracts URLs, archives them, replies publicly. Rate limited to 3 archives per run, ignores mentions older than 10 minutes.

## Event Spec

See `references/event-spec.md` for the full kind 4554 archive event schema and kind 1040 OTS proof format.

## Access Control

Three modes (set by configuring `OWNER_PUBKEY` in `naan.conf`):

1. **Owner only** (default): only DMs/mentions from the operator trigger archiving
2. **Follows**: anyone the owner follows (kind 3 contact list) can request archives
3. **Open**: leave `OWNER_PUBKEY` blank to accept from anyone (not recommended)

## Periodic Tasks

Set up cron jobs for:
- **OTS upgrade**: run `ots-upgrade.sh --publish` every 1-2 hours to finalize pending Bitcoin timestamps
- **Mention monitoring**: run `monitor-mentions.sh` every 5-10 minutes to auto-archive from mentions
