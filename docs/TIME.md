# The clock is wrong and there is no NTP to blame

After a power loss this TV boots with its RTC at `2022-12-31 21:00` and shows that date until
something corrects it. There is nothing to correct it:

```
ntpd: no    ntpdate: no    sntp: no    chronyd: no    ntp-ish process: none
```

You can set it by hand as root (`date -s '2026-10-21 15:04:00'`) and set the zone through
`com.webos.settingsservice`, but with no boot hook on a non-Dev-Mode TV nothing re-applies it
after the next unplug.

So fix it in the client. A web app can get the time over HTTPS; what matters is **CORS** (the app
runs from `file://`, so a response without `Access-Control-Allow-Origin` is unusable) and
**precision**.

| Source | CORS | Precision | Verdict |
|---|---|---|---|
| `cloudflare.com/cdn-cgi/trace` → `ts=<epoch>` | `*` | seconds | **use this** |
| `api.open-meteo.com` → `current.time` | `*` | rounded to 15 min | coarse fallback only |
| `timeapi.io` | no | seconds | blocked by CORS |
| `worldtimeapi.org` | `*` (claimed) | seconds | did not answer |

Two details that cost us time:

1. Cloudflare's `ts` arrives as `ts=1792606250.000` — **with decimals**. A regex like `/^ts=(\d+)$/`
   fails silently and you fall back to the coarse source without noticing. Accept `(?:\.\d+)?`.
2. Never trust the device's fields: keep an **offset** and add it to `Date.now()`, so the seconds
   tick normally instead of freezing until the next sync.

`snippets/clock-sync.js` is the drop-in (framework-free, ~40 lines). It re-syncs every 30 minutes
and refuses absurd jumps, so a broken response can never move the clock by days.
