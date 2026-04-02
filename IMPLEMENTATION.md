# NAAN Implementation Plan

A decentralized Internet Archive built on Nostr + Blossom + Hashtree + OpenTimestamps.

## Current State (v0.0.1)

What we have today:

- Archive pipeline for web pages (monolith) and videos (yt-dlp, blocked by YouTube cookies)
- Blossom upload with NIP-98 auth to 2 servers
- Kind 4554 archive events published to 3 relays
- Archive index site (applesauce + Vite) with NIP-66 relay discovery
- Deployed as nsite + GitHub
- One successful archive: Bitcoin whitepaper from nakamotoinstitute.org

## Architecture Overview

```
                    ┌─────────────────────────────────────────────┐
                    │              NAAN Network                    │
                    │                                             │
  ┌──────────┐     │  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
  │  User /  │────▶│  │  NAAN    │  │  NAAN    │  │  NAAN    │  │
  │  Client  │     │  │  Node 1  │  │  Node 2  │  │  Node N  │  │
  └──────────┘     │  └────┬─────┘  └────┬─────┘  └────┬─────┘  │
                    │       │             │             │         │
                    └───────┼─────────────┼─────────────┼─────────┘
                            │             │             │
                 ┌──────────▼─────────────▼─────────────▼──────────┐
                 │                                                  │
    ┌────────────┴────────────┐              ┌─────────────────────┐
    │     Storage Layer       │              │    Index Layer       │
    │                         │              │                     │
    │  Blossom (small files)  │              │  Nostr Relays       │
    │  Hashtree (large files) │              │  Kind 4554 events   │
    │  Content-addressed      │              │  Kind 1040 OTS      │
    │  Mirrored & redundant   │              │  Queryable by URL   │
    └─────────────────────────┘              └─────────────────────┘
                 │                                      │
                 └──────────────┬───────────────────────┘
                                │
                    ┌───────────▼───────────┐
                    │    Verification       │
                    │                       │
                    │  OpenTimestamps       │
                    │  Bitcoin-anchored     │
                    │  Proof of existence   │
                    └───────────────────────┘
```

## Milestones

### M1: Solid Foundation (v0.1.0)

Fix what we have, make it reliable. This is about getting the basics right before adding complexity.

**M1.1: Fix the site**
- Fix applesauce integration (getTimeline API, loading states)
- Add error handling visible to the user (relay connection failures, empty results)
- Show relay connection status in the UI
- Mobile-responsive layout

**M1.2: Fix video archiving**
- Integrate cookies.txt support into archive-url.sh
- Add cookie refresh workflow documentation
- Test with YouTube, Twitter/X, Vimeo
- Handle large files gracefully (progress reporting, retry on failure)

**M1.3: Harden the pipeline**
- Retry logic for Blossom uploads (transient failures)
- Verify upload integrity (re-download and compare hash after upload)
- Handle duplicate detection before downloading (check relays first)
- Timeout handling and cleanup of partial downloads
- Logging to a local archive log

**M1.4: GitHub push access**
- Get PAT with Contents write permission
- Set up CI/CD for auto-deploying nsite on push (GitHub Actions + nsyte)

### M2: OpenTimestamps Integration (v0.2.0)

Anchoring archives in Bitcoin. This is what makes NAAN archives legally and historically credible.

**M2.1: OTS proof generation**
- Install `ots` CLI tool
- After publishing a kind 4554 event, submit the event ID to OpenTimestamps
- Store pending OTS proofs locally (they take a few hours to confirm)
- Background job to check pending proofs and upgrade them when confirmed

**M2.2: Kind 1040 publishing**
- When an OTS proof is confirmed (Bitcoin attestation), publish kind 1040
- Tags: `e` referencing the kind 4554 event, content is the .ots file
- Publish to the same relays as the archive event

**M2.3: OTS verification in the UI**
- Show a "Bitcoin-timestamped" badge on archives that have a kind 1040 proof
- Click the badge to see the OTS details (block height, timestamp)
- Verify the proof client-side using ots-verify in the browser

