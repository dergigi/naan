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
