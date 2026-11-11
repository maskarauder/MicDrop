import Foundation

extension ConnectionPreferences {
    public static let fileName = "connection-settings.json"

    public func fields() -> [String: AudioPreferences.StoredValue] {
        var values = Dictionary(
            uniqueKeysWithValues: Timeout.allCases.map {
                ($0.storageKey, AudioPreferences.StoredValue.number(Double(self[$0])))
            })
        values["initialOrder"] = .string(initialOrder.rawValue)
        values["recoveryOrder"] = .string(recoveryOrder.rawValue)
        values["maxRestarts"] = .number(Double(maxRestarts))
        return values
    }

    public static func decodeJSON(_ data: Data?) -> ConnectionPreferences {
        guard let data, let fields = try? JSONDecoder().decode([String: AudioPreferences.StoredValue].self, from: data)
        else {
            return ConnectionPreferences()
        }
        func integer(_ key: String, minimum: Int, maximum: Int, fallback: Int) -> Int {
            guard case .number(let value)? = fields[key], value.isFinite, value.rounded(.towardZero) == value,
                value >= Double(minimum), value <= Double(maximum)
            else { return fallback }
            return Int(value)
        }
        func order(_ key: String, fallback: Order) -> Order {
            guard case .string(let value)? = fields[key] else { return fallback }
            return Order(rawValue: value) ?? fallback
        }
        let timeouts = Dictionary(
            uniqueKeysWithValues: Timeout.allCases.map { timeout in
                let limits = timeout.limits
                return (
                    timeout,
                    integer(
                        timeout.storageKey, minimum: limits.minimumMs, maximum: limits.maximumMs,
                        fallback: limits.defaultMs)
                )
            })
        return
            (try? ConnectionPreferences(
                initialOrder: order("initialOrder", fallback: .lanFirst),
                recoveryOrder: order("recoveryOrder", fallback: .rendezvousFirst),
                timeouts: timeouts, maxRestarts: integer("maxRestarts", minimum: 1, maximum: 10, fallback: 2)))
            ?? ConnectionPreferences()
    }

    public func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(fields())
    }

    public static func seconds(_ milliseconds: Int) -> String {
        let whole = milliseconds / 1_000
        let remainder = milliseconds % 1_000
        guard remainder != 0 else { return String(whole) }
        var fraction = String(remainder + 1_000).dropFirst()
        while fraction.last == "0" { fraction = fraction.dropLast() }
        return "\(whole).\(fraction)"
    }

    /// Exact decimal seconds, at most three fractional digits, within `minimumMs...maximumMs`; locale-independent
    /// and no rounding. Shared by every validated timeout (`Timeout.parseSeconds`, `AdvancedAudioPreferences`).
    public static func parseSeconds(_ text: String, minimumMs: Int, maximumMs: Int) -> Int? {
        guard !text.isEmpty, text.utf8.count <= 12 else { return nil }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty,
            parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
            let whole = Int(parts[0])
        else { return nil }
        if parts.count == 2 && parts[1].count > 3 { return nil }
        let scaled = whole.multipliedReportingOverflow(by: 1_000)
        guard !scaled.overflow else { return nil }
        let fraction = parts.count == 2 ? Int(parts[1] + String(repeating: "0", count: 3 - parts[1].count)) ?? 0 : 0
        let total = scaled.partialValue.addingReportingOverflow(fraction)
        guard !total.overflow, minimumMs <= maximumMs, (minimumMs...maximumMs).contains(total.partialValue) else {
            return nil
        }
        return total.partialValue
    }

    /// Typed field text: trims surrounding whitespace (like Android's `trim()`) and accepts the locale's decimal
    /// separator, which `.decimalPad` shows in place of '.', then applies the strict rules of `parseSeconds`.
    public static func parseUserSeconds(
        _ text: String, minimumMs: Int, maximumMs: Int, locale: Locale = .current
    ) -> Int? {
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = locale.decimalSeparator, separator.count == 1, let mark = separator.first, mark != "." {
            normalized = String(normalized.map { $0 == mark ? "." : $0 })
        }
        return parseSeconds(normalized, minimumMs: minimumMs, maximumMs: maximumMs)
    }
}

extension ConnectionPreferences.Timeout {
    public enum Group: String, CaseIterable, Sendable {
        case recovery = "Connection and recovery"
        case requests = "Request timeouts"
        case webRTC = "WebRTC timeouts"
    }

    public var group: Group {
        switch self {
        case .recovery, .setup, .busyHost, .restartDelay, .restartInterval: return .recovery
        case .initialOffer, .initialICE, .initialSDP, .recoveryICE, .recoveryOffer, .recoveryAnswer: return .webRTC
        default: return .requests
        }
    }

    public var label: String {
        switch self {
        case .recovery: return "Media connection / recovery window"
        case .setup: return "Windows offer-to-answer window"
        case .busyHost: return "Wait for Windows to finish the previous session"
        case .restartDelay: return "Delay before first ICE restart"
        case .restartInterval: return "Interval between ICE restarts"
        case .lanProbe: return "LAN verification"
        case .lanStatus: return "LAN status request"
        case .lanRequest: return "Other LAN control requests"
        case .remoteRequest: return "Rendezvous control request"
        case .iceService: return "STUN / TURN configuration request"
        case .lanStop: return "LAN Stop / cancellation budget"
        case .remoteStop: return "Remote Stop / cancellation budget"
        case .initialOffer: return "Initial offer request"
        case .cancelOffer: return "Offer cancellation"
        case .initialICE: return "Initial ICE gathering"
        case .initialSDP: return "Initial SDP operation"
        case .recoveryICE: return "Recovery ICE gathering"
        case .recoveryOffer: return "Recovery offer request"
        case .recoveryAnswer: return "Recovery SDP / answer operation"
        }
    }

    public var storageKey: String {
        switch self {
        case .recovery: return "RECOVERY"
        case .setup: return "SETUP"
        case .busyHost: return "BUSY_HOST"
        case .restartDelay: return "RESTART_DELAY"
        case .restartInterval: return "RESTART_INTERVAL"
        case .lanProbe: return "LAN_PROBE"
        case .lanStatus: return "LAN_STATUS"
        case .lanRequest: return "LAN_REQUEST"
        case .remoteRequest: return "REMOTE_REQUEST"
        case .iceService: return "ICE_SERVICE"
        case .lanStop: return "LAN_STOP"
        case .remoteStop: return "REMOTE_STOP"
        case .initialOffer: return "INITIAL_OFFER"
        case .cancelOffer: return "CANCEL_OFFER"
        case .initialICE: return "INITIAL_ICE"
        case .initialSDP: return "INITIAL_SDP"
        case .recoveryICE: return "RECOVERY_ICE"
        case .recoveryOffer: return "RECOVERY_OFFER"
        case .recoveryAnswer: return "RECOVERY_ANSWER"
        }
    }

    /// Exact decimal seconds, at most three fractional digits; locale-independent and no rounding.
    public func parseSeconds(_ text: String) -> Int? {
        ConnectionPreferences.parseSeconds(text, minimumMs: limits.minimumMs, maximumMs: limits.maximumMs)
    }

    /// Typed field text: trims surrounding whitespace (like Android's `trim()`) and accepts the locale's decimal
    /// separator, which `.decimalPad` shows in place of '.', then applies the strict rules of `parseSeconds`.
    public func parseUserSeconds(_ text: String, locale: Locale = .current) -> Int? {
        ConnectionPreferences.parseUserSeconds(
            text, minimumMs: limits.minimumMs, maximumMs: limits.maximumMs, locale: locale)
    }
}
