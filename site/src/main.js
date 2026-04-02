import { EventStore } from "applesauce-core";
import { getDisplayName } from "applesauce-core/helpers/profile";
import { RelayPool } from "applesauce-relay/pool";
import { onlyEvents, toEventStore } from "applesauce-relay/operators";
import { createEventLoaderForStore } from "applesauce-loaders/loaders";
import { timeout, catchError, EMPTY, merge } from "rxjs";

// --- Config ---
const SEED_RELAYS = [
  "wss://relay.damus.io",
  "wss://relay.primal.net",
  "wss://nos.lol",
];

const LOOKUP_RELAYS = ["wss://purplepag.es/", "wss://index.hzrd149.com/"];

const ARCHIVE_KIND = 4554;
const RELAY_DISCOVERY_KIND = 30166;
const MAX_DISCOVERED_RELAYS = 30;
const ARCHIVE_FILTER = { kinds: [ARCHIVE_KIND] };

// --- Core: single EventStore + RelayPool (applesauce best practice) ---
const eventStore = new EventStore();
const pool = new RelayPool();

// Connect event loader so the store can auto-fetch profiles (kind 0)
// and other missing events from relays
createEventLoaderForStore(eventStore, pool, {
  lookupRelays: LOOKUP_RELAYS,
});

// --- State ---
let discoveredRelayCount = 0;
let queriedRelayCount = 0;
const queriedRelays = new Set();
const profileCache = new Map();

// --- Helpers ---
function getTag(event, name) {
  const tag = event.tags.find((t) => t[0] === name);
  return tag ? tag[1] : null;
}

function getAllTags(event, name) {
  return event.tags.filter((t) => t[0] === name).map((t) => t[1]);
}

function formatBytes(bytes) {
  if (!bytes) return null;
  const n = parseInt(bytes);
  if (isNaN(n)) return bytes;
  if (n < 1024) return n + " B";
  if (n < 1048576) return (n / 1024).toFixed(1) + " KB";
  if (n < 1073741824) return (n / 1048576).toFixed(1) + " MB";
  return (n / 1073741824).toFixed(2) + " GB";
}

