import RoutePersistence

/// Filters the cached corridor's POIs to candidate stops ahead of the rider, ranks them, and
/// caps the result at 5 (RULE-18 in spec/rules.md). A pure function over already-cached data —
/// no network call, no opening-hours check (that's a separate step; see `isClosed(at:)`).
enum POILookahead {
    /// AC-21/AC-22/AC-23: a stop exactly at this distance ahead still counts as within range.
    static let lookaheadMeters: Double = 30_000
    /// AC-18/AC-19/AC-20.
    static let maxCandidates = 5

    /// Fixed priority order for ranking's type tie-break (lower index = higher priority),
    /// matching design.md's own POI type table order — cafés/bakeries first, since that's the
    /// headline use case ("a nearby stop before the rider runs out of energy").
    private static let typePriority: [String: Int] = [
        "CAFE_BAKERY_RESTAURANT": 0,
        "FOOD_SHOP": 1,
        "WATER": 2,
        "TOILETS": 3,
        "REST_SHELTER": 4,
        "BIKE_REPAIR": 5,
    ]

    /// Full pipeline (RULE-17 + RULE-18): excludes stops confirmed closed at the rider's ETA
    /// first — so a closed stop never occupies one of the 5 cap slots — then ranks and caps
    /// what's left. `etaDayOfWeek` is ISO-8601 (1 = Monday..7 = Sunday); `etaMinuteOfDay` is
    /// minutes since midnight.
    static func candidates(
        pois: [PersistedPoiInput], currentKmMarkMeters: Double, etaDayOfWeek: Int, etaMinuteOfDay: Int
    ) -> [PersistedPoiInput] {
        let open = pois.filter { !isClosed($0, dayOfWeek: etaDayOfWeek, minuteOfDay: etaMinuteOfDay) }
        return rankedCandidates(pois: open, currentKmMarkMeters: currentKmMarkMeters)
    }

    /// Candidate stops between `currentKmMarkMeters` and `lookaheadMeters` ahead, ranked by
    /// detour (ascending) then type priority, capped at `maxCandidates` (RULE-18). No opening-
    /// hours check — exposed separately so the range/rank/cap logic is independently testable
    /// from the closed-at-ETA exclusion (RULE-17). `candidates(...)` above composes both.
    static func rankedCandidates(pois: [PersistedPoiInput], currentKmMarkMeters: Double) -> [PersistedPoiInput] {
        let ahead = pois.filter { poi in
            let distanceAheadMeters = poi.kmMarkMeters - currentKmMarkMeters
            return distanceAheadMeters >= 0 && distanceAheadMeters <= lookaheadMeters
        }
        let ranked = ahead.sorted { lhs, rhs in
            if lhs.detourMeters != rhs.detourMeters {
                return lhs.detourMeters < rhs.detourMeters
            }
            return (typePriority[lhs.type] ?? Int.max) < (typePriority[rhs.type] ?? Int.max)
        }
        return Array(ranked.prefix(maxCandidates))
    }

    /// AC-24/RULE-17: a stop is excluded only on a *confirmed* closed interval — `nil`
    /// (pre-migration cache), `unknown`, and `alwaysOpen` all fail open (never excluded).
    static func isClosed(_ poi: PersistedPoiInput, dayOfWeek: Int, minuteOfDay: Int) -> Bool {
        guard let hours = poi.normalizedOpeningHours, !hours.unknown, !hours.alwaysOpen else {
            return false
        }
        let isOpenAtETA = hours.intervals.contains { interval in
            interval.dayOfWeek == dayOfWeek && minuteOfDay >= interval.startMinuteOfDay
                && minuteOfDay < interval.endMinuteOfDay
        }
        return !isOpenAtETA
    }
}
