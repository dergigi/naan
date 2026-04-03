#!/usr/bin/env bash
# naan-common.sh — Shared configuration and helpers for NAAN archiver scripts
# Source this file at the top of each script: source "$(dirname "$0")/naan-common.sh"

set -euo pipefail

# Resolve paths relative to the workspace (parent of scripts/)
NAAN_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAAN_WORKSPACE="$(dirname "$NAAN_SCRIPT_DIR")"

# Load config file if present (workspace root or parent workspace)
for _conf in "$NAAN_WORKSPACE/naan.conf" "$NAAN_WORKSPACE/../naan.conf"; do
  if [ -f "$_conf" ]; then
    # shellcheck source=/dev/null
    source "$_conf"
    break
  fi
done

# Defaults
NSEC_FILE="${NSEC_FILE:-$NAAN_WORKSPACE/.nostr-nsec.key}"
ARCHIVE_DIR="${ARCHIVE_DIR:-$NAAN_WORKSPACE/archives}"
CHROME_PATH="${CHROME_PATH:-/usr/bin/chromium}"
COOKIES_FILE="${COOKIES_FILE:-$NAAN_WORKSPACE/.youtube-cookies.txt}"
OTS_DIR="${OTS_DIR:-$ARCHIVE_DIR/ots}"
OPERATOR_PUBKEY="${OPERATOR_PUBKEY:-}"
OWNER_PUBKEY="${OWNER_PUBKEY:-}"

# Access control: owner | friends | followers | follows | anyone
ACCESS_TIER="${ACCESS_TIER:-follows}"
WHITELIST_FILE="${WHITELIST_FILE:-}"
BLACKLIST_FILE="${BLACKLIST_FILE:-}"

# Default servers and relays (space-separated strings or arrays)
_DEFAULT_BLOSSOM="https://blossom.primal.net https://cdn.hzrd149.com"
_DEFAULT_RELAYS="wss://relay.damus.io wss://relay.primal.net wss://nos.lol"

# Convert space-separated config to arrays
if [ -z "${BLOSSOM_SERVERS_ARRAY+x}" ]; then
  _blossom_str="${BLOSSOM_SERVERS:-$_DEFAULT_BLOSSOM}"
  read -ra BLOSSOM_SERVERS_ARRAY <<< "$_blossom_str"
fi

if [ -z "${RELAYS_ARRAY+x}" ]; then
  _relay_str="${RELAYS:-$_DEFAULT_RELAYS}"
  read -ra RELAYS_ARRAY <<< "$_relay_str"
fi

# Auto-discover from operator's Nostr metadata (if pubkey is set)
_naan_discover_done="${_naan_discover_done:-}"
if [ -n "$OPERATOR_PUBKEY" ] && [ -z "$_naan_discover_done" ]; then
  _naan_discover_done=1
  export _naan_discover_done

  # Discover Blossom servers from kind 10063
  if [ "${BLOSSOM_SERVERS:-}" = "$_DEFAULT_BLOSSOM" ] || [ -z "${BLOSSOM_SERVERS:-}" ]; then
    for _r in "${RELAYS_ARRAY[@]}"; do
      _discovered=$(nak req -k 10063 -a "$OPERATOR_PUBKEY" --limit 1 "$_r" 2>/dev/null | jq -r '[.tags[] | select(.[0]=="r") | .[1]] | join(" ")' 2>/dev/null || true)
      if [ -n "$_discovered" ] && [ "$_discovered" != "" ]; then
        read -ra BLOSSOM_SERVERS_ARRAY <<< "$_discovered"
        break
      fi
    done
  fi

  # Discover relays from kind 10002
  _discovered_relays=""
  for _r in "${RELAYS_ARRAY[@]}"; do
    _discovered_relays=$(nak req -k 10002 -a "$OPERATOR_PUBKEY" --limit 1 "$_r" 2>/dev/null | jq -r '[.tags[] | select(.[0]=="r") | .[1]] | join(" ")' 2>/dev/null || true)
    if [ -n "$_discovered_relays" ] && [ "$_discovered_relays" != "" ]; then
      read -ra RELAYS_ARRAY <<< "$_discovered_relays"
      break
    fi
  done
