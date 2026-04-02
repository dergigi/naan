#!/usr/bin/env bash
# blossom-upload.sh — Upload a file to Blossom server with NIP-98 auth
# Usage: blossom-upload.sh <file> [blossom_server_url]
#
# Requires: nak, NAAN_NSEC env var or --nsec-file
# Outputs: JSON with url and sha256

set -euo pipefail

FILE="${1:?Usage: blossom-upload.sh <file> [server_url]}"
SERVER="${2:-https://blossom.primal.net}"
# Available servers: blossom.primal.net, cdn.hzrd149.com, blossom.sovereignengineering.io, haven.dergigi.com
NSEC_FILE="${NSEC_FILE:-/data/.openclaw/agents/naan/workspace/.nostr-nsec.key}"

if [ ! -f "$FILE" ]; then
  echo "Error: File not found: $FILE" >&2
  exit 1
fi

# Read nsec
NSEC=$(cat "$NSEC_FILE")

# Compute SHA-256 of the file
SHA256=$(sha256sum "$FILE" | awk '{print $1}')
FILESIZE=$(stat -c%s "$FILE")
MIMETYPE=$(file --mime-type -b "$FILE")
FILENAME=$(basename "$FILE")

# Current time for auth event
NOW=$(date +%s)
EXPIRY=$((NOW + 300))

# Build the BUD-02 authorization event (kind 24242)
# Tags: t=upload, x=sha256, expiration
AUTH_EVENT=$(nak event \
  --sec "$NSEC" \
  --kind 24242 \
  -t t=upload \
  -t x="$SHA256" \
  -t expiration="$EXPIRY" \
  --content "Upload $FILENAME" \
  2>/dev/null)

# Base64 encode the auth event for the Authorization header
AUTH_B64=$(echo -n "$AUTH_EVENT" | base64 -w0)

# Upload to Blossom
RESPONSE=$(curl -s -X PUT \
  "${SERVER}/upload" \
  -H "Authorization: Nostr ${AUTH_B64}" \
  -H "Content-Type: ${MIMETYPE}" \
  -H "X-SHA-256: ${SHA256}" \
  --data-binary "@${FILE}")

# Check for error
if echo "$RESPONSE" | jq -e '.url' > /dev/null 2>&1; then
  echo "$RESPONSE" | jq -c --arg sha "$SHA256" --arg size "$FILESIZE" --arg mime "$MIMETYPE" \
    '. + {sha256: $sha, size: ($size | tonumber), mime: $mime}'
else
  echo "Error uploading to $SERVER:" >&2
  echo "$RESPONSE" >&2
  exit 1
fi
