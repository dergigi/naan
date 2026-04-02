# 🫓 NAAN — Nostr Agentic Archiving Node

A decentralized Internet Archive built on Nostr + Blossom. No single point of failure. Content-addressed storage. Censorship-resistant by design.

NAAN nodes are agents that download, archive, and re-upload web content to [Blossom](https://github.com/hzrd149/blossom) servers, then publish archive receipts as [kind 4554](https://github.com/fiatjaf/nostr-web-archiver) events on Nostr relays — creating a queryable, decentralized index of preserved content.

## How It Works

```
URL → Download → SHA-256 → Blossom Upload → Kind 4554 Event → Nostr Relays
```

1. **Download** — Web pages via [monolith](https://github.com/nicehash/nicehash-monolith), videos via [yt-dlp](https://github.com/yt-dlp/yt-dlp)
2. **Hash** — SHA-256 for content-addressed integrity
3. **Upload** — Push to multiple Blossom servers for redundancy
4. **Publish** — Announce the archive on Nostr with full metadata (kind 4554)
5. **Discover** — Anyone can query relays for archived content by URL

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
```

### `blossom-upload.sh`

Upload a single file to a Blossom server with NIP-98 authorization.

```bash
bash scripts/blossom-upload.sh archive.html
bash scripts/blossom-upload.sh video.mp4 https://cdn.hzrd149.com
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
    ["tool", "naan"]
  ]
}
```

Query any relay for archives of a URL:

```bash
nak req -k 4554 -t r="https://example.com" wss://relay.damus.io
```

## Requirements

- [monolith](https://github.com/nicehash/nicehash-monolith) — single-file HTML archiving
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) — video downloading
- [nak](https://github.com/fiatjaf/nak) — Nostr signing and publishing
- `curl`, `jq`, `sha256sum` — standard tools
- A Nostr keypair (nsec)
- Access to Blossom servers for upload

## Building Blocks

NAAN builds on existing Nostr infrastructure:

- **[Blossom](https://github.com/hzrd149/blossom)** — Content-addressed blob storage (BUD-01 through BUD-11)
- **[Nostr Web Archiver](https://github.com/fiatjaf/nostr-web-archiver)** — fiatjaf's Chrome extension for WACZ archiving (kind 4554 origin)
- **[Hashtree](https://hashtree.cc)** — Chunked file storage for large content (by Martti Malmi)
- **[ContextVM](https://contextvm.org)** — MCP over Nostr for agent-to-agent coordination (future)

## Vision

Replace centralized archives with a network of autonomous archiving agents. Each NAAN node preserves content independently. Blossom provides redundant storage. Nostr provides the discovery layer. No single entity can shut it down.

See [RESEARCH.md](RESEARCH.md) for the full design document.

## License

MIT
