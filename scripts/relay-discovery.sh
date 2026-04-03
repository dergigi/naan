#!/usr/bin/env bash
# relay-discovery.sh — NIP-65 relay discovery for NAAN
# Fetches kind 10002 relay list events and extracts inbox/outbox/general relays.
# Caches results to avoid redundant queries.
#
# Usage (sourced):
#   source scripts/relay-discovery.sh
#   discover_inbox_relays <pubkey>    # Returns read/general relays (where they receive)
#   discover_outbox_relays <pubkey>   # Returns write/general relays (where they publish)
#   discover_all_relays <pubkey>      # Returns all relays from kind 10002
#
# Usage (standalone):
#   bash scripts/relay-discovery.sh <pubkey> [inbox|outbox|all]
#
# Requires: nak, jq

RELAY_CACHE_DIR="${RELAY_CACHE_DIR:-${STATE_DIR:-.}/.relay-cache}"
RELAY_CACHE_TTL="${RELAY_CACHE_TTL:-3600}"  # 1 hour default

# Seed relays for discovering kind 10002 events
DISCOVERY_RELAYS=("wss://purplepag.es" "wss://relay.damus.io" "wss://relay.primal.net" "wss://nos.lol")

# Fallback relays if NIP-65 discovery fails entirely
FALLBACK_RELAYS=("wss://relay.damus.io" "wss://relay.primal.net" "wss://nos.lol")

_ensure_relay_cache() {
  mkdir -p "$RELAY_CACHE_DIR"
}

# Fetch and cache kind 10002 for a pubkey
_fetch_relay_list() {
  local pubkey="$1"
  _ensure_relay_cache

  local cache_file="$RELAY_CACHE_DIR/${pubkey}.json"
  local cache_ts_file="$RELAY_CACHE_DIR/${pubkey}.ts"
  local now
  now=$(date +%s)

  # Check cache freshness
  if [ -f "$cache_file" ] && [ -f "$cache_ts_file" ]; then
    local cached_at
    cached_at=$(cat "$cache_ts_file")
    if (( now - cached_at < RELAY_CACHE_TTL )); then
      cat "$cache_file"
      return 0
    fi
  fi

  # Query discovery relays for kind 10002
  local relay_event=""
  for relay in "${DISCOVERY_RELAYS[@]}"; do
    relay_event=$(timeout 10 nak req -k 10002 -a "$pubkey" --limit 1 "$relay" 2>/dev/null | head -1 || true)
    if [ -n "$relay_event" ]; then
      break
    fi
  done

  if [ -n "$relay_event" ]; then
    echo "$relay_event" > "$cache_file"
    echo "$now" > "$cache_ts_file"
    echo "$relay_event"
    return 0
  fi

  # Return empty if no relay list found
  echo ""
  return 1
}

# Parse relay tags from a kind 10002 event
# Output format: one relay URL per line
# Filter by: "read" (inbox), "write" (outbox), "all" (everything)
_parse_relays() {
  local event_json="$1"
  local filter="${2:-all}"

  if [ -z "$event_json" ]; then
    return 0
  fi

  case "$filter" in
    read|inbox)
      # Relays marked "read" or with no marker (general purpose)
      echo "$event_json" | jq -r '
        .tags[]
        | select(.[0] == "r")
        | if (.[2] // "") == "read" or (.[2] // "") == "" then .[1] else empty end
      ' 2>/dev/null
      ;;
    write|outbox)
      # Relays marked "write" or with no marker (general purpose)
      echo "$event_json" | jq -r '
        .tags[]
        | select(.[0] == "r")
        | if (.[2] // "") == "write" or (.[2] // "") == "" then .[1] else empty end
      ' 2>/dev/null
      ;;
    all)
      echo "$event_json" | jq -r '.tags[] | select(.[0] == "r") | .[1]' 2>/dev/null
      ;;
  esac
}

# Normalize relay URL: strip trailing slash
_normalize_relay() {
  echo "$1" | sed 's|/$||'
}

# Public API: discover inbox relays for a pubkey
discover_inbox_relays() {
  local pubkey="$1"
  local event
  event=$(_fetch_relay_list "$pubkey" 2>/dev/null) || true

  if [ -n "$event" ]; then
    local relays
    relays=$(_parse_relays "$event" "inbox")
    if [ -n "$relays" ]; then
      echo "$relays" | while read -r url; do
        _normalize_relay "$url"
      done | sort -u
      return 0
    fi
  fi

  # Fallback
  printf '%s\n' "${FALLBACK_RELAYS[@]}"
}

# Public API: discover outbox relays for a pubkey
discover_outbox_relays() {
  local pubkey="$1"
  local event
  event=$(_fetch_relay_list "$pubkey" 2>/dev/null) || true

  if [ -n "$event" ]; then
    local relays
    relays=$(_parse_relays "$event" "outbox")
    if [ -n "$relays" ]; then
      echo "$relays" | while read -r url; do
        _normalize_relay "$url"
      done | sort -u
      return 0
    fi
  fi

  # Fallback
  printf '%s\n' "${FALLBACK_RELAYS[@]}"
}

# Public API: discover all relays for a pubkey
discover_all_relays() {
  local pubkey="$1"
  local event
  event=$(_fetch_relay_list "$pubkey" 2>/dev/null) || true

  if [ -n "$event" ]; then
    local relays
    relays=$(_parse_relays "$event" "all")
    if [ -n "$relays" ]; then
      echo "$relays" | while read -r url; do
        _normalize_relay "$url"
      done | sort -u
      return 0
    fi
  fi

  # Fallback
  printf '%s\n' "${FALLBACK_RELAYS[@]}"
}

# Build a combined relay set: NAAN's inbox + sender outbox + seed relays (deduped)
build_mention_relays() {
  local naan_pubkey="$1"
  local sender_pubkey="${2:-}"

  {
    # NAAN's inbox relays (where mentions should arrive)
    discover_inbox_relays "$naan_pubkey" 2>/dev/null

    # Sender's outbox relays (where they publish)
    if [ -n "$sender_pubkey" ]; then
      discover_outbox_relays "$sender_pubkey" 2>/dev/null
    fi

    # Always include seed relays as baseline
    printf '%s\n' "${FALLBACK_RELAYS[@]}"
  } | sort -u
}

# Standalone mode
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [ $# -lt 1 ]; then
    echo "Usage: $0 <pubkey> [inbox|outbox|all]" >&2
    exit 1
  fi

  PUBKEY="$1"
  MODE="${2:-all}"

  case "$MODE" in
    inbox) discover_inbox_relays "$PUBKEY" ;;
    outbox) discover_outbox_relays "$PUBKEY" ;;
    all) discover_all_relays "$PUBKEY" ;;
    *) echo "Unknown mode: $MODE (use inbox, outbox, or all)" >&2; exit 1 ;;
  esac
fi
