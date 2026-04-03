#!/usr/bin/env bash
# archive-url.sh — Archive a URL (web page or video), upload to Blossom, publish kind 4554
# Usage: archive-url.sh <url> [--video] [--hashtree] [--requester <pubkey>] [--dry-run]
#
# Pipeline: SingleFile → Blossom upload → (Hashtree) → Kind 4554 → OpenTimestamps
#
# Files over 50MB are automatically chunked via Hashtree for streaming support.
# Use --hashtree to force Hashtree chunking regardless of file size.
#
# Web pages are archived with SingleFile (headless Chrome).
# Video URLs are auto-detected and downloaded with yt-dlp.
#
# Requires: single-file, chromium, yt-dlp, nak, curl, jq, ots
# Optional: htree (hashtree-cli for chunked storage)
# Env: NSEC_FILE (path to nsec key)

set -euo pipefail

ARCHIVE_DIR="/data/.openclaw/agents/naan/workspace/archives"
NSEC_FILE="${NSEC_FILE:-/data/.openclaw/agents/naan/workspace/.nostr-nsec.key}"
BLOSSOM_SERVERS=("https://blossom.primal.net" "https://cdn.hzrd149.com" "https://blossom.sovereignengineering.io" "https://haven.dergigi.com")
RELAYS=("wss://relay.damus.io" "wss://relay.primal.net" "wss://nos.lol")
CHROME_PATH="${CHROME_PATH:-/usr/bin/chromium}"
COOKIES_FILE="${COOKIES_FILE:-/data/.openclaw/agents/naan/workspace/.youtube-cookies.txt}"
HTREE_THRESHOLD=${HTREE_THRESHOLD:-52428800}  # 50MB default
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

URL=""
IS_VIDEO=false
FORCE_HASHTREE=false
DRY_RUN=false
REQUESTER_PUBKEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --video) IS_VIDEO=true; shift ;;
    --hashtree) FORCE_HASHTREE=true; shift ;;
    --requester) REQUESTER_PUBKEY="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) URL="$1"; shift ;;
  esac
done

if [ -z "$URL" ]; then
  echo "Usage: archive-url.sh <url> [--video] [--hashtree] [--requester <pubkey>] [--dry-run]" >&2
  exit 1
fi

# Auto-detect video URLs
if [[ "$URL" =~ (youtube\.com|youtu\.be|vimeo\.com|twitter\.com/.*/video|x\.com/.*/video|tiktok\.com|rumble\.com) ]]; then
  IS_VIDEO=true
fi

mkdir -p "$ARCHIVE_DIR"
TIMESTAMP=$(date +%s)
SAFE_NAME=$(echo "$URL" | sed 's|https\?://||;s|[^a-zA-Z0-9]|_|g' | head -c 80)

echo "=== NAAN Archive ==="
echo "URL: $URL"
echo "Type: $([ "$IS_VIDEO" = true ] && echo "video" || echo "web page")"
echo ""

