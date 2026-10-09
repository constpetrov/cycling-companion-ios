# Known Issue: SwiftData crash on Xcode 27 / iOS 27

**Status:** RESOLVED (confirmed 2026-10-08). Was blocking the persistence half of task-2.6 (AC-29).
**Environment (crashing):** Xcode 27.0 (27A266a), iOS 27.0 SDK/Simulator runtime, Swift 6.4, macOS (Darwin 27.0.0).
**Environment (fixed):** Same Xcode/toolchain, app + test deployment target lowered to iOS 17.0, run against the iOS 17.0 Simulator runtime.

## Resolution

Lowering `IPHONEOS_DEPLOYMENT_TARGET`/`project.yml`'s `deploymentTarget` from 26.0 to 17.0 and running
`CorridorPollingServiceTests.testPollsAtFixedIntervalUntilReadyThenPersists` against an iOS 17.0
Simulator (instead of iOS 27.0) makes the crash disappear entirely — no code changes needed. Full
suite (12/12 tests) passes cleanly on iOS 17.0 with no exclusions. This confirms the "recommended
next step" hypothesis below: the bug was specific to the very-new iOS 27 Simulator runtime, not a
defect in `RouteModel`/`RouteStore` or this project's code. `RoutePersistence`'s `Package.swift` was
already pinned to `.iOS(.v17)` and needed no change; `project.yml` was updated to match.

Going forward, this project targets iOS 17.0 as its minimum deployment target (and CI/local dev
should run tests against an iOS 17–26 Simulator runtime, not iOS 27, until Apple ships a fixed point
release). The investigation below is kept for reference in case iOS 27 needs revisiting later.

**Follow-up (2026-10-09):** this crash reproduced again on GitHub Actions even after the above fix,
because lowering `IPHONEOS_DEPLOYMENT_TARGET` only gates compile-time API availability — it does
not control which Simulator *runtime* actually executes the tests. `.github/workflows/ci.yml`'s
destination-selection step picked a device by name only (no `OS=` qualifier), so `xcodebuild` ran
against whatever runtime that name happened to resolve to on the hosted runner, independent of the
deployment target. Fixed by having that step explicitly enumerate available runtimes and select
the oldest one `>= 17.0`, then pass both `name=` and `OS=` in the `-destination` string. Local/CI
verification must pin the runtime explicitly, every time — the deployment target alone is not
sufficient.

## Symptom

Any `@Model` class with certain property shapes crashes on first real use (insert → save →
fetch) with:

```
Could not cast value of type '__NSCFNumber' to 'NSString'.
```

The crash originates in `libswiftCore.dylib`, is **not** a throwable Swift error — it's a fatal
runtime trap — and is not caught by `try`/`catch` around the SwiftData calls.

## Where it reproduces

- In XCTest unit tests (both hosted-in-app and standalone configurations).
- In the real app at runtime (confirmed via a temporary diagnostic call from
  `ContentView.task { }`, launched on the simulator outside of any test harness).

This rules out "XCTest-runner artifact" as the cause — it is a genuine SwiftData/Simulator
runtime bug on this SDK, not a testing-environment quirk.

## Root cause (as far as narrowed down)

The crash is tied to the **shape of the `@Model` class itself**, not to how it's used:

- A model with ≥3 plain `String`-typed stored properties reproducibly crashes on insert+save,
  regardless of property order, `@Attribute(.unique)` placement, or whether the properties are
  interspersed with other types.
- A model with ≤2 plain `String` properties (verified down to a minimal synthetic model with
  only `id` + one other string) does **not** crash in isolation.
- However, the full real-world case — a parent model with populated `@Relationship` arrays
  pointing at child `@Model` objects, then reading the relationship back after a fetch — crashes
  **even after** reducing all three involved models (`RouteModel`, `RoutePointModel`,
  `CorridorPOIModel`) to ≤2 plain strings each (closed-set string fields like `status` and
  `type` were converted to `Int` raw values specifically to test this).
- Removing `@Relationship` entirely — flattening to a single model that stores points/POIs as
  JSON-encoded `Data` blobs instead of related `@Model` objects — **still crashes** under the
  same insert → save → fetch → read cycle.

So there appear to be at least two distinct triggers on this SDK (the plain-string-count one,
and a second one affecting flat models too), and the second one was not fully isolated before
the investigation was parked.

## Workarounds attempted and ruled out

| Attempted | Result |
|---|---|
| Move `@Model` classes into a separate local Swift Package, imported normally (no `@testable`) | Still crashes — not a cross-module/`@testable` issue |
| Standalone (non-hosted) XCTest target, no `TEST_HOST` | Xcode cannot link an app target's symbols without hosting; not viable for app targets anyway |
| In-memory vs. file-backed `ModelConfiguration` | Crashes both ways |
| Convert closed-set `String` fields (`status`, `type`) to `Int` raw values | Reduces the per-model plain-string count below the observed 3-string threshold in isolation, but the real persist→fetch→read cycle still crashes |
| Remove `@Relationship` entirely; store children as JSON-encoded `Data` on a flat model | Still crashes |
| `SWIFT_VERSION: 5.0` / `swift-tools-version: 5.10` (drop Swift 6 strict concurrency) instead of 6.0 | Still crashes — not a Swift 6 concurrency-checking interaction |
| Clean build + wiped `DerivedData` (rule out stale SPM package caching) | Still crashes identically |
| Erase simulator state (rule out accumulated simulator cruft) | Still crashes identically |

## Current impact

- **`CorridorPollingService`** (import POST, auth-attached polling loop, injected `Clock`) is
  fully implemented and tested — all its own tests pass. AC-37 (keep polling while building) is
  satisfied.
- **`RouteStore.persist` / the SwiftData models** (AC-29: persist Route + CorridorPOI to
  SwiftData once ready) cannot be verified on this machine's current toolchain. The
  implementation exists (`Packages/RoutePersistence`) but its own test
  (`CorridorPollingServiceTests.testPollsAtFixedIntervalUntilReadyThenPersists`) is currently
  failing due to this environment bug, not a logic defect as far as this investigation could
  tell.

## Recommended next step

Install an older, stable Xcode (16.x / iOS 18 SDK is a safe choice) alongside Xcode 27, and
re-run the SwiftData persistence tests against that toolchain to confirm the hypothesis that
this is specific to the very-new Xcode 27/iOS 27 release rather than a defect in this project's
code. Installing an older Xcode requires Apple ID authentication (via the `xcodes` CLI, the App
Store, or a direct download from developer.apple.com), which needs to be done interactively by
whoever owns this machine.

If that confirms the hypothesis, the project should either pin CI/local development to the
older, stable Xcode until Apple ships a fixed iOS 27 point release, or file a formal bug report
with Apple (Feedback Assistant) with the minimal repro cases captured during this
investigation.
