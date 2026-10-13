import Foundation
import RoutePersistence

/// Computes a `FeatureSnapshot` from `RideTracker`'s current state every 60 seconds (RULE-2/
/// RULE-3 in spec/rules.md). An actor polling loop, mirroring `CorridorPollingService`'s
/// existing pattern — the sleep-loop shape fits here because, unlike `RideTracker` (push-based
/// off incoming fixes), `FeatureEngine` genuinely needs to wait between snapshots.
///
/// This is the first component habitually reading `RideTracker`'s `@MainActor` state from a
/// separate actor (review Risk Hotspot) — each read stays a single, quick `await`, never held
/// across a multi-step operation.
actor FeatureEngine {
    /// AC-56: meters/second of grade-adjustment per 1% grade (RULE-6) — an uncalibrated
    /// starting value (review Risk Hotspot); isolated here so it's a one-line tune later.
    private static let gradeAdjustmentPerPercent: Double = 0.1
    /// AC-6/AC-56: trailing window `speedTrend`'s slope is computed over.
    private static let speedTrendWindowSeconds: TimeInterval = 30 * 60
    /// AC-7/AC-56 (RULE-9/RULE-10): `hrDrift` has no baseline — and so reports missing —
    /// before this much moving time has accumulated.
    private static let firstHourMovingTimeSeconds: TimeInterval = 3600
    /// AC-9/AC-37/AC-38 (RULE-13): matches `RideTracker`'s own moving threshold — duplicated
    /// here since that constant is private to `RideTracker`.
    private static let movingThresholdMetersPerSecond: Double = 0.5
    /// AC-37/AC-38 (RULE-13): how long speed must stay at or below the moving threshold,
    /// continuously, to count as "a stop."
    private static let minimumStopDurationSeconds: TimeInterval = 3 * 60

    private let rideTracker: RideTracker
    private let route: [ResampledPoint]
    private let clock: Clock
    private let snapshotIntervalSeconds: TimeInterval

    private(set) var snapshots: [FeatureSnapshot] = []

    init(
        rideTracker: RideTracker, route: [ResampledPoint], clock: Clock,
        snapshotIntervalSeconds: TimeInterval = 60.0
    ) {
        self.rideTracker = rideTracker
        self.route = route
        self.clock = clock
        self.snapshotIntervalSeconds = snapshotIntervalSeconds
    }

    /// Computes one snapshot, appends it, then sleeps for the snapshot interval. Exposed
    /// separately from `run()` so tests can call it a fixed number of times directly, rather
    /// than racing to cancel an unbounded loop under a non-blocking fake clock.
    func tick() async throws {
        let snapshot = await computeSnapshot()
        snapshots.append(snapshot)
        try await clock.sleep(for: snapshotIntervalSeconds)
    }

    /// Compute + append only, no sleep (RULE-2 in spec/rules.md) — `RideSession` (Milestone 4)
    /// owns its own cadence/force-check loop and needs to run the advisor chain between a
    /// snapshot and the next wait, which `tick()`'s bundled compute+append+sleep shape doesn't
    /// allow. A pure addition: `tick()`/`run()` keep their exact Milestone 3 behavior.
    @discardableResult
    func computeAndAppendSnapshot() async -> FeatureSnapshot {
        let snapshot = await computeSnapshot()
        snapshots.append(snapshot)
        return snapshot
    }

    /// AC-1: the production entry point — runs `tick()` for the duration of a ride. Never
    /// returns in production (no injected source ever finishes mid-ride); tests call `tick()`
    /// directly instead of this.
    func run() async throws {
        while true {
            try await tick()
        }
    }

    /// `Date(timeIntervalSince1970: 0)` (not `Date()`) when no fix has arrived yet, consistent
    /// with never reading the live clock directly.
    private func computeSnapshot() async -> FeatureSnapshot {
        guard let latestFix = await rideTracker.latestFix else {
            return FeatureSnapshot(timestamp: Date(timeIntervalSince1970: 0))
        }
        let track = await rideTracker.track
        let distanceAlongRouteMeters = await rideTracker.distanceAlongRouteMeters
        let totalRouteDistanceMeters = await rideTracker.totalRouteDistanceMeters
        let movingTimeSeconds = await rideTracker.movingTimeSeconds
        let currentHeartRateBPM = await rideTracker.currentHeartRateBPM
        let currentCadenceRPM = await rideTracker.currentCadenceRPM

        let currentGradeAdjustedSpeed = gradeAdjustedSpeed(
            rawSpeed: latestFix.speedMetersPerSecond, distanceAlongRouteMeters: distanceAlongRouteMeters)

        return FeatureSnapshot(
            timestamp: latestFix.timestamp,
            speedTrend: speedTrend(
                track: track, now: latestFix.timestamp, currentGradeAdjustedSpeed: currentGradeAdjustedSpeed),
            hrDrift: hrDrift(
                track: track, currentHeartRateBPM: currentHeartRateBPM,
                currentGradeAdjustedSpeed: currentGradeAdjustedSpeed, movingTimeSeconds: movingTimeSeconds),
            cadenceDrop: cadenceDrop(track: track, currentCadenceRPM: currentCadenceRPM),
            timeSinceLastStopSeconds: timeSinceLastStopSeconds(track: track, now: latestFix.timestamp),
            remainingEffortMeters: totalRouteDistanceMeters - distanceAlongRouteMeters)
    }

    /// AC-9 (RULE-12): elapsed time since the end of the most recent qualifying stop
    /// (RULE-13), or since ride start if none has occurred yet. `nil` if `track` is empty.
    private func timeSinceLastStopSeconds(track: [PersistedRideSample], now: Date) -> Double? {
        guard let rideStart = track.first?.timestamp else {
            return nil
        }
        let lastStopEnd = mostRecentQualifyingStopEnd(track: track) ?? rideStart
        return now.timeIntervalSince(lastStopEnd)
    }

    /// AC-37/AC-38 (RULE-13): scans `track` for runs of consecutive samples at or below the
    /// moving threshold; a run qualifies as "a stop" once its own span reaches
    /// `minimumStopDurationSeconds`. Returns the end timestamp of the *most recent* qualifying
    /// run (including one still open at the end of `track`, i.e. the rider is stopped right
    /// now), or `nil` if no run ever qualified.
    private func mostRecentQualifyingStopEnd(track: [PersistedRideSample]) -> Date? {
        var lastQualifyingEnd: Date?
        var runStart: Date?
        var runEnd: Date?

        func closeRunIfQualifying() {
            guard let start = runStart, let end = runEnd, end.timeIntervalSince(start) >= Self.minimumStopDurationSeconds
            else {
                return
            }
            lastQualifyingEnd = end
        }

        for sample in track {
            if sample.speedMetersPerSecond <= Self.movingThresholdMetersPerSecond {
                if runStart == nil {
                    runStart = sample.timestamp
                }
                runEnd = sample.timestamp
            } else {
                closeRunIfQualifying()
                runStart = nil
                runEnd = nil
            }
        }
        closeRunIfQualifying()
        return lastQualifyingEnd
    }

    /// AC-6/AC-56 (RULE-8): the linear slope of grade-adjusted speed between the oldest sample
    /// still within the trailing 30-minute window and the current reading. `nil` if there's no
    /// earlier sample to compare against (e.g. the very first fix).
    private func speedTrend(track: [PersistedRideSample], now: Date, currentGradeAdjustedSpeed: Double) -> Double? {
        guard let earliest = earliestSample(in: track, within: Self.speedTrendWindowSeconds, of: now) else {
            return nil
        }
        let earliestGradeAdjusted = gradeAdjustedSpeedAtSample(earliest)
        let elapsedSeconds = now.timeIntervalSince(earliest.timestamp)
        return (currentGradeAdjustedSpeed - earliestGradeAdjusted) / elapsedSeconds
    }

    /// AC-7/AC-11/AC-56 (RULE-9/RULE-10): `nil` before the first-hour-of-moving-time baseline
    /// exists, or on a heart-rate dropout. Otherwise the current (HR ÷ grade-adjusted speed)
    /// ratio against that same ratio averaged over the ride's first hour.
    private func hrDrift(
        track: [PersistedRideSample], currentHeartRateBPM: Int?, currentGradeAdjustedSpeed: Double,
        movingTimeSeconds: Double
    ) -> Double? {
        guard movingTimeSeconds >= Self.firstHourMovingTimeSeconds, let currentHeartRateBPM,
            currentGradeAdjustedSpeed != 0
        else {
            return nil
        }
        guard let rideStart = track.first?.timestamp else {
            return nil
        }
        let baselineEnd = rideStart.addingTimeInterval(Self.firstHourMovingTimeSeconds)
        let baselineSamples = track.filter { $0.timestamp <= baselineEnd }

        let hrSamples = baselineSamples.compactMap(\.heartRateBPM)
        guard !hrSamples.isEmpty else {
            return nil
        }
        let averageHeartRateBPM = Double(hrSamples.reduce(0, +)) / Double(hrSamples.count)

        let gradeAdjustedSpeedSamples = baselineSamples.map(gradeAdjustedSpeedAtSample)
        guard !gradeAdjustedSpeedSamples.isEmpty else {
            return nil
        }
        let averageGradeAdjustedSpeed = gradeAdjustedSpeedSamples.reduce(0, +) / Double(gradeAdjustedSpeedSamples.count)
        guard averageGradeAdjustedSpeed != 0 else {
            return nil
        }

        let currentRatio = Double(currentHeartRateBPM) / currentGradeAdjustedSpeed
        let baselineRatio = averageHeartRateBPM / averageGradeAdjustedSpeed
        guard baselineRatio != 0 else {
            return nil
        }
        return currentRatio / baselineRatio - 1
    }

    /// AC-8/AC-12 (RULE-11): `nil` on a cadence dropout; otherwise current cadence minus the
    /// ride's first accepted cadence reading.
    private func cadenceDrop(track: [PersistedRideSample], currentCadenceRPM: Int?) -> Int? {
        guard let currentCadenceRPM, let firstCadenceRPM = track.first(where: { $0.cadenceRPM != nil })?.cadenceRPM
        else {
            return nil
        }
        return currentCadenceRPM - firstCadenceRPM
    }

    /// The oldest sample in `track` whose timestamp still falls within `windowSeconds` of
    /// `now`, or `nil` if every sample (including `track.first`) is older than that — meaning
    /// there's nothing recent enough to compare against.
    private func earliestSample(
        in track: [PersistedRideSample], within windowSeconds: TimeInterval, of now: Date
    ) -> PersistedRideSample? {
        let windowStart = now.addingTimeInterval(-windowSeconds)
        guard let earliest = track.first(where: { $0.timestamp >= windowStart }), earliest.timestamp < now else {
            return nil
        }
        return earliest
    }

    /// A historical sample is a single point, not a replayed freeze state (RULE-7 only
    /// applies to the *current* live reading), so its position is simply reprojected onto the
    /// route fresh.
    private func gradeAdjustedSpeedAtSample(_ sample: PersistedRideSample) -> Double {
        let projection = GeoMath.closestPointOnRoute(latitude: sample.latitude, longitude: sample.longitude, route: route)
        return gradeAdjustedSpeed(rawSpeed: sample.speedMetersPerSecond, distanceAlongRouteMeters: projection.distanceAlongRouteMeters)
    }

    /// RULE-6: `rawSpeed` normalized by the grade at `distanceAlongRouteMeters`.
    private func gradeAdjustedSpeed(rawSpeed: Double, distanceAlongRouteMeters: Double) -> Double {
        rawSpeed + gradePercent(atDistanceAlongRouteMeters: distanceAlongRouteMeters) * Self.gradeAdjustmentPerPercent
    }

    /// The grade (%) of the route segment bracketing `distance`, from the two nearest route
    /// points. `0` if the route has fewer than 2 points, elevation data is missing, or
    /// `distance` falls outside the route's own span.
    private func gradePercent(atDistanceAlongRouteMeters distance: Double) -> Double {
        guard route.count >= 2 else {
            return 0
        }
        for index in 0..<(route.count - 1) {
            let a = route[index]
            let b = route[index + 1]
            guard distance >= a.cumulativeDistanceMeters, distance <= b.cumulativeDistanceMeters else {
                continue
            }
            return segmentGradePercent(from: a, to: b)
        }
        return 0
    }

    private func segmentGradePercent(from a: ResampledPoint, to b: ResampledPoint) -> Double {
        let horizontalMeters = b.cumulativeDistanceMeters - a.cumulativeDistanceMeters
        guard horizontalMeters > 0, let elevationA = a.elevationMeters, let elevationB = b.elevationMeters else {
            return 0
        }
        return (elevationB - elevationA) / horizontalMeters * 100
    }
}
