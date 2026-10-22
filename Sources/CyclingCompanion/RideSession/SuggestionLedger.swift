import Foundation
import RoutePersistence

/// A stop suggestion the Guardrail Gate approved during a ride.
struct ApprovedSuggestion: Sendable, Equatable, Codable, Identifiable {
    let id: String
    let stopId: Int64
    let name: String?
    let type: String
    let latitude: Double
    let longitude: Double
    let kmMarkMeters: Double
    let detourMeters: Double
    let message: String?
    let suggestedAt: Date
}

/// The rider's answer to a suggestion. Raw values are the wire form (RULE-18 in milestone 7's
/// rules.md), matching the uppercase `outcome` field.
enum SuggestionAnswer: String, Sendable, Codable {
    case accepted = "ACCEPTED"
    case declined = "DECLINED"
    case none = "NONE"
}

struct SuggestionResponse: Sendable, Equatable, Codable {
    let suggestionId: String
    let stopId: Int64
    let suggestedAt: Date
    let answer: SuggestionAnswer
    /// When the rider answered; `nil` for `.none`.
    let respondedAt: Date?
}

/// Per-ride suggestion state (RULE-16 in milestone 7's rules.md, AC-51 to AC-65, AC-136, AC-137):
/// the suggestion on the dashboard card, every suggestion approved this ride with its answer, and
/// the stops the rider declined. Pure transitions, so every rule is unit-testable on its own.
struct SuggestionLedger: Sendable, Equatable, Codable {
    /// AC-60 to AC-63: a stop counts as passed this far beyond its km mark.
    static let passedThresholdMeters: Double = 200

    /// The suggestion shown on the card, if any.
    private(set) var current: ApprovedSuggestion?
    /// Every suggestion approved this ride, oldest first.
    private(set) var suggestions: [ApprovedSuggestion] = []
    /// Recorded answers, keyed by suggestion id.
    private(set) var answers: [String: SuggestionResponse] = [:]
    /// AC-64/AC-65: never suggested again this ride.
    private(set) var declinedStopIds: Set<Int64> = []

    init() {}

    func response(to suggestionId: String) -> SuggestionResponse? {
        answers[suggestionId]
    }

    /// The most recent suggestion for `stopId` this ride, if any (AC-137: an older notification).
    func suggestion(forStop stopId: Int64) -> ApprovedSuggestion? {
        suggestions.last { $0.stopId == stopId }
    }

    /// AC-54: the card shows "heading to" once its suggestion is accepted.
    var isCurrentAccepted: Bool {
        guard let current else { return false }
        return answers[current.id]?.answer == .accepted
    }

    /// AC-58/AC-59: a new approved suggestion takes the card. A previous one left unanswered is
    /// recorded as `.none`; an answered one keeps its answer.
    mutating func approve(_ suggestion: ApprovedSuggestion) {
        if let previous = current, answers[previous.id] == nil {
            record(.none, for: previous, at: nil)
        }
        suggestions.append(suggestion)
        current = suggestion
    }

    /// AC-53, AC-55, AC-56, AC-136, AC-137: records the rider's answer, replacing any earlier one
    /// for that suggestion (including a `.none` from being superseded or passed). A decline excludes
    /// the stop and, if it is on the card, removes the card. Returns `false` for an unknown id.
    @discardableResult
    mutating func respond(_ answer: SuggestionAnswer, to suggestionId: String, at time: Date) -> Bool {
        guard answer != .none, let suggestion = suggestions.first(where: { $0.id == suggestionId }) else {
            return false
        }
        record(answer, for: suggestion, at: time)
        if answer == .declined {
            declinedStopIds.insert(suggestion.stopId)
            if current?.id == suggestionId {
                current = nil
            }
        }
        return true
    }

    /// AC-51/AC-52: opening directions counts as accepting — but only if nothing is recorded yet
    /// (an explicit answer, or a `.none` from being superseded or passed, is kept).
    mutating func directionsOpened(for suggestionId: String, at time: Date) {
        guard answers[suggestionId] == nil else { return }
        respond(.accepted, to: suggestionId, at: time)
    }

    /// AC-60 to AC-63: once the rider is `passedThresholdMeters` beyond the card's stop, the card is
    /// removed; an unanswered suggestion becomes `.none`, an accepted one stays accepted.
    mutating func advance(toKmMark kmMarkMeters: Double) {
        guard let current, kmMarkMeters - current.kmMarkMeters >= Self.passedThresholdMeters else { return }
        if answers[current.id] == nil {
            record(.none, for: current, at: nil)
        }
        self.current = nil
    }

    /// For the upload (AC-67): one response per approved suggestion, `.none` where unanswered.
    var finalResponses: [SuggestionResponse] {
        suggestions.map { suggestion in
            answers[suggestion.id]
                ?? SuggestionResponse(
                    suggestionId: suggestion.id, stopId: suggestion.stopId, suggestedAt: suggestion.suggestedAt,
                    answer: .none, respondedAt: nil)
        }
    }

    private mutating func record(_ answer: SuggestionAnswer, for suggestion: ApprovedSuggestion, at time: Date?) {
        answers[suggestion.id] = SuggestionResponse(
            suggestionId: suggestion.id, stopId: suggestion.stopId, suggestedAt: suggestion.suggestedAt,
            answer: answer, respondedAt: answer == .none ? nil : time)
    }
}

// MARK: - Saving with the ride checkpoint (RULE-17 in milestone 7's rules.md)

extension SuggestionLedger {
    var persisted: PersistedSuggestionState {
        PersistedSuggestionState(
            currentSuggestionId: current?.id,
            suggestions: suggestions.map {
                PersistedSuggestion(
                    id: $0.id, stopId: $0.stopId, name: $0.name, type: $0.type, latitude: $0.latitude,
                    longitude: $0.longitude, kmMarkMeters: $0.kmMarkMeters, detourMeters: $0.detourMeters,
                    message: $0.message, suggestedAt: $0.suggestedAt)
            },
            answers: answers.values.sorted { $0.suggestedAt < $1.suggestedAt }.map {
                PersistedSuggestionAnswer(
                    suggestionId: $0.suggestionId, stopId: $0.stopId, suggestedAt: $0.suggestedAt,
                    answer: $0.answer.rawValue, respondedAt: $0.respondedAt)
            },
            declinedStopIds: declinedStopIds.sorted())
    }

    init(persisted state: PersistedSuggestionState) {
        self.init()
        suggestions = state.suggestions.map {
            ApprovedSuggestion(
                id: $0.id, stopId: $0.stopId, name: $0.name, type: $0.type, latitude: $0.latitude,
                longitude: $0.longitude, kmMarkMeters: $0.kmMarkMeters, detourMeters: $0.detourMeters,
                message: $0.message, suggestedAt: $0.suggestedAt)
        }
        for answer in state.answers {
            guard let kind = SuggestionAnswer(rawValue: answer.answer) else { continue }
            answers[answer.suggestionId] = SuggestionResponse(
                suggestionId: answer.suggestionId, stopId: answer.stopId, suggestedAt: answer.suggestedAt,
                answer: kind, respondedAt: answer.respondedAt)
        }
        declinedStopIds = Set(state.declinedStopIds)
        current = state.currentSuggestionId.flatMap { id in suggestions.first { $0.id == id } }
    }
}
