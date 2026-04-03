#!/usr/bin/env bash
# blossom-upload.sh — Upload a file to Blossom server with NIP-98 auth
# Usage: blossom-upload.sh <file> [blossom_server_url]

source "$(dirname "$0")/naan-common.sh"

FILE="${1:?Usage: blossom-upload.sh <file> [server_url]}"
SERVER="${2:-${BLOSSOM_SERVERS_ARRAY[0]}}"

if [ ! -f "$FILE" ]; then
  echo "Error: File not found: $FILE" >&2
  exit 1
fi

NSEC=$(_read_nsec)
SHA256=$(sha256sum "$FILE" | awk '{print $1}')
FILESIZE=$(stat -c%s "$FILE")
MIMETYPE=$(file --mime-type -b "$FILE")
FILENAME=$(basename "$FILE")

NOW=$(date +%s)
EXPIRY=$((NOW + 300))

AUTH_EVENT=$(nak event \
  --sec "$NSEC" \
  --kind 24242 \
  -t t=upload \
  -t x="$SHA256" \
  -t expiration="$EXPIRY" \
  --content "Upload $FILENAME" \
  2>/dev/null)

AUTH_B64=$(echo -n "$AUTH_EVENT" | base64 -w0)

RESPONSE=$(curl -s -X PUT \
  "${SERVER}/upload" \
  -H "Authorization: Nostr ${AUTH_B64}" \
  -H "Content-Type: ${MIMETYPE}" \
  -H "X-SHA-256: ${SHA256}" \
  --data-binary "@${FILE}")

if echo "$RESPONSE" | jq -e '.url' > /dev/null 2>&1; then
  echo "$RESPONSE" | jq -c --arg sha "$SHA256" --arg size "$FILESIZE" --arg mime "$MIMETYPE" \
    '. + {sha256: $sha, size: ($size | tonumber), mime: $mime}'
else
  echo "Error uploading to $SERVER:" >&2
  echo "$RESPONSE" >&2
  exit 1
fi
