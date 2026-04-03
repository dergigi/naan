#!/usr/bin/env bash
# publish-nip71.sh — Publish a NIP-71 video event (kind 34235/34236) to Nostr
# Usage: publish-nip71.sh <video_file> <meta_json> <original_url> <blossom_urls_file>
#
# Reads yt-dlp .info.json for metadata, constructs imeta tags, publishes.
# Outputs the event ID on success.
#
# Requires: nak, jq, ffprobe (optional, for dimensions)
# Env: NSEC_FILE (path to nsec key)

set -euo pipefail

VIDEO_FILE="${1:?Usage: publish-nip71.sh <video_file> <meta_json> <original_url> <blossom_urls_file>}"
META_JSON="${2:?Missing meta_json path}"
ORIGINAL_URL="${3:?Missing original URL}"
BLOSSOM_URLS_FILE="${4:?Missing blossom_urls_file (one URL per line)}"

NSEC_FILE="${NSEC_FILE:-/data/.openclaw/agents/naan/workspace/.nostr-nsec.key}"
RELAYS=("wss://relay.damus.io" "wss://relay.primal.net" "wss://nos.lol")

NSEC=$(cat "$NSEC_FILE")

# --- Extract metadata from yt-dlp info.json ---
TITLE=$(jq -r '.title // empty' "$META_JSON" 2>/dev/null || echo "")
DESCRIPTION=$(jq -r '.description // empty' "$META_JSON" 2>/dev/null || echo "")
DURATION=$(jq -r '.duration // empty' "$META_JSON" 2>/dev/null || echo "")
WIDTH=$(jq -r '.width // empty' "$META_JSON" 2>/dev/null || echo "")
HEIGHT=$(jq -r '.height // empty' "$META_JSON" 2>/dev/null || echo "")
UPLOAD_DATE=$(jq -r '.upload_date // empty' "$META_JSON" 2>/dev/null || echo "")
THUMBNAIL=$(jq -r '.thumbnail // empty' "$META_JSON" 2>/dev/null || echo "")
VIDEO_ID=$(jq -r '.id // empty' "$META_JSON" 2>/dev/null || echo "")
EXTRACTOR=$(jq -r '.extractor_key // .extractor // empty' "$META_JSON" 2>/dev/null || echo "")
TAGS=$(jq -r '.tags[]? // empty' "$META_JSON" 2>/dev/null || true)

# Fall back to ffprobe for dimensions if missing
if [ -z "$WIDTH" ] || [ -z "$HEIGHT" ] || [ "$WIDTH" = "null" ] || [ "$HEIGHT" = "null" ]; then
  if command -v ffprobe &>/dev/null; then
    DIMS=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$VIDEO_FILE" 2>/dev/null || echo "")
    if [ -n "$DIMS" ]; then
      WIDTH=$(echo "$DIMS" | cut -d',' -f1)
      HEIGHT=$(echo "$DIMS" | cut -d',' -f2)
    fi
  fi
fi

# Determine orientation: vertical if height > width
IS_VERTICAL=false
if [ -n "$WIDTH" ] && [ -n "$HEIGHT" ] && [ "$WIDTH" != "null" ] && [ "$HEIGHT" != "null" ]; then
  if [ "$HEIGHT" -gt "$WIDTH" ] 2>/dev/null; then
    IS_VERTICAL=true
  fi
fi

# Kind: 34235 for landscape, 34236 for vertical/shorts
if [ "$IS_VERTICAL" = true ]; then
  KIND=34236
else
  KIND=34235
fi

# File properties
SHA256=$(sha256sum "$VIDEO_FILE" | awk '{print $1}')
FILESIZE=$(stat -c%s "$VIDEO_FILE")
MIMETYPE=$(file --mime-type -b "$VIDEO_FILE")

# Read Blossom URLs
mapfile -t BLOSSOM_URLS < "$BLOSSOM_URLS_FILE"

