import Foundation

/// A snapshot of everything the app cares about, parsed from `get_home` + `get_devices`.
nonisolated struct PoolState: Equatable, Sendable {
    var poolTemp: Int?          // nil when the sensor reports empty (pump off, no flow)
    var airTemp: Int?
    var poolSetPoint: Int
    var isHeaterOn: Bool
    var isPumpOn: Bool
    var isLightOn: Bool
    var lightColorIndex: Int?   // nil when the controller hasn't reported a color yet
    var areJetsOn: Bool

    /// The AquaLink RS pool setpoint range. Not a policy cap — the controller rejects
    /// values outside it.
    static let minSetPoint = 65
    static let maxSetPoint = 104

    static func clampSetPoint(_ degrees: Int) -> Int {
        min(max(degrees, minSetPoint), maxSetPoint)
    }

    /// Whether switching the heater on at `target` would actually produce heat.
    ///
    /// The controller happily accepts "heater on" with a setpoint at or below the current
    /// water temperature and then does nothing — the thermostat is already satisfied. Without
    /// this check the app starts a timer and reports "Heating until…" while the pool sits
    /// cold, which is exactly the failure that looks like a broken heater.
    ///
    /// An unknown reading is not treated as a blocker: `pool_temp` goes empty when the pump
    /// is off, and refusing to heat then would be its own bug.
    func wouldHeat(target: Int) -> Bool {
        guard let poolTemp else { return true }
        return target > poolTemp
    }

    static let placeholder = PoolState(
        poolTemp: nil, airTemp: nil, poolSetPoint: 85,
        isHeaterOn: false, isPumpOn: false,
        isLightOn: false, lightColorIndex: nil, areJetsOn: false
    )
}

/// Identifies which relay does what on this specific RS-4. Verified against the live
/// controller on 2026-08-11: aux_1 is the color light, aux_4 is the jets.
nonisolated enum AuxCircuit: Int, Sendable {
    case light = 1
    case jets = 4

    /// The light's `subtype`, echoed back in every `set_light` call.
    static let lightSubtype = 4
}

/// A logged-in session. Short-lived — expect to re-login mid-day.
nonisolated struct Session: Equatable, Sendable {
    var token: String
    var userID: String
    var sessionID: String
    var serial: String
}

nonisolated enum PoolError: Error, LocalizedError {
    case noCredentials
    case loginFailed(String)
    case sessionExpired
    case noDevices
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .noCredentials:      return "No saved account."
        case .loginFailed(let m): return "Sign-in failed: \(m)"
        case .sessionExpired:     return "Session expired."
        case .noDevices:          return "No pool controller on this account."
        case .badResponse(let m): return "Unexpected response: \(m)"
        }
    }
}