**M2.4: Automated OTS pipeline**
- Cron job that checks pending timestamps every hour
- Publishes kind 1040 events as soon as proofs are confirmed
- Handles retries for failed submissions

### M3: Hashtree Integration (v0.3.0)

Large file support. Videos, datasets, full site snapshots.

**M3.1: Hashtree setup**
- Install hashtree-cli
- Configure with our Blossom servers
- Test chunked upload/download cycle

**M3.2: Integrate into archive pipeline**
- Files under 100MB: direct Blossom upload (current behavior)
- Files over 100MB: chunk via Hashtree, upload chunks to Blossom
- Add `hashtree` tag to kind 4554 event with root hash
- Add `chunks` tag with chunk count for UI display

**M3.3: Retrieval**
- Site can detect `hashtree` tag and reassemble from chunks
- Fallback: direct download link if a Blossom server has the full file
- Progress bar for large file downloads

**M3.4: Video archiving at scale**
- Archive videos up to 4K resolution
- Multiple format support (mp4, webm)
- Thumbnail extraction and upload as separate blob
- Add `thumb` tag to kind 4554 for preview in the index

### M4: Wayback Machine (v0.4.0)

The flagship UI. Enter a URL, see its history.

**M4.1: URL timeline view**
- Search bar: enter a URL, see all archived versions
- Timeline visualization showing when snapshots were taken
- Each entry shows: date, archiver (npub), format, size, OTS status
- Click to view the archived content

**M4.2: Content viewer**
- HTML archives: render in an iframe with original styling
- PDF: embedded viewer
- Video: HTML5 player with Blossom source
- Images: lightbox viewer
- WACZ: integrate Webrecorder's replay viewer

**M4.3: Diff view**
- Compare two snapshots of the same URL side-by-side
- Highlight what changed between versions
- Useful for tracking edits to articles, policy pages, terms of service

**M4.4: Calendar view**
- Wayback-style calendar showing which days have snapshots
- Color-coded by number of snapshots per day
- Click a day to see all snapshots from that date

**M4.5: Domain browser**
- Browse all archived URLs from a domain
- Tree view of the site structure
- Stats: total archives, total size, date range

### M5: Network Growth (v0.5.0)

Making it easy for others to run NAAN nodes and contribute.

**M5.1: Archive request board**
- New event kind (or use a standardized one) for archive requests
- Anyone can publish "please archive this URL"
- NAAN nodes monitor for requests and fulfill them
- Request status: pending, in-progress, completed (linked to kind 4554)

**M5.2: NAAN node packaging**
- Docker image with all tools (monolith, yt-dlp, nak, ots, hashtree-cli)
- Simple configuration: provide nsec, choose Blossom servers, choose relays
- Health monitoring dashboard
- Auto-update mechanism

**M5.3: Archiver leaderboard**
- Public stats page showing most active archivers (by npub)
- Total archives, total data preserved, domains covered
- Web of trust integration: trust archives from people you follow

**M5.4: Mirror protocol**
- NAAN nodes can automatically mirror archives from other nodes
- "I care about this domain, mirror all archives of it"
- BUD-04 (Blossom mirroring) for blob-level redundancy
- Configurable storage limits per node

**M5.5: ContextVM integration (long-term)**
- Expose NAAN tools as MCP services over Nostr via ContextVM
- Any AI agent can call `archive_url()`, `lookup_archive()`, `verify_ots()`
- Inter-node coordination without centralized APIs

### M6: Advanced Features (v1.0.0)

The features that make this genuinely better than the Internet Archive.

