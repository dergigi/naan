# NAAN Research — Nostr Agentic Archiving Node

## The Vision

A decentralized Internet Archive built on Nostr. No single point of failure. Everything identified by npubs. Agents as nodes, each with tools to download, archive, and re-upload content to Blossom. A new Nostr event kind for "archive" events that builds a queryable index of preserved content.

Name: **NAAN** (like the flatbread). Acronym: **N**ostr **A**gentic **A**rchiving **N**ode.

---

## Existing Building Blocks

### 1. Blossom (Blobs Stored Simply on Mediaservers)
- **Repo:** https://github.com/hzrd149/blossom
- **What:** HTTP endpoints for storing binary blobs, addressed by SHA-256 hash.
- **Key BUDs:**
  - BUD-01: Blob retrieval by hash
  - BUD-02: Upload + management (PUT /upload, DELETE, GET /list)
  - BUD-03: User Server List (kind 10063) — users declare their Blossom servers
  - BUD-04: Mirroring blobs across servers (PUT /mirror) — critical for redundancy
  - BUD-05: Media optimization
  - BUD-06: Upload requirements
  - BUD-07: Payment required — potential funding model
  - BUD-08: File metadata tags (aligned with NIP-94)
  - BUD-10: Blossom URI scheme
  - BUD-11: Nostr Authorization (kind 24242)
- **Relevance:** Core storage layer for NAAN. Every archived file becomes a Blossom blob, mirrored across multiple servers.

### 2. Nostr Web Archiver (fiatjaf)
- **Repo:** https://github.com/fiatjaf/nostr-web-archiver
- **Chrome extension:** https://chromewebstore.google.com/detail/nostr-web-archiver/aegkhiohbkiminnfpaekgpedkiookikg
- **What:** Fork of Webrecorder's ArchiveWeb.page. Archives websites as WACZ files, stores them on Blossom, announces on Nostr relays.
- **Format:** WACZ (Web Archive Collection Zipped) — high-fidelity web archives via Chrome debugging protocol.
- **Stack:** Webrecorder components, Blossom for storage, Nostr for discovery. Uses `@nostr/tools`, `@nostr/gadgets`.
- **Status:** v0.1.0, by fiatjaf. Early but functional.
- **Event Kind: 4554** — This is the archive announcement event. Key details from source code:
  - **Flow:** (1) Build WACZ archive from captured pages, (2) SHA-256 hash the WACZ, (3) sign a kind 24242 Blossom auth event, (4) upload WACZ to user's Blossom servers (from kind 10063), (5) publish kind 4554 event with tags.
  - **Tags produced:**
    - `["url", "<blossom URL>"]` — one per successful Blossom upload
    - `["page", "<original page URL>"]` — one per archived page
    - `["r", "<domain>"]` — domain references for queryability (archive title domain first, then other domains appearing in >10% of pages)
  - **Content:** empty string
  - **Viewer:** `https://websitestr.netlify.app/<nevent>` — renders archived WACZ
  - **Queries existing archives:** checks relays for kind 4554 events matching the same blossom hash (via URL tag containing the hash) to detect already-published archives
- **Relevance:** Direct predecessor to NAAN's browser extension. The kind 4554 event is our starting point for the archive event spec. We should extend it (add `x` hash tag, `m` MIME type, `format` tag, `archived-at` timestamp) rather than invent from scratch.

