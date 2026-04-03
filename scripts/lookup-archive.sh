#!/usr/bin/env bash
# lookup-archive.sh — Check if a URL has been archived on Nostr (kind 4554)
# Usage: lookup-archive.sh <url>
#
# Queries relays for kind 4554 events with matching r-tag (original URL)

set -euo pipefail

URL="${1:?Usage: lookup-archive.sh <url>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAAN_PUBKEY="d1ee2f8ee60e7b2496176963e9f710ca476c456f5f9be2bbe3b4f1e6c62052ff"

# Default relays, enhanced with NIP-65 discovery
RELAYS=("wss://relay.damus.io" "wss://relay.primal.net" "wss://nos.lol")
if [ -f "$SCRIPT_DIR/relay-discovery.sh" ]; then
  STATE_DIR="${STATE_DIR:-/data/.openclaw/agents/naan/workspace/.mention-state}"
  export STATE_DIR
  source "$SCRIPT_DIR/relay-discovery.sh"
  ALL=()
  while IFS= read -r r; do
    [ -n "$r" ] && ALL+=("$r")
  done < <(discover_outbox_relays "$NAAN_PUBKEY" 2>/dev/null || true)
  if [ ${#ALL[@]} -gt 0 ]; then
    declare -A _seen
    MERGED=()
    for r in "${ALL[@]}" "${RELAYS[@]}"; do
      nr=$(echo "$r" | sed 's|/$||')
      if [ -z "${_seen[$nr]+x}" ]; then
        MERGED+=("$nr")
        _seen["$nr"]=1
      fi
    done
    unset _seen
    RELAYS=("${MERGED[@]}")
  fi
fi

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
