import { EventStore } from "applesauce-core";
import { getDisplayName } from "applesauce-core/helpers/profile";
import { RelayPool } from "applesauce-relay/pool";
import { onlyEvents, toEventStore } from "applesauce-relay/operators";
import { createEventLoaderForStore } from "applesauce-loaders/loaders";
import { timeout, catchError, EMPTY } from "rxjs";

// --- Config ---
const SEED_RELAYS = [
  "wss://relay.damus.io",
  "wss://relay.primal.net",
  "wss://nos.lol",
];

const LOOKUP_RELAYS = ["wss://purplepag.es/", "wss://index.hzrd149.com/"];

const ARCHIVE_KIND = 4554;
const VIDEO_KIND_H = 34235; // NIP-71 horizontal/landscape video
const VIDEO_KIND_V = 34236; // NIP-71 vertical/shorts video
const OTS_KIND = 1040;
const RELAY_DISCOVERY_KIND = 30166;
const MAX_DISCOVERED_RELAYS = 30;
const ALL_KINDS = [ARCHIVE_KIND, VIDEO_KIND_H, VIDEO_KIND_V];
const ARCHIVE_FILTER = { kinds: ALL_KINDS };

// --- Core: single EventStore + RelayPool (applesauce best practice) ---
const eventStore = new EventStore();
const pool = new RelayPool();

createEventLoaderForStore(eventStore, pool, {
  lookupRelays: LOOKUP_RELAYS,
});

// --- State ---
let discoveredRelayCount = 0;
let queriedRelayCount = 0;
const queriedRelays = new Set();
const profileCache = new Map();

// OTS proofs: archive event ID -> true (has Bitcoin timestamp)
const otsProofs = new Map();

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

function formatDuration(seconds) {
  if (!seconds) return null;
  const s = parseInt(seconds);
  if (isNaN(s)) return null;
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  if (h > 0) return `${h}:${String(m).padStart(2, "0")}:${String(sec).padStart(2, "0")}`;
  return `${m}:${String(sec).padStart(2, "0")}`;
}

function parseImeta(event) {
  // Parse imeta tags: ["imeta", "url X", "m Y", "x Z", ...]
  const imetaTags = event.tags.filter((t) => t[0] === "imeta");
  const result = [];
  for (const tag of imetaTags) {
    const entry = {};
    for (let i = 1; i < tag.length; i++) {
      const space = tag[i].indexOf(" ");
      if (space > 0) {
        const key = tag[i].substring(0, space);
        const val = tag[i].substring(space + 1);
        if (key === "fallback") {
          entry.fallbacks = entry.fallbacks || [];
          entry.fallbacks.push(val);
        } else {
          entry[key] = val;
        }
      }
    }
    result.push(entry);
  }
  return result;
}