**M6.1: Scheduled archiving**
- Watch a URL and archive it on a schedule (daily, weekly)
- Detect changes before archiving (don't archive if nothing changed)
- RSS/Atom feed monitoring

**M6.2: Full-text search**
- Extract text from HTML archives
- Publish searchable index events on Nostr (or use a dedicated search relay)
- Search across all archived content

**M6.3: AI summaries**
- Generate summaries of archived content
- Store in the `content` field of kind 4554 events
- Searchable, useful for discovery

**M6.4: Browser extension**
- One-click "archive this page" from any browser
- Shows if the current page has existing archives
- Fork or extend fiatjaf's Nostr Web Archiver

**M6.5: API**
- Simple REST API: `GET /archive?url=https://example.com`
- Returns archived versions with Blossom URLs and OTS proofs
- Rate-limited, open access

**M6.6: Zap-funded archiving**
- Zap an archive event to fund the archiver
- Zap a request to incentivize archiving
- BUD-07 (payment required) for premium Blossom storage

## Event Schema

### Kind 4554: Archive Event

```json
{
  "kind": 4554,
  "content": "<optional AI summary or description>",
  "tags": [
    ["url", "<blossom URL>"],
    ["url", "<mirror blossom URL>"],
    ["r", "<original URL>"],
    ["x", "<sha256 of archived content>"],
    ["m", "<MIME type>"],
    ["format", "html|wacz|mp4|pdf|mp3|png|..."],
    ["size", "<bytes>"],
    ["title", "<content title>"],
    ["thumb", "<blossom URL of thumbnail>"],
    ["hashtree", "<root hash if chunked>"],
    ["chunks", "<chunk count if chunked>"],
    ["archived-at", "<unix timestamp of capture>"],
    ["tool", "naan|nostr-web-archiver|manual"],
    ["v", "<naan version>"]
  ]
}
```

### Kind 1040: OpenTimestamps Proof

```json
{
  "kind": 1040,
  "content": "<base64 .ots file content>",
  "tags": [
    ["e", "<kind 4554 event id>", "<relay>"]
  ]
}
```

### Kind 10063: Blossom Server List

Published by each NAAN node to declare its Blossom servers.

### Kind 30166: Relay Discovery (NIP-66)

Used by the index site to discover relays beyond the seed set.

## Technology Stack

| Component | Tool | Purpose |
|-----------|------|---------|
| Web archiving | monolith | Single-file HTML capture |
| Web archiving | Webrecorder | WACZ high-fidelity capture |
| Video archiving | yt-dlp | Download from 1000+ sites |
| Small file storage | Blossom | Content-addressed blobs |
| Large file storage | Hashtree | Chunked Merkle tree storage |
| Timestamping | OpenTimestamps | Bitcoin-anchored proofs |
| Event signing | nak | Nostr event creation |
| Index/discovery | Nostr relays | Decentralized event storage |
| Frontend SDK | applesauce | Reactive Nostr UI |
| Build tool | Vite | Fast JS bundling |
| Deployment | nsyte | Nostr-native site hosting |
| Agent runtime | OpenClaw | NAAN node orchestration |

## Design Principles

1. **Preservation over perfection.** Archive first, optimize later. A bad archive is better than no archive.

2. **Redundancy is survival.** Every blob on multiple Blossom servers. Every event on multiple relays. No single point of failure.

3. **Verifiable integrity.** SHA-256 for content, OpenTimestamps for time. Every claim is cryptographically provable.

4. **Permissionless participation.** Anyone can run a NAAN node. Anyone can archive anything. Anyone can query the index. No gatekeepers.

5. **Build on what exists.** Blossom, Hashtree, OpenTimestamps, nak, applesauce, nsyte. Don't reinvent. Wire together.

6. **Organic growth.** The network gets stronger with every archive. Popular content naturally gets more redundancy through independent archivers.

## Open Questions

1. **WACZ vs single-file HTML.** WACZ is higher fidelity but larger. Support both? Default to which?
2. **Relay selection for archive events.** Should there be dedicated "archive relays" optimized for kind 4554 queries?
3. **Content moderation.** How do nodes handle illegal content? Opt-in allowlists? Domain blocklists?
4. **Dedup coordination.** If 100 nodes archive the same URL, that's 100 events. Is relay-level dedup needed, or is client-side dedup sufficient?
5. **Storage economics.** Who pays for Blossom storage long-term? Zaps? BUD-07 payments? Donations?
6. **Archive formats.** Should we standardize on specific formats per content type, or let archivers choose?
7. **Versioning of the spec.** When the kind 4554 tag schema evolves, how do we handle backward compatibility?
