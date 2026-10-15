import os

/// Apple's unified logging (`os.Logger`) — the iOS equivalent of a system journal: entries
/// persist in the system-wide log store and are retrievable after the fact via Console.app or
/// `log show`/`log stream --predicate 'subsystem == "com.cyclingcompanion.app"'`, even from a
/// device not attached to Xcode. Unlike `print()`, this works the same in Release builds, so
/// it's safe to use everywhere, not just Debug.
enum Log {
    static func logger(category: String) -> Logger {
        Logger(subsystem: "com.cyclingcompanion.app", category: category)
    }
}