if [ ${#BLOSSOM_URLS[@]} -eq 0 ]; then
  echo "ERROR: No Blossom URLs provided" >&2
  exit 1
fi

PRIMARY_URL="${BLOSSOM_URLS[0]}"

# --- Build d-tag for dedup ---
EXTRACTOR_LOWER=$(echo "$EXTRACTOR" | tr '[:upper:]' '[:lower:]')
if [ -n "$VIDEO_ID" ] && [ "$VIDEO_ID" != "null" ] && [ -n "$EXTRACTOR_LOWER" ]; then
  D_TAG="${EXTRACTOR_LOWER}:${VIDEO_ID}"
else
  D_TAG="naan:${SHA256}"
fi

# --- Build imeta for video ---
IMETA_PARTS="url ${PRIMARY_URL};m ${MIMETYPE};x ${SHA256};size ${FILESIZE}"

if [ -n "$WIDTH" ] && [ -n "$HEIGHT" ] && [ "$WIDTH" != "null" ] && [ "$HEIGHT" != "null" ]; then
  IMETA_PARTS="${IMETA_PARTS};dim ${WIDTH}x${HEIGHT}"
fi

# Add fallback URLs (mirrors)
for ((i=1; i<${#BLOSSOM_URLS[@]}; i++)); do
  IMETA_PARTS="${IMETA_PARTS};fallback ${BLOSSOM_URLS[$i]}"
done

# Add thumbnail if available
if [ -n "$THUMBNAIL" ] && [ "$THUMBNAIL" != "null" ]; then
  IMETA_PARTS="${IMETA_PARTS};image ${THUMBNAIL}"
fi

# --- Build tag args ---
TAG_ARGS=()
TAG_ARGS+=(-d "$D_TAG")
TAG_ARGS+=(-t "imeta=${IMETA_PARTS}")

# Title
if [ -n "$TITLE" ] && [ "$TITLE" != "null" ]; then
  TAG_ARGS+=(-t "title=${TITLE}")
fi

# Duration (in seconds, as string)
if [ -n "$DURATION" ] && [ "$DURATION" != "null" ]; then
  # Round to integer
  DURATION_INT=$(printf "%.0f" "$DURATION" 2>/dev/null || echo "$DURATION")
  TAG_ARGS+=(-t "duration=${DURATION_INT}")
fi

# Published at (convert YYYYMMDD to unix timestamp)
if [ -n "$UPLOAD_DATE" ] && [ "$UPLOAD_DATE" != "null" ]; then
  PUBLISHED_TS=$(date -d "${UPLOAD_DATE:0:4}-${UPLOAD_DATE:4:2}-${UPLOAD_DATE:6:2}" +%s 2>/dev/null || echo "")
  if [ -n "$PUBLISHED_TS" ]; then
    TAG_ARGS+=(-t "published_at=${PUBLISHED_TS}")
  fi
fi

# Origin tag: ["origin", "<platform>", "<video-id>", "<original-url>"]
if [ -n "$EXTRACTOR_LOWER" ] && [ -n "$VIDEO_ID" ] && [ "$VIDEO_ID" != "null" ]; then
  TAG_ARGS+=(-t "origin=${EXTRACTOR_LOWER};${VIDEO_ID};${ORIGINAL_URL}")
fi

# Hashtags from yt-dlp tags
if [ -n "$TAGS" ]; then
  while IFS= read -r tag; do
    [ -n "$tag" ] && TAG_ARGS+=(-t "t=${tag}")
  done <<< "$TAGS"
fi

# r-tag for the original URL
TAG_ARGS+=(-t "r=${ORIGINAL_URL}")

# Content: video description (truncated to 2000 chars)
CONTENT=""
if [ -n "$DESCRIPTION" ] && [ "$DESCRIPTION" != "null" ]; then
  CONTENT="${DESCRIPTION:0:2000}"
fi

echo "=== NIP-71 Video Event ==="
echo "Kind:     $KIND ($([ "$IS_VERTICAL" = true ] && echo "vertical" || echo "landscape"))"
echo "Title:    ${TITLE:-<none>}"
echo "d-tag:    $D_TAG"
echo "Duration: ${DURATION_INT:-?}s"
echo "Dims:     ${WIDTH:-?}x${HEIGHT:-?}"
echo "Primary:  $PRIMARY_URL"
echo ""

# --- Publish ---
echo "Publishing kind $KIND to Nostr..."

nak event \
  --sec "$NSEC" \
  -k "$KIND" \
  "${TAG_ARGS[@]}" \
  -c "$CONTENT" \
  "${RELAYS[@]}" 2>&1

# Get event ID (deterministic: same event without relay publish)
EVENT_ID=$(nak event \
  --sec "$NSEC" \
  -k "$KIND" \
  "${TAG_ARGS[@]}" \
  -c "$CONTENT" 2>/dev/null | jq -r '.id')

echo ""
echo "NIP-71 Event: $EVENT_ID"
echo "$EVENT_ID"
