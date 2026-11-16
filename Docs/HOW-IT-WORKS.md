# How it works

Two apps, no server: a watchOS app reads heart rate from HealthKit and posts
it to a small HTTP listener inside the macOS menu-bar app on the same Wi-Fi.

```
Apple Watch (watchOS 11+)                      Mac (macOS 15+)
  Live:     workout session, ~1 reading/s        Menu-bar app
  Periodic: background wakes, ~every 15 min  ->  HTTP listener, port 5337
  URLSession, JSON + bearer token                History file + trend chart
```

## Two ways readings arrive

**Live.** The only way watchOS delivers second-by-second heart rate is an
active `HKWorkoutSession`. The app starts one of type `.other` when you tap
Go Live and discards it afterwards, so nothing is written to Health.

**Periodic.** With the app closed, watchOS decides when it may run:

- Heart-rate samples are limited to hourly HealthKit background delivery on
  watchOS (they are not on Apple's "immediate" list).
- HealthKit wakes and scheduled refreshes share a budget of about four per
  hour, and only while the app's complication is on the active watch face.

On each wake the app reads the samples HealthKit saved since the last one the
Mac confirmed (up to 200) and uploads them with a system-managed background
`URLSession`, so the transfer survives the app being suspended again. Each
sample keeps HealthKit's own timestamp; the Mac never treats an old reading
as current.

Measured on an Apple Watch Ultra over 45 minutes with the app closed: a new
reading reached the Mac every 15–17 minutes, 2–7 minutes old on arrival, and
each wake completed query, upload and confirmation in 1–8 seconds. HealthKit
itself saved a sample every 1–7 minutes; the gap is wake scheduling, which an
app cannot change.

## Pairing

The Mac shows one pairing number: a range digit, the Mac's local IPv4 address
packed into 5–10 digits, a 4-digit code, and a Luhn check digit (11 digits on
a 192.168.x.x network). The Watch has no camera and watchOS apps cannot
browse the local network, so typing is unavoidable; a digits-only keypad and
a check digit keep it short and catch typos before any network attempt. The
code is replaced after five wrong attempts. A successful pairing gives the
Watch a random 32-byte token it sends as a bearer token from then on.

## When the Mac's address changes

Routers hand out a new address now and then, usually on the same network.
After a send fails while the app is on screen, the Watch asks the other
addresses on that network `GET /hello?k=<key id>&n=<nonce>`. Only a Mac
holding the token can answer with `HMAC-SHA256(token, nonce)`, so the token
is never sent to an unknown device. The Watch then saves the new address.

watchOS allows only a few connections at a time: 40 parallel probes with a
2-second limit took 65 seconds for 253 addresses and missed the Mac. The app
therefore probes 6 at a time with a 5-second limit and tries the ranges
routers usually use (.2–.40, .100–.140) first. In the one successful
on-device test the Mac was found in under a second; a sweep of the whole
range can take several minutes and stops if the Watch screen turns off.

## Protocol

- `POST /pair` `{"code": "0427"}` -> `200 {"token": "...", "host": "..."}` or `403`
- `POST /event` (bearer token) -> `204`. Body: `event` (`hr` or `missing`),
  `bpm`, `sampleTs`, `mode` (`live`/`passive`), optional `trigger`,
  `appState`, `op`, `queuedTs`, and `history: [{t, b}]` for backfill.
- `GET /hello?k=&n=` -> `200 {"proof": "..."}` or `404`

The Mac ignores readings older than the one it shows (they still fill the
chart) and drops duplicates.

## Diagnostics

Neither log contains heart-rate values, tokens or addresses.

- Watch: `Library/Application Support/passive-trace.jsonl` in the app's
  container — one line per stage (wake, query, queue, upload result, search).
- Mac: `~/Library/Logs/HRMenuBar/ingest.jsonl` — one line per periodic packet
  with what was decided (accepted, duplicate, older).

The two share an operation id (`op`), so a reading can be followed from the
Watch's query to the Mac's decision.

## Known gaps

- Transport is plain HTTP on the local network.
- iCloud pairing (address and key only — App Review guideline 5.1.3 forbids
  storing health data in iCloud) is implemented behind the `ICLOUD_PAIRING`
  build flag and has never run, as it needs a paid developer team.
- The Watch complication shows the last reading only, not a trend.
- Not tested: networks other than 192.168.x.x, multi-hour soak, Wi-Fi loss
  mid-upload, more than one Watch.
