#!/usr/bin/env bash
# lookup-archive.sh — Check if a URL has been archived on Nostr (kind 4554)
# Usage: lookup-archive.sh <url>
#
# Queries relays for kind 4554 events with matching r-tag (original URL)

set -euo pipefail

URL="${1:?Usage: lookup-archive.sh <url>}"
RELAYS=("wss://relay.damus.io" "wss://relay.primal.net" "wss://nos.lol")

echo "Looking up archives for: $URL"
echo ""

for RELAY in "${RELAYS[@]}"; do
  RESULTS=$(nak req -k 4554 -t r="$URL" --limit 10 "$RELAY" 2>/dev/null || true)
  if [ -n "$RESULTS" ]; then
    echo "=== $RELAY ==="
    echo "$RESULTS" | jq -c '{
      id: .id[:16],
      pubkey: .pubkey[:16],
      created: (.created_at | todate),
      urls: [.tags[] | select(.[0]=="url") | .[1]],
      format: ([.tags[] | select(.[0]=="format") | .[1]] | first // "unknown"),
      size: ([.tags[] | select(.[0]=="size") | .[1]] | first // "?"),
      title: ([.tags[] | select(.[0]=="title") | .[1]] | first // ""),
      tool: ([.tags[] | select(.[0]=="tool") | .[1]] | first // "unknown")
    }' 2>/dev/null
    echo ""
  fi
done
