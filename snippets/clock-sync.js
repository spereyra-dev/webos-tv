// Clock correction for LG webOS TVs whose RTC resets and whose firmware has no NTP client.
// Framework-free: import it, call startClockSync() once, and format with new Date(nowMs()).
// Never trusts the device clock for display; keeps an offset instead so seconds still tick.

const PRECISE = 'https://cloudflare.com/cdn-cgi/trace'; // CORS *, ts=<epoch seconds>

let offsetMs = 0;
let synced = false;
let precise = false;
let inflight = false;

export const clockSynced = () => synced;

/** Use this instead of Date.now() for anything the user reads. */
export const nowMs = () => Date.now() + offsetMs;

function setOffset(targetMs) {
  const next = targetMs - Date.now();
  if (Math.abs(next) > 2 * 24 * 3600_000) return; // never accept absurd jumps
  offsetMs = next;
  synced = true;
}

async function syncOnce() {
  if (inflight) return;
  inflight = true;
  try {
    const r = await fetch(PRECISE, { cache: 'no-store' });
    if (!r.ok) return;
    // NOTE: the value often arrives as "1792606250.000" — decimals must be accepted,
    // otherwise this silently fails and you fall back to a 15-minute-accurate source.
    const m = /^ts=(\d+)(?:\.\d+)?$/m.exec(await r.text());
    if (!m) return;
    setOffset(Number(m[1]) * 1000);
    precise = true;
  } catch {
    /* offline: keep whatever offset we already have */
  } finally {
    inflight = false;
  }
}

/** Coarse fallback: Open-Meteo returns the local wall clock, rounded to 15 minutes. */
export function applyNetworkLocalTime(isoLocal) {
  if (precise || !isoLocal) return;
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(isoLocal);
  if (!m) return;
  const apiLocalMs = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]);
  const localWallMs = Date.now() + offsetMs - new Date().getTimezoneOffset() * 60_000;
  const next = offsetMs + (apiLocalMs - localWallMs);
  if (Math.abs(next - offsetMs) > 2 * 24 * 3600_000) return;
  offsetMs = next;
  synced = true;
}

export function startClockSync() {
  void syncOnce();
  setInterval(() => void syncOnce(), 30 * 60_000);
}