if [ "$IS_VIDEO" = true ]; then
  OUTPUT_TEMPLATE="${ARCHIVE_DIR}/${SAFE_NAME}_${TIMESTAMP}.%(ext)s"
  COOKIE_ARGS=()
  if [ -f "$COOKIES_FILE" ]; then
    COOKIE_ARGS=(--cookies "$COOKIES_FILE")
  fi

  echo "[1/3] Downloading video with yt-dlp..."
  export PATH="/data/.deno/bin:$PATH"
  yt-dlp \
    --no-playlist \
    -f "bestvideo[height<=1080]+bestaudio/best[height<=1080]/best" \
    --merge-output-format mp4 \
    --remote-components ejs:github \
    -o "$OUTPUT_TEMPLATE" \
    --write-info-json \
    "${COOKIE_ARGS[@]}" \
    "$URL" 2>&1

  # Find the downloaded file (yt-dlp resolves the extension)
  ARCHIVED_FILE=$(find "$ARCHIVE_DIR" -name "${SAFE_NAME}_${TIMESTAMP}.*" ! -name "*.info.json" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
  META_FILE="${ARCHIVE_DIR}/${SAFE_NAME}_${TIMESTAMP}.info.json"
  TITLE=$(jq -r '.title // empty' "$META_FILE" 2>/dev/null || echo "")
  FORMAT="mp4"

else
  ARCHIVED_FILE="${ARCHIVE_DIR}/${SAFE_NAME}_${TIMESTAMP}.html"
  echo "[1/3] Saving web page with SingleFile (headless Chrome)..."
  single-file \
    --browser-executable-path "$CHROME_PATH" \
    --browser-arg "--no-sandbox" \
    --browser-wait-until "networkIdle" \
    --browser-load-max-time 30000 \
    --browser-capture-max-time 30000 \
    "$URL" "$ARCHIVED_FILE" 2>&1

  if [ ! -f "$ARCHIVED_FILE" ] || [ ! -s "$ARCHIVED_FILE" ]; then
    echo "ERROR: SingleFile failed to archive $URL" >&2
    exit 1
  fi

  TITLE=$(grep -oP '<title[^>]*>\K[^<]+' "$ARCHIVED_FILE" 2>/dev/null | head -1 || echo "")
  FORMAT="html"
fi

if [ ! -f "$ARCHIVED_FILE" ] || [ ! -s "$ARCHIVED_FILE" ]; then
  echo "ERROR: Archive failed — no output file" >&2
  exit 1
fi

SHA256=$(sha256sum "$ARCHIVED_FILE" | awk '{print $1}')
FILESIZE=$(stat -c%s "$ARCHIVED_FILE")
MIMETYPE=$(file --mime-type -b "$ARCHIVED_FILE")

echo ""
echo "Archived: $(basename "$ARCHIVED_FILE")"
echo "SHA-256:  $SHA256"
echo "Size:     $FILESIZE bytes ($(numfmt --to=iec $FILESIZE))"
echo "MIME:     $MIMETYPE"
echo "Title:    ${TITLE:-<none>}"
echo ""

if [ "$DRY_RUN" = true ]; then
  echo "[DRY RUN] Would upload to Blossom and publish kind 4554"
  echo "File: $ARCHIVED_FILE"
  exit 0
fi

# Upload to Blossom servers
NSEC=$(cat "$NSEC_FILE")
BLOSSOM_URLS=()

echo "[2/3] Uploading to Blossom..."
for SERVER in "${BLOSSOM_SERVERS[@]}"; do
  NOW=$(date +%s)
  EXPIRY=$((NOW + 300))

  AUTH_EVENT=$(nak event \
    --sec "$NSEC" \
    --kind 24242 \
    -t t=upload \
    -t x="$SHA256" \
    -t expiration="$EXPIRY" \
    -c "Upload archive of $URL" \
    2>/dev/null)

  AUTH_B64=$(echo -n "$AUTH_EVENT" | base64 -w0)

  RESPONSE=$(curl -s -X PUT \
    "${SERVER}/upload" \
    -H "Authorization: Nostr ${AUTH_B64}" \
    -H "Content-Type: ${MIMETYPE}" \
    -H "X-SHA-256: ${SHA256}" \
    --data-binary "@${ARCHIVED_FILE}" \
    --max-time 120 || echo '{"error":"curl failed"}')

  BLOB_URL=$(echo "$RESPONSE" | jq -r '.url // empty' 2>/dev/null)
  if [ -n "$BLOB_URL" ]; then
    echo "  ✓ $SERVER → $BLOB_URL"
    BLOSSOM_URLS+=("$BLOB_URL")
  else
    echo "  ✗ $SERVER: $(echo "$RESPONSE" | jq -r '.message // .error // "unknown error"' 2>/dev/null)" >&2
  fi
done

if [ ${#BLOSSOM_URLS[@]} -eq 0 ]; then
  echo "ERROR: Failed to upload to any Blossom server" >&2
  exit 1
fi

# Hashtree chunking for large files (or when forced)
HTREE_ROOT=""
HTREE_BIN="${HTREE:-htree}"
USE_HASHTREE=false

if [ "$FORCE_HASHTREE" = true ]; then
  USE_HASHTREE=true
elif [ "$FILESIZE" -ge "$HTREE_THRESHOLD" ]; then
  USE_HASHTREE=true
fi

if [ "$USE_HASHTREE" = true ]; then
  if command -v "$HTREE_BIN" &>/dev/null; then
    echo ""
    echo "[2.5] Chunking with Hashtree (file >= $(numfmt --to=iec $HTREE_THRESHOLD) or forced)..."
    HTREE_OUTPUT=$(bash "$SCRIPT_DIR/hashtree-upload.sh" "$ARCHIVED_FILE" 2>&1) || true
    echo "$HTREE_OUTPUT"
    # Last line of hashtree-upload.sh output is the root hash
    HTREE_ROOT=$(echo "$HTREE_OUTPUT" | tail -1)
    if [ -n "$HTREE_ROOT" ] && [[ "$HTREE_ROOT" =~ ^[a-f0-9]{64}$ ]]; then
      FILENAME=$(basename "$ARCHIVED_FILE")
      echo "  Hashtree root: $HTREE_ROOT"
      echo "  Viewer: https://files.iris.to/#/$HTREE_ROOT/$FILENAME"
    else
      echo "  WARNING: Hashtree chunking failed or returned invalid hash (non-fatal)" >&2
      HTREE_ROOT=""
    fi
  else
    echo "  NOTE: htree not installed, skipping Hashtree chunking" >&2
  fi
fi

# Build kind 4554 event and publish
echo ""
echo "[3/3] Publishing kind 4554 to Nostr..."

TAG_ARGS=()
for BURL in "${BLOSSOM_URLS[@]}"; do
  TAG_ARGS+=(-t "url=$BURL")
done
TAG_ARGS+=(-t "r=$URL")
TAG_ARGS+=(-t "x=$SHA256")
TAG_ARGS+=(-t "m=$MIMETYPE")
TAG_ARGS+=(-t "format=$FORMAT")
TAG_ARGS+=(-t "size=$FILESIZE")
[ -n "$TITLE" ] && TAG_ARGS+=(-t "title=$TITLE")
TAG_ARGS+=(-t "archived-at=$TIMESTAMP")
TAG_ARGS+=(-t "tool=naan")
# Include requester pubkey if provided
if [ -n "$REQUESTER_PUBKEY" ]; then
  TAG_ARGS+=(-t "p=${REQUESTER_PUBKEY};;requester")
fi
# Include Hashtree root if chunking was successful
if [ -n "$HTREE_ROOT" ]; then
  TAG_ARGS+=(-t "hashtree=$HTREE_ROOT")
fi

# nak event publishes to relays given as positional args
nak event \
  --sec "$NSEC" \
  -k 4554 \
  "${TAG_ARGS[@]}" \
  -c "" \
  "${RELAYS[@]}" 2>&1

EVENT_ID=$(nak event \
  --sec "$NSEC" \
  -k 4554 \
  "${TAG_ARGS[@]}" \
  -c "" \
  --ts "$TIMESTAMP" 2>/dev/null | jq -r '.id')

# Publish NIP-71 video event (kind 34235/34236) for video archives
NIP71_EVENT_ID=""
if [ "$IS_VIDEO" = true ]; then
  echo ""
  echo "[4/5] Publishing NIP-71 video event..."
  BLOSSOM_URLS_FILE=$(mktemp)
  printf '%s\n' "${BLOSSOM_URLS[@]}" > "$BLOSSOM_URLS_FILE"
  SCRIPT_DIR_NIP71="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  NIP71_OUTPUT=$(bash "$SCRIPT_DIR_NIP71/publish-nip71.sh" "$ARCHIVED_FILE" "$META_FILE" "$URL" "$BLOSSOM_URLS_FILE" "$HTREE_ROOT" "$REQUESTER_PUBKEY" 2>&1) || true
  echo "$NIP71_OUTPUT"
  NIP71_EVENT_ID=$(echo "$NIP71_OUTPUT" | tail -1)
  rm -f "$BLOSSOM_URLS_FILE"
fi

# Submit to OpenTimestamps (NIP-03)
echo ""
echo "[$([ "$IS_VIDEO" = true ] && echo "5/5" || echo "4/4")] Submitting to OpenTimestamps..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if bash "$SCRIPT_DIR/ots-stamp.sh" "$EVENT_ID" 2>&1; then
  echo "  OTS proof pending — run ots-upgrade.sh later to finalize"
else
  echo "  WARNING: OTS stamping failed (non-fatal)" >&2
fi

# Also stamp the NIP-71 event if it was published
if [ -n "$NIP71_EVENT_ID" ] && [ "$NIP71_EVENT_ID" != "null" ]; then
  if bash "$SCRIPT_DIR/ots-stamp.sh" "$NIP71_EVENT_ID" 2>&1; then
    echo "  NIP-71 event OTS proof pending"
  fi
fi

echo ""
echo "=== Archive Complete ==="
echo "Event:    $EVENT_ID"
if [ -n "$NIP71_EVENT_ID" ] && [ "$NIP71_EVENT_ID" != "null" ]; then
  echo "NIP-71:   $NIP71_EVENT_ID"
fi
if [ -n "$HTREE_ROOT" ]; then
  FILENAME=$(basename "$ARCHIVED_FILE")
  echo "Hashtree: $HTREE_ROOT"
  echo "Viewer:   https://files.iris.to/#/$HTREE_ROOT/$FILENAME"
fi
echo "Blossom:  ${BLOSSOM_URLS[*]}"
echo "Original: $URL"
echo "OTS:      pending (run ots-upgrade.sh --publish to finalize)"
