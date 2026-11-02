import Foundation

/// One crank revolution report: the cumulative revolution count and the time of the last crank
/// event in 1/1024 s. Both are 16-bit and wrap around.
struct CrankSample: Equatable, Sendable {
    let revolutions: UInt16
    let eventTime: UInt16
}

/// Extracts crank data from the Cycling Speed and Cadence (0x2A5B) and Cycling Power (0x2A63)
/// measurements (RULE-2 in milestone 12's rules.md). Power values are skipped, not read.
enum CrankMeasurement {
    /// CSC Measurement: a flags byte, then wheel data (6 bytes) if bit 0 is set, then crank data
    /// (4 bytes) if bit 1 is set. `nil` when there is no crank data (a wheel-only speed sensor) or
    /// the payload is too short.
    static func fromCyclingSpeedAndCadence(_ data: Data) -> CrankSample? {
        let bytes = [UInt8](data)
        guard let flags = bytes.first, flags & 0x02 != 0 else { return nil }
        let offset = 1 + (flags & 0x01 != 0 ? 6 : 0)
        return crankSample(bytes, at: offset)
    }

    /// Cycling Power Measurement: 16-bit flags, 16-bit instantaneous power, then optional fields in
    /// order — pedal power balance (1 byte, bit 0), accumulated torque (2 bytes, bit 2), wheel data
    /// (6 bytes, bit 4) and crank data (4 bytes, bit 5). Bits 1 and 3 only qualify other fields.
    static func fromCyclingPower(_ data: Data) -> CrankSample? {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }
        let flags = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        guard flags & 0x20 != 0 else { return nil }
        var offset = 4
        if flags & 0x01 != 0 { offset += 1 }
        if flags & 0x04 != 0 { offset += 2 }
        if flags & 0x10 != 0 { offset += 6 }
        return crankSample(bytes, at: offset)
    }

    private static func crankSample(_ bytes: [UInt8], at offset: Int) -> CrankSample? {
        guard bytes.count >= offset + 4 else { return nil }
        return CrankSample(
            revolutions: UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8,
            eventTime: UInt16(bytes[offset + 2]) | UInt16(bytes[offset + 3]) << 8)
    }
}

/// Turns consecutive crank samples into cadence (AC-30 to AC-41): Δ revolutions ÷ Δ event time,
/// across the 16-bit wraparound. A cadence above `maximumRPM` is a glitch and reported as no
/// reading; once `coastingTimeout` passes without a new crank event, cadence is 0. Time is passed in
/// and never read from the system clock (RULE-2, RULE-7).
struct CrankCadenceCalculator: Sendable {
    static let coastingTimeout: TimeInterval = 3
    static let maximumRPM = 250

    private var previous: CrankSample?
    private var lastCadence: Int?
    private var lastNewEventAt: Date?

    /// Takes one measurement's crank data (`nil` when the measurement carries none) and returns the
    /// cadence to report for it, or `nil` for no reading.
    mutating func ingest(_ sample: CrankSample?, at now: Date) -> Int? {
        guard let sample else { return nil }
        guard let previous else {
            // AC-33: nothing to compare the first sample with.
            self.previous = sample
            lastNewEventAt = now
            return nil
        }
        // AC-34: the same event again means no new crank revolution since the last one.
        guard sample.eventTime != previous.eventTime else {
            return cadence(at: now)
        }
        self.previous = sample
        lastNewEventAt = now
        let revolutions = Double(sample.revolutions &- previous.revolutions)
        let seconds = Double(sample.eventTime &- previous.eventTime) / 1024
        let rpm = Int((revolutions * 60 / seconds).rounded())
        // AC-38 to AC-40.
        guard rpm <= Self.maximumRPM else { return nil }
        lastCadence = rpm
        return rpm
    }

    /// The cadence to report at `now` with no new measurement: the last value until the coasting
    /// timeout, then 0 (AC-35 to AC-37). `nil` before any crank sample arrived.
    func cadence(at now: Date) -> Int? {
        guard let lastNewEventAt else { return nil }
        if now.timeIntervalSince(lastNewEventAt) >= Self.coastingTimeout {
            return 0
        }
        return lastCadence
    }
}
