# Manual Testing: Full App Walkthrough (Install → Meaningful Data → Real Advisor Decisions)

## Why this doc, and its scope

All 6 MVP milestones are now built — route import, ride tracking, the rule-based local advisor,
real navigation, the LLM advisor, and RAG over the rider's own history. This is the first
"exercise the whole thing as a user would" walkthrough since `milestone-2-location-and-resume.md`
(written before real navigation existed, when there was no UI to even start from). It's meant
to be followed once on a fresh checkout, not an exhaustive regression script — if it takes you
much more than an hour including one real ride, something's gone wrong.

## 0. Before you start

- **Backend running and reachable** — see `cycling-companion-backend/docs/deployment.md`.
  Variant A (`java -jar`) is the simplest for this.
- **Set `NEBIUS_API_KEY` on the backend** if you want to see real LLM-driven Advisor messages.
  Without it, every Advisor call fails and the app silently falls back to its on-device
  rule-based advisor — you won't see an error, just less personalized stop messages, so it's
  easy to mistake "no key" for "nothing's happening."
- **Xcode** with `xcodegen` installed (`brew install xcodegen` if you don't have it).

## 1. Pointing the app at your backend

`CyclingCompanionApp.swift` hardcodes `http://localhost:8080` — there's no environment variable
or build setting to override it.

- **Simulator**: works as-is. The Simulator shares the Mac's network, so `localhost:8080`
  reaches a backend running on the same Mac directly.
- **Real device**: `localhost` on the phone means the phone itself, not your Mac. You have to:
  1. Find your Mac's LAN IP (e.g. `ipconfig getifaddr en0`).
  2. Edit `backendBaseURL` in `Sources/CyclingCompanion/App/CyclingCompanionApp.swift` to
     `http://<that-ip>:8080`.
  3. Add an App Transport Security exception for that IP — the project currently has none, and
     plain HTTP to a non-loopback address is blocked by default. Add to `project.yml`'s
     `info.properties`:
     ```yaml
     NSAppTransportSecurity:
       NSExceptionDomains:
         <your-ip>:
           NSExceptionAllowsInsecureHTTPLoads: true
     ```
  4. `xcodegen generate` to regenerate the project with the updated Info.plist.
  5. Revert both edits once you're done — they're local-only scaffolding, not something to
     commit.

## 2. Install & first run

1. `xcodegen generate` (regenerates `CyclingCompanion.xcodeproj` from `project.yml`).
2. Open `CyclingCompanion.xcodeproj`, pick your Simulator or device as the run destination, ⌘R.
3. First-run permission prompts:
   - **Location**: "When In Use" first; iOS should separately prompt to upgrade to "Always"
     shortly after (background tracking needs it) — if it doesn't prompt on its own, grant it
     manually in Settings → Privacy & Security → Location Services → Cycling Companion.
   - **Notifications**: *not* requested at launch — only right before the app is about to post
     its first real stop suggestion (§4/§5). If you never see this prompt, that's a sign no
     suggestion has fired yet, not that permission handling is broken.

## 3. Get a real route

You need a real-world GPX route, not a synthetic one — POI suggestions come from real
OpenStreetMap data (Overpass), queried within 1.5km of your actual route line, so a made-up
route finds nothing.

- Export any real ride from a mapping/GPS tool (Strava, Komoot, RideWithGPS — anything that
  exports `.gpx`) covering roads/paths you'd actually recognize.
- What makes it a *good* test route:
  - **10–25km**, long enough to matter without dragging the test out.
  - Passes within **1.5km of at least one real café, bakery, or restaurant** — check on a map
    first. Without a candidate nearby, POI Lookahead has nothing to offer and the Advisor loop
    never has a reason to suggest anything.
  - A route you already ride or know well is the easiest way to guarantee both.
- Home screen → **Choose GPX File** → pick it. "Route: \<id\>" appearing means it's now your
  *current route* — everything below (including Demo Mode) rides against whichever route is
  current.

## 4. Generate meaningful data fast — Demo Mode

A single real ride (§5) validates the real GPS/background path, but it's slow and only gives
one data point. **Demo Mode** replays one bundled ~20-minute fixture ride against your current
route at up to 20x speed, through the exact same pipeline a live ride uses: tracking, feature
computation, Advisor calls, notifications, and ride upload. At 20x, the whole fixture plays out
in about a minute.

This is the fast way to get the volume two things actually need:

- **Personal baselines** (`speedVsBaseline`/`rideSoFarVsLongest`) only switch on after **5
  finished rides** — below that, both stay "missing" regardless of how the ride went.
- **RAG retrieval** has nothing to retrieve from until there's real ride/snapshot history on
  the backend.

Steps:

1. Home → **Demo Mode**.
2. Set speed to **20x**.
3. **Start Demo Ride** — you land on the live ride screen with progress moving fast.
4. Tap **Force Check** once or twice during the replay. This forces an Advisor decision
   immediately instead of waiting out the (also speed-scaled) 45-minute check cadence — at 20x
   over a ~1-minute replay, relying on that cadence to fire naturally is mostly luck; Force
   Check is the reliable way to actually see a decision.
5. Tap **Finish Ride** whenever you're satisfied — nothing requires waiting for the exact end
   of the replay, and this button is always a manual tap, live or demo.
6. **Repeat 5 times total** (back into Demo Mode, go again) to clear the personal-baseline
   floor and give RAG retrieval real history to work with.

If the backend isn't reachable when a demo ride finishes, the upload silently queues
(`PendingRideUploadQueue`) and retries on the next app launch (capped at 5 retries per launch)
— no visible error, so if you expect new backend-side history and don't see it, check the
backend is actually up rather than assuming the app is broken.

## 5. One real ride (what Demo Mode can't substitute for)

Demo Mode proves the whole decision/notification/upload pipeline without leaving your desk, but
only a real ride exercises actual CoreLocation, actual background execution, and real elapsed
wall-clock time against the Guardrail Gate's real-time gates: a 2km detour cap, a 30-minute
minimum gap between approved suggestions, and a 10-minute quiet period after a stop. Do this
once, on a real device, on the same real-POI-backed route from §3:

1. **Start Ride** from the Home screen.
2. Ride (walk or drive is fine if you're validating the pipeline rather than actually cycling)
   for at least 20–30 minutes — long enough for a nearby stop to plausibly clear the detour cap
   and rate limit above.
3. Lock the screen partway through. Confirm tracking keeps advancing in the background (the app
   sets `allowsBackgroundLocationUpdates`/disables automatic pausing specifically so this
   works) — reopen the app and check distance/time progressed while locked.
4. If a stop notification arrives, tap it and confirm it deep-links straight into the live ride
   screen, not just to the app's default launch screen.
5. Tap **Finish Ride** at the end.

## 6. Confirm it's actually meaningful

- Run one more ride (demo or real) *after* §4/§5's five rides, with a real `NEBIUS_API_KEY` set
  on the backend (§0), and look for an Advisor message that references something more specific
  than a generic fallback line — that's RAG-retrieved history actually influencing the prompt.
- Directly confirming it: query the backend's `advisor_trace` table for a recent row and check
  `retrieved_ride_ids`/`retrieved_snapshot_ids` are non-empty JSON arrays, not `[]`.

## Viewing logs

The app logs its own events (sign-in, Advisor decisions, ride ingest/retry, notifications,
route import, ride resume) via Apple's unified logging (`os.Logger`, subsystem
`com.cyclingcompanion.app`) — this persists in the system log store and survives after the
fact, unlike `print()`. Easiest: **Console.app**, select the Simulator or your connected device
in the sidebar, filter by `com.cyclingcompanion.app`. From the terminal:

- **Simulator**: the plain `log`/`log stream` commands on your Mac do *not* see Simulator
  process logs (confirmed — they return nothing even while the app is actively logging). Use
  `xcrun simctl spawn <device-id> log show --last 5m --predicate 'subsystem ==
  "com.cyclingcompanion.app"'` (or `log stream` for live tailing) instead.
- **Real device**: plain `log stream --predicate 'subsystem == "com.cyclingcompanion.app"'` on
  your Mac works directly while the device is connected.

## Notes

- The on-device rule-based fallback (`LocalAdvisor`) is indistinguishable from the LLM path at
  the UI level by design — both end in the same notification shape. To tell which one actually
  fired, check the backend's `advisor_trace.outcome`/`raw_response` for that call (nothing to
  check there at all if it never left the device), or just make sure `NEBIUS_API_KEY` is set so
  there's nothing to disambiguate.
- Demo Mode is compiled out of Release builds entirely (`#if DEBUG`) — it won't appear if you
  build/run a Release configuration.
- This doc stops at "install → generate data → confirm it's meaningful." For deeper
  CoreLocation/background-resume-specific testing, see
  `docs/manual-testing/milestone-2-location-and-resume.md` — older and predates real
  navigation, but the resume mechanics it describes haven't changed since.