function formatDate(timestamp) {
  return new Date(timestamp * 1000).toLocaleDateString("en-US", {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function escapeHtml(str) {
  const div = document.createElement("div");
  div.textContent = str;
  return div.innerHTML;
}

// --- Profile resolution via eventStore.profile() ---
function subscribeToProfile(pubkey) {
  if (profileCache.has(pubkey)) return;
  profileCache.set(pubkey, { name: null });

  eventStore.profile(pubkey).subscribe((profile) => {
    if (profile) {
      const name = getDisplayName(profile, pubkey.substring(0, 12) + "…");
      const cached = profileCache.get(pubkey);
      if (cached && cached.name !== name) {
        cached.name = name;
        // Update DOM elements in-place (no full re-render)
        document.querySelectorAll(`[data-pubkey="${pubkey}"]`).forEach((el) => {
          el.textContent = `by ${name}`;
        });
      }
    }
  });
}

function getProfileName(pubkey) {
  const cached = profileCache.get(pubkey);
  return cached?.name || pubkey.substring(0, 12) + "…";
}

// --- Rendering ---
function updateStats() {
  const el = document.getElementById("stats");
  const count = eventStore.database.getTimeline(ARCHIVE_FILTER).length;
  const relayInfo =
    discoveredRelayCount > 0
      ? `${queriedRelayCount} relays queried (${SEED_RELAYS.length} seed + ${discoveredRelayCount} discovered via NIP-66)`
      : `${queriedRelayCount} relays queried`;
  el.innerHTML = `<span>${count}</span> archive${count !== 1 ? "s" : ""} found · ${relayInfo}`;
}

function renderArchives(events) {
  const list = document.getElementById("archiveList");
  const filter = document.getElementById("searchInput").value.toLowerCase();

  let filtered = events;
  if (filter) {
    filtered = events.filter((e) => {
      const title = (getTag(e, "title") || "").toLowerCase();
      const url = (getTag(e, "r") || "").toLowerCase();
      const pages = getAllTags(e, "page").join(" ").toLowerCase();
      return title.includes(filter) || url.includes(filter) || pages.includes(filter);
    });
  }

  updateStats();

  if (filtered.length === 0) {
    list.innerHTML = '<div class="empty">No archives found</div>';
    return;
  }

  // Subscribe to profiles for all pubkeys
  const pubkeys = new Set(filtered.map((e) => e.pubkey));
  pubkeys.forEach((pk) => subscribeToProfile(pk));

  list.innerHTML = filtered
    .map((event) => {
      const title = getTag(event, "title");
      const originalUrl = getTag(event, "r") || getAllTags(event, "page")[0] || "";
      const blossomUrls = getAllTags(event, "url");
      const format = getTag(event, "format");
      const size = getTag(event, "size");
      const mime = getTag(event, "m");
      const tool = getTag(event, "tool");
      const hash = getTag(event, "x");
      const archivedAt = getTag(event, "archived-at");
      const displayDate = archivedAt ? formatDate(parseInt(archivedAt)) : formatDate(event.created_at);
      const displayTitle = escapeHtml(title || originalUrl || "Untitled Archive");
      const profileName = getProfileName(event.pubkey);

      return `
      <div class="archive-card">
        <div class="archive-title">
          ${blossomUrls.length > 0
            ? `<a href="${escapeHtml(blossomUrls[0])}" target="_blank">${displayTitle}</a>`
            : displayTitle}
        </div>
        ${originalUrl ? `<a class="archive-url" href="${escapeHtml(originalUrl)}" target="_blank">${escapeHtml(originalUrl)}</a>` : ""}
        <div class="archive-meta">
          <span class="tag">${displayDate}</span>
          ${format ? `<span class="tag format">${escapeHtml(format.toUpperCase())}</span>` : ""}
          ${mime ? `<span class="tag">${escapeHtml(mime)}</span>` : ""}
          ${size ? `<span class="tag">${formatBytes(size)}</span>` : ""}
          ${tool ? `<span class="tag tool">${escapeHtml(tool)}</span>` : ""}
          ${hash ? `<span class="tag" title="${escapeHtml(hash)}">sha256:${escapeHtml(hash.substring(0, 12))}…</span>` : ""}
        </div>
        ${blossomUrls.length > 0 ? `
          <div class="archive-links">
            ${blossomUrls.map((u, i) => `<a href="${escapeHtml(u)}" target="_blank">📦 ${i === 0 ? "Blossom" : "Mirror " + i}</a>`).join("")}
          </div>` : ""}
        <div class="archive-pubkey" data-pubkey="${event.pubkey}">by ${escapeHtml(profileName)}</div>
      </div>`;
    })
    .join("");
}

// --- Relay Discovery (NIP-66) ---
function discoverRelays(seedRelays) {
  return new Promise((resolve) => {
    const discovered = new Set();
    let resolved = false;

    function finish() {
      if (resolved) return;
      resolved = true;
      sub.unsubscribe();
      seedRelays.forEach((r) => discovered.delete(r));
      resolve(Array.from(discovered).slice(0, MAX_DISCOVERED_RELAYS));
    }

    const sub = pool
      .subscription(seedRelays, { kinds: [RELAY_DISCOVERY_KIND], limit: 500 })
      .pipe(onlyEvents(), timeout(3000), catchError(() => EMPTY))
      .subscribe({
        next: (event) => {
          const relayUrl = getTag(event, "d");
          if (relayUrl && relayUrl.startsWith("wss://")) {
            const requiresPayment = event.tags.some((t) => t[0] === "R" && t[1] === "payment");
            const requiresAuth = event.tags.some((t) => t[0] === "R" && t[1] === "auth");
            if (!requiresPayment && !requiresAuth) discovered.add(relayUrl);
          }
        },
        complete: () => finish(),
        error: () => finish(),
      });

    setTimeout(finish, 4000);
  });
}

// --- Main ---
function fetchArchives() {
  const btn = document.getElementById("refreshBtn");
  btn.disabled = true;
  btn.textContent = "Querying relays...";

  discoveredRelayCount = 0;
  queriedRelayCount = 0;
  queriedRelays.clear();

  // Use eventStore.timeline() as a reactive subscription.
  // It fires whenever the store gets new kind 4554 events.
  eventStore.timeline(ARCHIVE_FILTER).subscribe((events) => {
    renderArchives(events);
  });

  // Query seed relays using toEventStore operator (applesauce best practice):
  // pipes events directly into the store with dedup, triggers timeline subscription
  function queryRelays(relays) {
    relays.forEach((r) => {
      if (queriedRelays.has(r)) return;
      queriedRelays.add(r);
      queriedRelayCount++;
    });

    return pool
      .subscription(relays, { kinds: [ARCHIVE_KIND], limit: 200 })
      .pipe(
        toEventStore(eventStore),
        timeout(10000),
        catchError(() => EMPTY)
      )
      .subscribe({
        complete: () => updateStats(),
      });
  }

  // Step 1: Query seed relays immediately
  queryRelays(SEED_RELAYS);

  // Step 2: Discover more relays via NIP-66 (non-blocking)
  discoverRelays(SEED_RELAYS).then((newRelays) => {
    discoveredRelayCount = newRelays.length;
    if (newRelays.length > 0) {
      btn.textContent = `Querying ${newRelays.length + SEED_RELAYS.length} relays...`;
      queryRelays(newRelays);
    }
    updateStats();
  });

  // Enable refresh after queries settle
  setTimeout(() => {
    btn.disabled = false;
    btn.textContent = "Refresh";
  }, 10000);
}

// --- Event Listeners ---
document.getElementById("searchInput").addEventListener("input", () => {
  // Re-render with current filter using latest store data
  const events = eventStore.database.getTimeline(ARCHIVE_FILTER);
  renderArchives(events);
});

document.getElementById("refreshBtn").addEventListener("click", fetchArchives);

// --- Boot ---
fetchArchives();
