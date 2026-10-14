import Foundation

@testable import CyclingCompanion

/// An `HTTPTransport` whose `data(for:)` call stays suspended until the test explicitly
/// `release(with:)`s it — the operation-arm counterpart to `GatedClock`, for the same
/// deterministic-race-ordering reason. Cancellation-aware for the same reason `GatedClock` is:
/// when the clock arm wins, this one must actually unblock, not hang `withTaskGroup` forever.
actor GatedTransport: HTTPTransport {
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    /// Sticky for the same reason `GatedClock.released` is — see its comment.
    private var releasedResult: Result<(Data, URLResponse), Error>?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if let releasedResult {
            return try releasedResult.get()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.resumeWithCancellation() }
        }
    }

    func release(data: Data, response: URLResponse) {
        releasedResult = .success((data, response))
        continuation?.resume(returning: (data, response))
        continuation = nil
    }

    func releaseWithFailure(_ error: Error) {
        releasedResult = .failure(error)
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func resumeWithCancellation() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
