import Foundation

/// Primitive operations against the iAqualink API.
///
/// Deliberately dumb: every method maps to exactly one request and does no reconciliation.
/// Because the API's writes are *toggles* rather than assignments, deciding whether a command
/// should be sent at all is `PoolStore`'s job, not the client's.
nonisolated protocol IAqualinkClient: Sendable {
    func login(email: String, password: String) async throws -> Session
    func loadState(_ session: Session) async throws -> PoolState
    func toggleAux(_ circuit: AuxCircuit, session: Session) async throws
    func setLightColor(index: Int, session: Session) async throws
    func setPoolSetPoint(_ degrees: Int, session: Session) async throws
    func togglePoolHeater(session: Session) async throws
}

/// Parses the API's unusual response shape: arrays of single-key objects, where absent
/// readings are empty strings rather than nulls.
///
///     "home_screen": [ {"pool_temp": "89"}, {"spa_temp": ""}, {"swc_info": {…}} ]
nonisolated enum ScreenParser {
    /// Flattens an array of single-key objects into a dictionary, keeping only string values.
    /// Non-string values (`swc_info`, `heatpump_info`, `icl_custom_color_info`) are dropped —
    /// nothing in this app reads them.
    static func flatten(_ screen: [[String: Any]]) -> [String: String] {
        var out: [String: String] = [:]
        for entry in screen {
            for (key, value) in entry {
                if let string = value as? String { out[key] = string }
            }
        }
        return out
    }

    /// Empty string means "no reading", which is distinct from zero. `spa_temp` is always
    /// empty on this pool-only system, and `pool_temp` goes empty when the pump is off.
    static func int(_ dict: [String: String], _ key: String) -> Int? {
        guard let raw = dict[key], !raw.isEmpty else { return nil }
        return Int(raw)
    }

    static func bool(_ dict: [String: String], _ key: String) -> Bool {
        // Heater states report "0" off, "1" on, and "3" for "enabled but not currently
        // firing". Anything non-zero counts as on.
        guard let raw = dict[key], !raw.isEmpty else { return false }
        return raw != "0"
    }

    /// Pulls one aux circuit's `state` and `subtype` out of a `devices_screen` payload.
    /// Each aux is `{"aux_1": [{"state": "0"}, {"label": "Pool Light"}, …]}`.
    static func aux(_ screen: [[String: Any]], _ circuit: AuxCircuit) -> (state: Int, label: String)? {
        let key = "aux_\(circuit.rawValue)"
        for entry in screen {
            guard let fields = entry[key] as? [[String: Any]] else { continue }
            let flat = flatten(fields)
            guard let state = Int(flat["state"] ?? "") else { return nil }
            return (state, flat["label"] ?? "")
        }
        return nil
    }
}
