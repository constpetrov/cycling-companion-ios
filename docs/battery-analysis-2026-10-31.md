# Battery analysis: the drain happens during rides, not at idle

**Date:** 2026-10-31. **Code:** branch `m12/ble-sensors` at `d5a17c4`. **Status:** analysis only; nothing is fixed yet.

The likeliest causes are the map with the screen on, an LLM call every minute, and best-accuracy GPS. A fourth, the ride save, gets worse as ride history grows.

This comes from reading the code and a throwaway benchmark, using Axiom's `axiom-performance` and `axiom-location` skills. There is no on-device power trace, because the iPhone was unavailable, so the ranking is a judgement and not a measurement.

## What the Battery screen shows

- **48% isn't 48 points of charge:** Apple defines this figure as the app's [share of the battery used](https://support.apple.com/en-us/102432) in that period. A long ride with little other phone use can score high.
- **Idle drain looks absent:** usage shows on only 3 of the 8 days (24, 26 and 29 Oct), about 19%, 48% and 21%. The app also schedules no background tasks. This assumes those three days were rides.
- **Not enough to explain Monday:** that needs ride length and screen-on time.

## Likely causes

| # | Cause | Where | Evidence |
|---|---|---|---|
| 1 | **Map and screen:** when the screen is on, the camera animates for 0.5 s of every second, for a barely visible shift at 1.5 km zoom. Each fix also rebuilds the map content, including the route line. "Keep screen on" is remembered between rides. | `LiveRideViewModel.swift:302`, `LiveRideMapView.swift:34`, `LiveRideMapView.swift:77` | Code only |
| 2 | **LLM call about every minute:** any open stop within 30 km trips the trigger, so calls continue through the 30-minute window when the gate must reject any suggestion. Each call can take up to 8 s, and the radio stays on after it. | `LocalTrigger.swift:36`, `RideSession.swift:190`, `GuardrailGate.swift:44` | Code only; advisor trace counts can confirm it |
| 3 | **Best-accuracy GPS:** `desiredAccuracy` is never set, so it defaults to best, although `design.md:154` and the class comment say otherwise. It also keeps running through café stops. | `CoreLocationSource.swift:26` | Code only |
| 4 | **Whole-file ride save on every fix:** each one reads, decodes, re-encodes and rewrites `rides.json`, including all past rides, which are never pruned. | `RideTracker.swift:148`, `RideStore.swift:142` | Benchmarked below |

The saves and camera moves were already deferred in the 22 Oct review, and the battery ride for task-7.4 was never recorded.

### Cost of the ride save

Timed with the real `RideStore` on an M4 Mac, with one fix per second. An iPhone 15 will be slower, and these runs had no suggestion data or sensor values.

| Past 2-hour rides | Current ride | File size | Time per save | Share of one core |
|---|---|---|---|---|
| 0 | 3 h | 1.2 MB | 24 ms | 2.4% |
| 3 | 3 h | 3.5 MB | 71 ms | 7.1% |
| 10 | 3 h | 8.9 MB | 186 ms | 18.6% |
| 30 | 3 h | 24.4 MB | 507 ms | 50.7% |

With 10 past rides, a 3-hour ride rewrites roughly 90 GB to flash. This probably wasn't the main cost yet with only a few rides, but it keeps growing.

## Checked and not the cause

- **Notifications:** real rides are capped at one per 30 minutes, so the iOS "frequently" label is unlikely to matter for battery. The cap resets if a ride resumes after the app is killed, and sped-up Demo Mode rides send them faster.
- **Route calculations:** matching a fix to the route takes 0.013 ms, and the heart-rate drift baseline about 47 ms per minute.
- **Bluetooth:** it was only committed on 31 Oct, so it's newer than these three days unless uncommitted work was running.
- **Other usual suspects:** there are no repeating animations, blur or `Timer` objects, and route polling pauses in the background. Finishing a ride stops GPS in the code, though this wasn't tested on a device.

## Still unknown

- **Locked phone:** the 1 Hz dashboard loop keeps running because nothing stops it on lock (`LiveRideScreen.swift:24`). It probably draws nothing, so only a trace can show what it costs.
- **Generic GPS advice doesn't fit:** Axiom's usual 100 m accuracy or significant-change tracking is too coarse for a 50 m route corridor.
- **Why `distanceFilter` and auto-pause aren't quick fixes:** with no fixes while stopped, three things break:
    - stop detection (`FeatureEngine.swift:146`)
    - moving time, because the café gap counts as riding (`RideTracker.swift:215`)
    - the No GPS badge, which would show falsely after 30 s (`LiveRideViewModel.swift:312`)

## Recommended fix order

1. **Skip pointless LLM calls:** don't call during the rate-limit or post-stop windows. Riders see no change, and it also cuts LLM costs.
2. **Reduce map work:** move the camera only after the rider has travelled a set distance, and stop the dashboard loop while the phone is locked.
3. **Save only the current ride, less often:** use an append-only file for the live ride, so the save no longer depends on history.
4. **Try `kCLLocationAccuracyNearestTenMeters`:** change only that setting, then compare corridor matching and speed on a real ride.
5. **Rework the trigger:** call the LLM only when a fatigue signal crosses its threshold, the set of stops changes, or the 45-minute fallback is due. This changes RULE-4, so it needs a spec update.

## How to confirm it

- **Screen vs background:** read the Activity section of the Battery screen for 26 and 29 Oct, together with the ride lengths. This shows whether the map or the background work matters more.
- **LLM calls:** count advisor traces per ride. About 60 per hour confirms cause 2.
- **Ride history:** check the size of `rides.json` with the phone connected.
- **Power trace:** record the next real ride with Settings → Developer → Performance Trace in Power Profiler mode. Do this with a Release build, unplugged, because a cabled trace reads near zero.

## Sources

- [Check battery usage on your iPhone](https://support.apple.com/en-us/102432)
- [Understand your iPhone battery usage and health](https://support.apple.com/guide/iphone/understand-iphone-battery-usage-health-iphd453d043a/ios)