function isVideoEvent(event) {
  return event.kind === VIDEO_KIND_H || event.kind === VIDEO_KIND_V;
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

// --- OTS: query for kind 1040 events referencing archive events ---
function queryOtsProofs(relays, archiveEventIds) {
  if (archiveEventIds.length === 0) return;

  pool
    .subscription(relays, { kinds: [OTS_KIND], "#e": archiveEventIds, limit: 500 })
    .pipe(onlyEvents(), timeout(10000), catchError(() => EMPTY))
    .subscribe({
      next: (event) => {
        // kind 1040 references the archive event via e-tag
        const referencedId = getTag(event, "e");
        if (referencedId && !otsProofs.has(referencedId)) {
          otsProofs.set(referencedId, true);
          // Update badge in-place
          const badge = document.querySelector(`[data-ots="${referencedId}"]`);
          if (badge) {
            badge.innerHTML = '<span class="tag ots" title="Bitcoin-timestamped via OpenTimestamps (NIP-03)">₿ timestamped</span>';
          }
        }
      },
    });
}

// --- Rendering ---
function updateStats() {
  const el = document.getElementById("stats");
  const allEvents = eventStore.database.getTimeline(ARCHIVE_FILTER);
  const archiveCount = allEvents.filter((e) => e.kind === ARCHIVE_KIND).length;
  const videoCount = allEvents.filter((e) => isVideoEvent(e)).length;
  const total = allEvents.length;
  const relayInfo =
    discoveredRelayCount > 0
      ? `${queriedRelayCount} relays queried (${SEED_RELAYS.length} seed + ${discoveredRelayCount} discovered via NIP-66)`
      : `${queriedRelayCount} relays queried`;
  const countParts = [];
  if (archiveCount > 0) countParts.push(`${archiveCount} archive${archiveCount !== 1 ? "s" : ""}`);
  if (videoCount > 0) countParts.push(`${videoCount} video${videoCount !== 1 ? "s" : ""}`);
  const countStr = countParts.length > 0 ? countParts.join(", ") : `${total} item${total !== 1 ? "s" : ""}`;
  el.innerHTML = `<span>${countStr}</span> found · ${relayInfo}`;
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
      const hashtags = getAllTags(e, "t").join(" ").toLowerCase();
      return title.includes(filter) || url.includes(filter) || pages.includes(filter) || hashtags.includes(filter);
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

  // Query OTS proofs for all visible archive events
  const eventIds = filtered.map((e) => e.id);
  queryOtsProofs(SEED_RELAYS, eventIds);

  list.innerHTML = filtered
    .map((event) => {
      const isVideo = isVideoEvent(event);
      const title = getTag(event, "title");
      const originalUrl = getTag(event, "r") || getAllTags(event, "page")[0] || "";
      const profileName = getProfileName(event.pubkey);
      const hasOts = otsProofs.has(event.id);

      if (isVideo) {
        // NIP-71 video event rendering
        const imeta = parseImeta(event);
        const videoMeta = imeta.find((m) => m.m && m.m.startsWith("video/")) || imeta[0] || {};
        const thumbMeta = imeta.find((m) => m.m && m.m.startsWith("image/"));
        const duration = getTag(event, "duration");
        const publishedAt = getTag(event, "published_at");
        const origin = event.tags.find((t) => t[0] === "origin");
        const hashtags = getAllTags(event, "t");

        const videoUrl = videoMeta.url || "";
        const thumbUrl = videoMeta.image || (thumbMeta && thumbMeta.url) || "";
        const dims = videoMeta.dim || "";
        const size = videoMeta.size || "";
        const hash = videoMeta.x || "";
        const mime = videoMeta.m || "";
        const fallbacks = videoMeta.fallbacks || [];
        const allUrls = [videoUrl, ...fallbacks].filter(Boolean);

        const displayDate = publishedAt ? formatDate(parseInt(publishedAt)) : formatDate(event.created_at);
        const displayTitle = escapeHtml(title || originalUrl || "Untitled Video");
        const durationStr = formatDuration(duration);
        const kindLabel = event.kind === VIDEO_KIND_V ? "shorts" : "video";

        return `
        <div class="archive-card video-card">
          ${thumbUrl ? `
          <div class="video-thumb">
            <a href="${escapeHtml(videoUrl || originalUrl)}" target="_blank">
              <img src="${escapeHtml(thumbUrl)}" alt="${displayTitle}" loading="lazy" />
              ${durationStr ? `<span class="video-duration">${durationStr}</span>` : ""}
            </a>
          </div>` : ""}
          <div class="archive-title">
            ${videoUrl
              ? `<a href="${escapeHtml(videoUrl)}" target="_blank">${displayTitle}</a>`
              : displayTitle}
          </div>
          ${originalUrl ? `<a class="archive-url" href="${escapeHtml(originalUrl)}" target="_blank">${escapeHtml(originalUrl)}</a>` : ""}
          <div class="archive-meta">
            <span class="tag">${displayDate}</span>
            <span class="tag format">🎬 ${escapeHtml(kindLabel.toUpperCase())}</span>
            ${mime ? `<span class="tag">${escapeHtml(mime)}</span>` : ""}
            ${dims ? `<span class="tag">${escapeHtml(dims)}</span>` : ""}
            ${size ? `<span class="tag">${formatBytes(size)}</span>` : ""}
            ${durationStr ? `<span class="tag">⏱ ${durationStr}</span>` : ""}
            ${hash ? `<span class="tag" title="${escapeHtml(hash)}">sha256:${escapeHtml(hash.substring(0, 12))}…</span>` : ""}
            <span data-ots="${event.id}">${hasOts ? '<span class="tag ots" title="Bitcoin-timestamped via OpenTimestamps (NIP-03)">₿ timestamped</span>' : ""}</span>
          </div>
          ${hashtags.length > 0 ? `<div class="archive-meta">${hashtags.slice(0, 8).map((t) => `<span class="tag hashtag">#${escapeHtml(t)}</span>`).join("")}</div>` : ""}
          ${allUrls.length > 0 ? `
            <div class="archive-links">
              ${allUrls.map((u) => { try { return `<a href="${escapeHtml(u)}" target="_blank">📦 ${new URL(u).hostname}</a>`; } catch { return `<a href="${escapeHtml(u)}" target="_blank">📦 mirror</a>`; } }).join("")}
            </div>` : ""}
          ${origin ? `<div class="archive-origin">via ${escapeHtml(origin[1])}${origin[3] ? ` · <a href="${escapeHtml(origin[3])}" target="_blank">original</a>` : ""}</div>` : ""}
          <div class="archive-pubkey" data-pubkey="${event.pubkey}">by ${escapeHtml(profileName)}</div>
        </div>`;
      }

      // Standard kind 4554 archive event rendering
      const blossomUrls = getAllTags(event, "url");
      const format = getTag(event, "format");
      const size = getTag(event, "size");
      const mime = getTag(event, "m");
      const tool = getTag(event, "tool");
      const hash = getTag(event, "x");
      const archivedAt = getTag(event, "archived-at");
      const displayDate = archivedAt ? formatDate(parseInt(archivedAt)) : formatDate(event.created_at);
      const displayTitle = escapeHtml(title || originalUrl || "Untitled Archive");

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
          <span data-ots="${event.id}">${hasOts ? '<span class="tag ots" title="Bitcoin-timestamped via OpenTimestamps (NIP-03)">₿ timestamped</span>' : ""}</span>
        </div>
        ${blossomUrls.length > 0 ? `
          <div class="archive-links">
            ${blossomUrls.map((u) => { try { return `<a href="${escapeHtml(u)}" target="_blank">📦 ${new URL(u).hostname}</a>`; } catch { return `<a href="${escapeHtml(u)}" target="_blank">📦 mirror</a>`; } }).join("")}
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

  // Reactive timeline subscription — fires on new kind 4554 events
  eventStore.timeline(ARCHIVE_FILTER).subscribe((events) => {
    renderArchives(events);
  });

  // Query relays using toEventStore operator
  function queryRelays(relays) {
    relays.forEach((r) => {
      if (queriedRelays.has(r)) return;
      queriedRelays.add(r);
      queriedRelayCount++;
    });

    return pool
      .subscription(relays, { kinds: ALL_KINDS, limit: 200 })
      .pipe(
        toEventStore(eventStore),
        timeout(10000),
        catchError(() => EMPTY)
      )
      .subscribe({
        complete: () => updateStats(),
      });
  }

  queryRelays(SEED_RELAYS);

  discoverRelays(SEED_RELAYS).then((newRelays) => {
    discoveredRelayCount = newRelays.length;
    if (newRelays.length > 0) {
      btn.textContent = `Querying ${newRelays.length + SEED_RELAYS.length} relays...`;
      queryRelays(newRelays);
    }
    updateStats();
  });

  setTimeout(() => {
    btn.disabled = false;
    btn.textContent = "Refresh";
  }, 10000);
}

// --- Event Listeners ---
document.getElementById("searchInput").addEventListener("input", () => {
  const events = eventStore.database.getTimeline(ARCHIVE_FILTER);
  renderArchives(events);
});

document.getElementById("refreshBtn").addEventListener("click", fetchArchives);

// --- Boot ---
fetchArchives();