fi

# Compute node pubkey from nsec
_get_node_pubkey() {
  if [ -f "$NSEC_FILE" ]; then
    local nsec
    nsec=$(cat "$NSEC_FILE")
    nak key public "$nsec" 2>/dev/null || true
  fi
}

NODE_PUBKEY="${NODE_PUBKEY:-$(_get_node_pubkey)}"

# Read nsec helper
_read_nsec() {
  cat "$NSEC_FILE"
}

# --- Access Control Helpers ---

# Check if a pubkey is in a file (one hex pubkey per line)
_pubkey_in_file() {
  local pubkey="$1"
  local filepath="$2"
  [ -n "$filepath" ] && [ -f "$filepath" ] && grep -qxF "$pubkey" "$filepath" 2>/dev/null
}

# Check if pubkey is blacklisted
is_blacklisted() {
  _pubkey_in_file "$1" "$BLACKLIST_FILE"
}

# Check if pubkey is whitelisted
is_whitelisted() {
  _pubkey_in_file "$1" "$WHITELIST_FILE"
}

# Check if pubkey follows the owner (sender has owner in their kind 3)
_pubkey_follows_owner() {
  local pubkey="$1"
  for relay in "${RELAYS_ARRAY[@]}"; do
    local contact_event
    contact_event=$(nak req -k 3 -a "$pubkey" --limit 1 "$relay" 2>/dev/null | head -1 || true)
    if [ -n "$contact_event" ]; then
      if echo "$contact_event" | jq -e --arg pk "$OWNER_PUBKEY" '[.tags[] | select(.[0]=="p") | .[1]] | any(. == $pk)' > /dev/null 2>&1; then
        return 0
      fi
      return 1
    fi
  done
  return 1
}

# Fetch followers of owner (kind 3 events tagging owner). Cached.
_FOLLOWERS_CACHE="$NAAN_WORKSPACE/.mention-state/followers.json"
_FOLLOWERS_CACHE_TS="$NAAN_WORKSPACE/.mention-state/followers_ts"

fetch_followers_list() {
  local now
  now=$(date +%s)
  local cache_age=3600

  if [ -f "$_FOLLOWERS_CACHE" ] && [ -f "$_FOLLOWERS_CACHE_TS" ]; then
    local cached_at
    cached_at=$(cat "$_FOLLOWERS_CACHE_TS")
    if (( now - cached_at < cache_age )); then
      return 0
    fi
  fi

  echo "[WoT] Fetching owner's followers..."
  local all_followers="[]"
  for relay in "${RELAYS_ARRAY[@]}"; do
    local follower_events
    follower_events=$(nak req -k 3 -t p="$OWNER_PUBKEY" --limit 500 "$relay" 2>/dev/null || true)
    if [ -n "$follower_events" ]; then
      local follower_pubkeys
      follower_pubkeys=$(echo "$follower_events" | jq -r '.pubkey' 2>/dev/null | sort -u | jq -Rs 'split("\n") | map(select(. != ""))')
      all_followers=$(echo -e "$all_followers\n$follower_pubkeys" | jq -s 'flatten | unique')
      break
    fi
  done

  mkdir -p "$(dirname "$_FOLLOWERS_CACHE")"
  echo "$all_followers" > "$_FOLLOWERS_CACHE"
  echo "$now" > "$_FOLLOWERS_CACHE_TS"
  local count
  count=$(jq 'length' "$_FOLLOWERS_CACHE")
  echo "[WoT] Cached $count followers"
}

# Check if pubkey is in followers cache
_is_follower() {
  local pubkey="$1"
  [ -f "$_FOLLOWERS_CACHE" ] && jq -e --arg pk "$pubkey" 'any(. == $pk)' "$_FOLLOWERS_CACHE" > /dev/null 2>&1
}
