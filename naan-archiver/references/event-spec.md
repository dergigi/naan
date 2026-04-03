# NAAN Event Specification

## Kind 4554: Archive Event

Based on fiatjaf's [Nostr Web Archiver](https://github.com/fiatjaf/nostr-web-archiver). Published when content is archived.

```json
{
  "kind": 4554,
  "content": "",
  "tags": [
    ["url", "<blossom URL>"],
    ["url", "<mirror blossom URL>"],
    ["r", "<original URL>"],
    ["x", "<sha256 of archived content>"],
    ["m", "<MIME type>"],
    ["format", "html|mp4|pdf|mp3|png|..."],
    ["size", "<bytes>"],
    ["title", "<content title>"],
    ["archived-at", "<unix timestamp of capture>"],
    ["tool", "naan"]
  ]
}
```

### Tag descriptions

| Tag | Required | Description |
|-----|----------|-------------|
| `url` | yes | Blossom URL(s) where the archived content is stored. Multiple allowed for mirrors. |
| `r` | yes | Original URL that was archived. Full URL (not just domain). |
| `x` | yes | SHA-256 hash of the archived file. |
| `m` | yes | MIME type of the archived content. |
| `format` | yes | File format shorthand (html, mp4, pdf, etc.). |
| `size` | yes | File size in bytes. |
| `title` | no | Title of the content (page title, video title). |
| `archived-at` | yes | Unix timestamp of when the archive was captured. |
| `tool` | yes | Archiving tool identifier. Always `naan` for NAAN nodes. |

## Kind 1040: OpenTimestamps Proof (NIP-03)

Published when an OTS proof is confirmed with a Bitcoin attestation.

```json
{
  "kind": 1040,
  "content": "<base64 .ots file content>",
  "tags": [
    ["e", "<kind 4554 event id>", "<relay hint>"]
  ]
}
```

The `e` tag references the kind 4554 archive event that was timestamped. The content is the base64-encoded `.ots` file containing the Bitcoin attestation.

## Kind 24242: Blossom Authorization (BUD-02)

Used for authenticating uploads to Blossom servers. Not published to relays, sent as HTTP header.

```json
{
  "kind": 24242,
  "content": "Upload <filename>",
  "tags": [
    ["t", "upload"],
    ["x", "<sha256>"],
    ["expiration", "<unix timestamp>"]
  ]
}
```

## Kind 34235/34236: NIP-71 Video Events

Published alongside kind 4554 when archiving video content. Kind 34235 for landscape, 34236 for vertical. Enables playback in video clients like nostube and Amethyst.