### 3. Hashtree (Martti Malmi)
- **Site:** https://hashtree.cc
- **Crate:** https://crates.io/crates/hashtree-config (v0.2.20)
- **Source:** https://git.iris.to (Martti's Nostr-native git hosting)
- **What:** Rust-based file sharing and directory support on top of Blossom + Nostr. Adds chunking, directories, encryption, and peer-to-peer transfer to Blossom's blob storage.
- **Key properties:**
  - File chunking for large files (beyond Blossom's ~100MB single-blob limit)
  - Directory/folder support via Merkle tree roots published on Nostr
  - Encrypted chunks for private sharing
  - WebRTC peer-to-peer transfer, Blossom servers as fallback
  - CLI tool (`hashtree-cli`) and git remote helper (`git-remote-htree`) for decentralized git
  - Config at `~/.hashtree/config.toml` with Blossom read/write servers + Nostr relays
  - Default servers: cdn.iris.to (read), hashtree.iris.to (read/write)
  - Max upload: 100MB per chunk
- **Relevance:** This is THE chunking layer for NAAN. Production Rust code, actively developed by Martti, published on crates.io. Handles the hard problem of archiving large content (videos, datasets, full website snapshots) while keeping everything addressable by hash and mirrored across Blossom servers.

### 3b. H.O.R.N.E.T Storage (Scionic Merkle Trees)
- **Site:** https://www.hornet.storage/nostr-lfs
- **What:** Alternative approach using "Scionic Merkle Trees" — a Merkle Tree/DAG hybrid with numbered leaves for range-based sync. More experimental than Hashtree.
- **Relevance:** Interesting research but Hashtree is more mature and better integrated with the Blossom ecosystem. Worth watching but not our primary dependency.

### 4. ArchiveBox
- **Site:** https://archivebox.io
- **Repo:** https://github.com/archivebox/archivebox
- **What:** Self-hosted, open-source web archiving. Comprehensive: saves HTML, JS, PDFs, screenshots (PNG), WARC files. Extracts articles, audio, video, clones git repos.
- **Key features:**
  - Multiple input sources: browser bookmarks, RSS, Pocket, Pinboard, manual URLs
  - Durable output formats: HTML, PDF, PNG, JSON, SQLite, WARC
  - Uses Chrome, wget, and **yt-dlp** under the hood
  - CLI, web UI, REST API
  - Scheduled archiving with dedup
- **Relevance:** Reference architecture. ArchiveBox solved the "archive everything" problem for self-hosted setups. NAAN can adopt its archiving strategies (especially the multi-format output: save HTML + screenshot + PDF + WARC) and its use of standard tools, but replace its centralized storage with Blossom + Nostr.

### 5. yt-dlp
- **Repo:** https://github.com/yt-dlp/yt-dlp
- **What:** Fork of youtube-dl. Downloads video/audio from YouTube and thousands of other sites.
- **Key features:**
  - Supports YouTube, Vimeo, Twitter, Facebook, Instagram, TikTok, Twitch, etc.
  - Quality selection up to 8K, audio extraction, subtitle/metadata download
  - Multi-threaded fragment downloads, SponsorBlock integration
  - Browser cookie extraction for authenticated content
  - Active development, very reliable
- **Relevance:** Primary tool for video archiving in NAAN. Agent downloads video via yt-dlp, uploads to Blossom (or Hashtree for large files), publishes archive event on Nostr.

### 6. Relevant Nostr NIPs
- **NIP-94 (kind 1063):** File Metadata — event for organizing shared files. Tags for URL, MIME type, SHA-256, size, dimensions, blurhash.
- **NIP-96:** HTTP File Storage Integration — REST API for file servers integrated with Nostr.
- **NIP-BE (draft):** How Nostr apps leverage Blossom for media.
- **Kind 10063:** User Server List (Blossom servers).
- **Kind 24242:** Blossom authorization token.

### 7. Other Tools Worth Noting
- **Webrecorder:** https://webrecorder.net — the underlying WACZ/WARC capture engine used by fiatjaf's extension.
- **SingleFile:** Browser extension that saves a complete web page as a single HTML file. Simpler than WACZ but very portable.
- **Monolith:** CLI tool that saves web pages as single HTML files (Rust, fast).
- **IPFS / Arweave:** Competing decentralized storage. IPFS uses Merkle DAGs (similar concept to Hashtree). Arweave is permanent storage with a token. Both centralize around their respective protocols; Nostr + Blossom is more aligned with our values.

### 8. ContextVM (MCP over Nostr)
- **Site:** https://contextvm.org
- **Docs:** https://docs.contextvm.org
- **SDK:** `@contextvm/sdk` (npm), also Rust SDK at `ContextVM/rs-sdk`
- **Repos:** https://github.com/ContextVM (sdk, relay, relatr, gateway, proxy)
- **What:** Transport layer for MCP (Model Context Protocol) over Nostr. Lets AI agents expose and consume tools/services using npubs for identity and NIP-44 for encryption.
- **Key components:**
  - **Gateway:** wraps any MCP server and exposes its capabilities over Nostr
  - **Proxy:** client-side bridge to remote MCP servers through Nostr (looks local)
  - **Relay:** simple Nostr relay implementation
  - **Relatr:** trust scoring for Nostr pubkeys via social graph analysis
- **Relevance for NAAN:**
  - **Agent-to-agent coordination:** NAAN nodes can query each other ("do you have archive of X?", "please archive Y") via MCP calls over Nostr. No centralized API.
  - **Archiving as a service:** NAAN node exposes `archive_url()`, `lookup_archive()` as MCP tools via ContextVM. Any AI agent on Nostr can call them.
  - **Trust:** Relatr's trust scoring could help weight archive reliability (trust archives from high-trust npubs).
  - **Not critical path for v1** — start with DM-based interactions, but ContextVM is the right long-term architecture for inter-node communication.

---

## Proposed Architecture

### Content Types
1. **Web pages** — WACZ (full fidelity) or single-file HTML (lightweight)
2. **Videos** — Downloaded via yt-dlp, stored as Blossom blobs or Hashtree chunks
3. **Images** — Direct Blossom upload
4. **PDFs / Documents** — Direct Blossom upload
5. **Audio / Podcasts** — Downloaded, Blossom upload
6. **Datasets / Large files** — Hashtree chunked storage

### Archive Event — Kind 4554 (Extending fiatjaf's Spec)

fiatjaf's extension already uses kind 4554 for web archive announcements. We build on this rather than inventing a new kind. The current spec is minimal (just `url`, `page`, `r` tags). NAAN extends it to cover all content types.

**Current (fiatjaf's extension):**
```json
{
  "kind": 4554,
  "content": "",
  "tags": [
    ["url", "<blossom URL of WACZ>"],
    ["page", "<archived page URL>"],
    ["r", "<domain>"]
  ]
}
```

**Proposed NAAN extension:**
```json
{
  "kind": 4554,
  "content": "<optional description or AI-generated summary>",
  "tags": [
    ["url", "<blossom URL of archived file>"],
    ["url", "<mirror blossom URL>"],
    ["r", "<original URL being archived>"],
    ["page", "<page URL>"],
    ["x", "<sha256 of archived content>"],
    ["m", "<MIME type>"],
    ["format", "wacz|html|mp4|pdf|mp3|..."],
    ["size", "<bytes>"],
    ["title", "<page/video title>"],
    ["alt", "<human-readable description>"],
    ["hashtree", "<root hash if chunked via Hashtree>"],
    ["archived-at", "<unix timestamp of capture>"],
    ["tool", "naan|nostr-web-archiver|manual"]
  ]
}
```

Key design decisions:
- **Reuse kind 4554** — backward compatible with fiatjaf's extension and websitestr viewer
- The `r` tag links to the original URL — query "has anyone archived this URL?" via relay filter `{"kinds": [4554], "#r": ["example.com"]}`
- The `x` tag is the content SHA-256 — verifiable integrity, also dedup key
- Multiple `url` tags for Blossom mirrors (same as fiatjaf's approach)
- `hashtree` tag when content is chunked via Martti's Hashtree
- `format` distinguishes web archives (wacz) from videos (mp4), documents (pdf), etc.
- `content` field can hold an AI-generated summary of the archived content (agent value-add)
- `tool` tag identifies what created the archive (useful for trust/filtering)

### NAAN Node (The Agent)
Each NAAN node is an agent with:
- **Archive tools:** Webrecorder/WACZ for pages, yt-dlp for video, wget/monolith for simple pages
- **Storage tools:** Blossom client for upload/mirror, Hashtree for large files
- **Nostr tools:** Publish archive events, query existing archives, respond to archive requests
- **Bot interface:** Accept DMs like "archive https://example.com/article" and do the work
- **Redundancy:** Mirror archived blobs to multiple Blossom servers
- **Index:** Query relays for existing archive events before re-archiving (dedup)

### Interaction Modes
1. **Browser extension** — User clicks "archive this page", extension captures WACZ, uploads to Blossom, publishes Nostr event
2. **Nostr bot (DM)** — User sends "archive <URL>" to a NAAN npub, agent does the work
3. **Nostr bot (public mention)** — Same but via public note mention
4. **CLI** — `naan archive <URL>` for power users
5. **Scheduled/bulk** — Feed a list of URLs, RSS feed, or bookmarks for batch archiving

### Discovery & Index
- Archive events published to relays create a decentralized index
- Any client can query relays for archive events matching a URL (`r` tag filter)
- A dedicated web UI (like a decentralized Wayback Machine) could query relays and display archived content
- Multiple NAAN nodes archiving the same URL creates natural redundancy

---

## Open Questions

1. **~~Event kind number~~** — RESOLVED: Use kind 4554 (fiatjaf's existing archive kind). Extend with additional tags.
2. **WACZ vs simpler formats** — WACZ is high fidelity but large. For most use cases, a single-file HTML + screenshot might suffice. Support both?
3. **Funding model** — BUD-07 (payment required) could let Blossom servers charge for storage. Zaps on archive events could fund archivers. Lightning integration is natural.
4. **Verification/trust** — How do we ensure archived content is authentic? The original URL + SHA-256 hash provides integrity, but who verifies the capture was faithful? Web of trust / follows could help (trust archives from people you follow).
5. **Copyright/legal** — Same issues as archive.org. Archiving public web pages is generally fine. Video archiving is murkier. Nodes can choose what they archive.
6. **Hashtree interop** — Hashtree is production Rust, but how many Blossom servers support chunked retrieval natively? Do we need Hashtree-aware servers or does standard Blossom blob retrieval + client-side reassembly work?
7. **Deduplication** — If 100 people archive the same YouTube video, we want dedup. SHA-256 content addressing handles this naturally at the blob level, but we need relay-level dedup for archive events too.

---

## Next Steps

1. **Deeper dive into fiatjaf's Nostr Web Archiver** — understand the WACZ format, how it publishes to relays, what event kind it uses
2. **Draft the archive event NIP** — propose a kind and tag schema
3. **Prototype the bot** — simple DM-based archiver (accept URL, download, upload to Blossom, publish event)
4. **Evaluate Hashtree** — install hashtree-cli, test chunked uploads, check interop with Blossom servers
5. **Set up a NAAN agent** — OpenClaw agent with archiving tools (yt-dlp, monolith, Blossom client)
6. **Design the browser extension** — fork fiatjaf's extension or build fresh
7. **Plan the index/discovery UI** — how users find and browse archived content
