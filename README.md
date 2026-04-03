# 🫓 NAAN — Nostr Agentic Archiving Node

A decentralized Internet Archive built on Nostr + Blossom. No single point of failure. Content-addressed storage. Censorship-resistant by design.

NAAN nodes are agents that download, archive, and re-upload web content to [Blossom](https://github.com/hzrd149/blossom) servers, then publish archive receipts as [kind 4554](https://github.com/fiatjaf/nostr-web-archiver) events on Nostr relays — creating a queryable, decentralized index of preserved content.

## How It Works

```
URL → Download → SHA-256 → Blossom Upload → (Hashtree) → Kind 4554 Event → Nostr Relays
```

1. **Download** — Web pages via [SingleFile](https://github.com/nicehash/nicehash-monolith) (headless Chrome), videos via [yt-dlp](https://github.com/yt-dlp/yt-dlp)
2. **Hash** — SHA-256 for content-addressed integrity
3. **Upload** — Push to multiple Blossom servers for redundancy
4. **Chunk** — Files over 50MB are automatically split via [Hashtree](https://hashtree.cc) for streaming and P2P delivery
5. **Publish** — Announce the archive on Nostr with full metadata (kind 4554)
6. **Discover** — Anyone can query relays for archived content by URL

## Scripts

### `archive-url.sh`

Full archiving pipeline. Downloads content, uploads to Blossom, publishes to Nostr.

```bash
# Archive a web page
bash scripts/archive-url.sh https://example.com/article

# Archive a video (auto-detected for YouTube, Vimeo, Twitter, TikTok, Rumble)
bash scripts/archive-url.sh https://youtube.com/watch?v=dQw4w9WgXcQ

# Force video mode
bash scripts/archive-url.sh https://example.com/video.mp4 --video

# Dry run (download only, no upload/publish)
bash scripts/archive-url.sh https://example.com --dry-run

# Force Hashtree chunking regardless of file size
bash scripts/archive-url.sh https://example.com/large-page --hashtree
```

### `hashtree-upload.sh`

Chunk a file into a Merkle tree via Hashtree and push all chunks to Blossom servers. Returns the tree root hash. Used automatically by `archive-url.sh` for files over 50MB.

```bash
bash scripts/hashtree-upload.sh large-video.mp4
bash scripts/hashtree-upload.sh archive.html --dry-run
```

### `blossom-upload.sh`

Upload a single file to a Blossom server with NIP-98 authorization.

```bash
bash scripts/blossom-upload.sh archive.html
bash scripts/blossom-upload.sh video.mp4 https://cdn.hzrd149.com
```

### `monitor-mentions.sh`

Monitor public Nostr mentions tagging NAAN and auto-archive URLs. Access is gated by Gigi's Web of Trust (kind 3 follow list): only Gigi and accounts Gigi follows can trigger archives.

```bash
# Run the monitor (processes mentions from the last 10 minutes)
bash scripts/monitor-mentions.sh

# Dry run (show what would be archived without doing it)
bash scripts/monitor-mentions.sh --dry-run

# Check mentions since a specific timestamp
bash scripts/monitor-mentions.sh --since 1712100000
```

### `lookup-archive.sh`

Check if a URL has already been archived on Nostr.

```bash
bash scripts/lookup-archive.sh https://example.com/article
```

## Archive Event — Kind 4554

NAAN extends [fiatjaf's kind 4554](https://github.com/fiatjaf/nostr-web-archiver) with additional metadata tags:

```json
{
  "kind": 4554,
  "content": "",
  "tags": [
    ["url", "<blossom URL>"],
    ["url", "<mirror blossom URL>"],
    ["r", "<original URL>"],
    ["x", "<sha256>"],
    ["m", "<MIME type>"],
    ["format", "html|mp4|pdf|..."],
    ["size", "<bytes>"],
    ["title", "<content title>"],
    ["archived-at", "<unix timestamp>"],
    ["hashtree", "<merkle tree root hash>"],
    ["tool", "naan"]
  ]
}
```

The `hashtree` tag is included when a file was chunked via Hashtree. Clients can use this to fetch content chunk-by-chunk from Blossom servers or via WebRTC peers, enabling streaming playback for large video archives without downloading the entire file.

For video archives, NAAN also publishes NIP-71 events (kind 34235/34236) with Hashtree info in the `imeta` tag, so video clients like nostube can stream directly.

```json
{
  "kind": 34235,
  "tags": [
    ["imeta", "url <blossom_url>", "m video/mp4", "x <sha256>", "size <bytes>", "hashtree <root_hash>", "fallback <mirror_url>"],
    ["title", "Video Title"],
    ["r", "<original URL>"]
  ]
}
```

Query any relay for archives of a URL:

```bash
nak req -k 4554 -t r="https://example.com" wss://relay.damus.io
```

## OpenClaw Skill

NAAN is packaged as an [OpenClaw](https://openclaw.ai) skill in `naan-archiver/`. Any OpenClaw agent can install it to become an archival node. The skill auto-discovers Blossom servers and relays from the operator's Nostr metadata (kind 10063 and kind 10002), so configuration is minimal: provide an nsec and optionally an operator pubkey.

See `naan-archiver/SKILL.md` for setup instructions.

## Requirements

- [yt-dlp](https://github.com/yt-dlp/yt-dlp) — video downloading
- [nak](https://github.com/fiatjaf/nak) — Nostr signing and publishing
- [htree](https://github.com/mmalmi/hashtree-rs) — Hashtree CLI for chunked storage (optional, for files >50MB)
- `curl`, `jq`, `sha256sum` — standard tools
- A Nostr keypair (nsec)
- Access to Blossom servers for upload

## Building Blocks

NAAN builds on existing Nostr infrastructure:

- **[Blossom](https://github.com/hzrd149/blossom)** — Content-addressed blob storage (BUD-01 through BUD-11)
- **[Hashtree](https://hashtree.cc)** — Chunked file storage for large content (by Martti Malmi)
- **[nsite](https://github.com/nicehash/nsyte)** — Deploy websites to Nostr + Blossom. Every NAAN node serves its own archive index as an nsite
- **[ContextVM](https://contextvm.org)** — MCP over Nostr for agent-to-agent coordination (future)

## Vision

Turn every OpenClaw agent into a Nostr archival node.

The Internet Archive is fantastic, but it's a central point of failure. One organization, one jurisdiction, one domain. We can do better.

NAAN is an OpenClaw skill. Install it, give it an nsec, and your agent becomes part of a decentralized web archive. No central server, no API keys, no accounts.

Archives are requested via Nostr: tag an agent in a public note or send it a DM with a URL. The agent downloads the content, uploads it to Blossom servers, and publishes the archive metadata as a Nostr event. Anyone can query any relay to find every archived copy of a URL, from every node, with full provenance.

Each node is autonomous. It has its own keys, its own storage, its own operator. Nodes discover each other's work through Nostr relays. Blossom provides content-addressed redundancy. OpenTimestamps anchors proofs to the Bitcoin blockchain. The Web of Trust gates access.

There is no single interface. Every agent deploys its own archive index as an nsite, browseable by anyone. And since archive events are just Nostr events, any client can query and display them.

The more agents run the skill, the more resilient the archive becomes.

See [RESEARCH.md](RESEARCH.md) for the full design document.

## Inspired By

- **[Nostr Web Archiver](https://github.com/fiatjaf/nostr-web-archiver)** — fiatjaf's browser extension for archiving websites to Nostr + Blossom. Pioneered the idea of publishing web archives as Nostr events.
- **[ArchiveBox](https://archivebox.io/)** — Self-hosted internet archiving. Comprehensive, well-designed, and a proof that individuals can run their own archive. NAAN takes the same spirit and makes it decentralized.
- **[Internet Archive](https://archive.org/)** — The original. Decades of preservation work. NAAN exists because this work is too important to depend on a single organization.

## License

MIT
