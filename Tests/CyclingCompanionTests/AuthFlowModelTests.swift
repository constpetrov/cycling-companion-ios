import XCTest

@testable import CyclingCompanion

/// Milestone 10 task-5.1 (RULE-42, RULE-4): AC-111 to AC-114, AC-136 to AC-139.
@MainActor
final class AuthFlowModelTests: XCTestCase {

    private static let tokens = #"{"accessToken":"a1","refreshToken":"r1","riderId":"rider-1","accessTokenExpiresIn":3600}"#

    private struct Harness {
        let model: AuthFlowModel
        let transport: ScriptedAuthTransport
        let store: InMemoryTokenStore
        let memory: AccountMemory
        let state: SessionState
    }

    private func harness(status: Int = 200, body: String = AuthFlowModelTests.tokens) -> Harness {
        let transport = ScriptedAuthTransport(status: status, body: body)
        let account = AccountHarness(transport: transport)
        return Harness(model: AuthFlowModel(actions: account.actions), transport: transport, store: account.tokenStore,
                       memory: account.memory, state: account.state)
    }

    private func waitForSignedIn(_ state: SessionState) async {
        for _ in 0..<100 where !state.isSignedIn {
            await Task.yield()
        }
    }

    /// AC-111.
    func testASuccessfulSignUpSignsTheRiderIn() async throws {
        let h = harness()
        h.model.mode = .signUp
        h.model.email = " Anna@Example.com "
        h.model.password = "a long password"
        h.model.inviteCode = "abcde-fghjk"

        await h.model.submit()
        await waitForSignedIn(h.state)

        XCTAssertNil(h.model.errorMessage)
        XCTAssertEqual(h.state.status, .signedIn(riderId: "rider-1"))
        XCTAssertEqual(try h.store.load(), "r1")
        XCTAssertEqual(h.memory.riderId, "rider-1")
        XCTAssertEqual(h.memory.email, "anna@example.com")
        let sent = await h.transport.sent
        XCTAssertEqual(sent.first?.path, "/api/v1/auth/sign-up")
        XCTAssertEqual(sent.first?.body["inviteCode"], "abcde-fghjk")
    }

    /// AC-112.
    func testARejectedSignUpShowsTheBackendMessageAndKeepsTheFields() async {
        let h = harness(status: 400, body: #"{"error":"INVITE_INVALID","message":"This invite code isn't valid"}"#)
        h.model.mode = .signUp
        h.model.email = "anna@example.com"
        h.model.password = "a long password"
        h.model.inviteCode = "WRONG-CODE1"

        await h.model.submit()

        XCTAssertEqual(h.model.errorMessage, "This invite code isn't valid")
        XCTAssertEqual(h.model.email, "anna@example.com")
        XCTAssertEqual(h.model.inviteCode, "WRONG-CODE1")
        XCTAssertEqual(h.state.status, .signedOut)
    }

    /// AC-113.
    func testARejectedSignInShowsTheBackendMessage() async {
        let h = harness(status: 401, body: #"{"error":"BAD_CREDENTIALS","message":"Email or password is incorrect"}"#)
        h.model.email = "anna@example.com"
        h.model.password = "wrong"

        await h.model.submit()

        XCTAssertEqual(h.model.errorMessage, "Email or password is incorrect")
        XCTAssertEqual(h.model.mode, .signIn)
    }

    func testOfflineSaysSo() async {
        let model = AuthFlowModel(actions: AccountHarness(transport: OfflineTransport()).actions)
        model.email = "anna@example.com"
        model.password = "whatever"

        await model.submit()

        XCTAssertEqual(model.errorMessage, AuthAPIError.unavailable.message)
    }

    /// AC-114.
    func testAResetSignsTheRiderIn() async {
        let h = harness()
        h.model.mode = .reset
        h.model.email = "anna@example.com"
        h.model.resetCode = "KLMNP-QRSTU"
        h.model.password = "a brand new password"

        await h.model.submit()
        await waitForSignedIn(h.state)

        XCTAssertEqual(h.state.status, .signedIn(riderId: "rider-1"))
        let sent = await h.transport.sent
        XCTAssertEqual(sent.first?.path, "/api/v1/auth/reset")
        XCTAssertEqual(sent.first?.body["newPassword"], "a brand new password")
    }

    /// AC-136 to AC-139, on sign-up and reset; sign-in doesn't check (the backend decides).
    func testNewPasswordsAreLengthCheckedBeforeSending() async {
        for mode in [AuthFlowModel.Mode.signUp, .reset] {
            for (password, sends) in [
                ("a".repeat(9), false), ("a".repeat(10), true), ("a".repeat(128), true), ("a".repeat(129), false),
                (String(repeating: "a", count: 9) + "🚲", true), (String(repeating: "🚲", count: 129), false),
            ] {
                let h = harness()
                h.model.mode = mode
                h.model.email = "anna@example.com"
                h.model.inviteCode = "ABCDE-FGHJK"
                h.model.resetCode = "ABCDE-FGHJK"
                h.model.password = password

                await h.model.submit()

                let sent = await h.transport.sent
                XCTAssertEqual(!sent.isEmpty, sends, "\(mode) with \(password.unicodeScalars.count) scalars")
                if !sends {
                    XCTAssertTrue(h.model.errorMessage?.contains("characters") ?? false)
                }
            }
        }
    }

    func testTheFormNeedsItsFields() {
        let h = harness()
        XCTAssertFalse(h.model.canSubmit)
        h.model.email = "anna@example.com"
        h.model.password = "a long password"
        XCTAssertTrue(h.model.canSubmit)
        h.model.mode = .signUp
        XCTAssertFalse(h.model.canSubmit, "sign-up needs the invite code")
        h.model.inviteCode = "ABCDE-FGHJK"
        XCTAssertTrue(h.model.canSubmit)
    }
}

private extension String {
    func `repeat`(_ count: Int) -> String {
        String(repeating: self, count: count)
    }
}
