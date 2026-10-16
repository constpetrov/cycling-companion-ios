import Foundation

/// Build settings are embedded in Info.plist, so they also apply when launching from the
/// Home Screen rather than Xcode. No model-provider credentials belong in this configuration.
struct BackendConfiguration: Sendable {
    let baseURL: URL
    let demoAccessToken: String?

    static let local = BackendConfiguration(baseURL: URL(string: "http://localhost:8080")!, demoAccessToken: nil)

    static func load(
        info: [String: Any] = Bundle.main.infoDictionary ?? [:],
        allowsLoopback: Bool = isSimulator
    ) throws -> BackendConfiguration {
        let address = setting("CyclingCompanionBackendBaseURL", in: info) ?? local.baseURL.absoluteString
        guard let components = URLComponents(string: address),
            let host = components.host?.lowercased(), !host.isEmpty,
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil,
            components.path.isEmpty || components.path == "/",
            let url = components.url
        else {
            throw ConfigurationError.invalidAddress
        }
        let isLoopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard !isLoopback || allowsLoopback else {
            throw ConfigurationError.deviceNeedsRemoteAddress
        }
        guard components.scheme?.lowercased() == "https"
            || (isLoopback && components.scheme?.lowercased() == "http")
        else {
            throw ConfigurationError.httpsRequired
        }
        let token = setting("CyclingCompanionDemoAccessToken", in: info)
        guard isLoopback || token != nil else {
            throw ConfigurationError.demoAccessTokenRequired
        }
        return BackendConfiguration(baseURL: url, demoAccessToken: token)
    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    private static func setting(_ key: String, in info: [String: Any]) -> String? {
        guard let value = info[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$("), !trimmed.hasPrefix("CHANGE_ME") else { return nil }
        return trimmed
    }

    enum ConfigurationError: LocalizedError {
        case invalidAddress
        case deviceNeedsRemoteAddress
        case httpsRequired
        case demoAccessTokenRequired

        var errorDescription: String? {
            switch self {
            case .invalidAddress:
                "Set CC_BACKEND_BASE_URL to the backend origin, without a path, credentials or query."
            case .deviceNeedsRemoteAddress:
                "On iPhone, localhost points to the phone. Set CC_BACKEND_BASE_URL to the backend HTTPS domain and rebuild."
            case .httpsRequired:
                "The remote backend requires an HTTPS address with a valid certificate."
            case .demoAccessTokenRequired:
                "Set CC_DEMO_ACCESS_TOKEN to the demo gateway key and rebuild. Do not use the Nebius API key."
            }
        }
    }
}
