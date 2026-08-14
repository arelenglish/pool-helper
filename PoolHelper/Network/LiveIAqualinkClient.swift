import Foundation

/// Talks to the real iAqualink service.
///
/// This API is undocumented and reverse-engineered. Everything it does is confined to this
/// one file so a breaking upstream change is a single-file fix.
nonisolated struct LiveIAqualinkClient: IAqualinkClient {
    /// The public `api_key` embedded in the official iAqualink mobile app. Not a secret,
    /// and not account-specific.
    private static let apiKey = "EOOEMOW4YR6QNB07"

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    // MARK: - Auth

    func login(email: String, password: String) async throws -> Session {
        var request = URLRequest(url: URL(string: "https://prod.zodiac-io.com/users/v1/login")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "api_key": Self.apiKey, "email": email, "password": password,
        ])

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw PoolError.loginFailed("check the email and password")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["authentication_token"] as? String,
              let sessionID = json["session_id"] as? String,
              let id = json["id"] as? Int
        else { throw PoolError.loginFailed("unrecognized sign-in response") }

        let serial = try await firstDeviceSerial(token: token, userID: String(id))
        return Session(token: token, userID: String(id), sessionID: sessionID, serial: serial)
    }

    private func firstDeviceSerial(token: String, userID: String) async throws -> String {
        var components = URLComponents(string: "https://r-api.iaqualink.net/devices.json")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: Self.apiKey),
            URLQueryItem(name: "authentication_token", value: token),
            URLQueryItem(name: "user_id", value: userID),
        ]
        let (data, _) = try await session.data(from: components.url!)
        guard let devices = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { throw PoolError.badResponse("device list") }

        // Only "iaqua" controllers speak the session.json command set. Robots and
        // chlorinators on the same account use a different API and are ignored.
        let controller = devices.first {
            ($0["device_type"] as? String) == "iaqua" || ($0["device_type"] as? String) == "iaqualink"
        }
        guard let serial = controller?["serial_number"] as? String else { throw PoolError.noDevices }
        return serial
    }

    // MARK: - Reads

    func loadState(_ session: Session) async throws -> PoolState {
        let home = try await command("get_home", session: session, screenKey: "home_screen")
        let devices = try await command("get_devices", session: session, screenKey: "devices_screen")

        let h = ScreenParser.flatten(home)
        let light = ScreenParser.aux(devices, .light)
        let jets = ScreenParser.aux(devices, .jets)

        return PoolState(
            poolTemp: ScreenParser.int(h, "pool_temp"),
            airTemp: ScreenParser.int(h, "air_temp"),
            poolSetPoint: ScreenParser.int(h, "pool_set_point") ?? 85,
            isHeaterOn: ScreenParser.bool(h, "pool_heater"),
            isPumpOn: ScreenParser.bool(h, "pool_pump"),
            isLightOn: (light?.state ?? 0) != 0,
            // On this controller a color light's `state` is 0 when off, and when on it
            // carries the active color index. Guard the range: if a firmware reports a
            // plain "1" for on, index 1 is still a valid color, so the UI stays coherent.
            lightColorIndex: light.flatMap { $0.state > 0 ? $0.state : nil },
            areJetsOn: (jets?.state ?? 0) != 0
        )
    }

    // MARK: - Writes

    func toggleAux(_ circuit: AuxCircuit, session: Session) async throws {
        _ = try await command("set_aux_\(circuit.rawValue)", session: session, screenKey: nil)
    }

    func setLightColor(index: Int, session: Session) async throws {
        _ = try await command("set_light", session: session, screenKey: nil, extra: [
            "light": String(index),
            "aux": String(AuxCircuit.light.rawValue),
            "subtype": String(AuxCircuit.lightSubtype),
        ])
    }

    func setPoolSetPoint(_ degrees: Int, session: Session) async throws {
        // `temp1` and `temp2` are two presets for the same body of water, and `temp2` is the
        // one the system heats to. Confirmed live on 2026-08-13: sending `temp1` alone moved
        // `spa_set_point` 104 -> 95 while `pool_set_point` stayed at 104.
        //
        // Only temp2 is sent. An earlier version wrote both slots to the same value, which
        // silently destroyed the other preset every time a guest changed the temperature —
        // and the two presets aren't even allowed to be equal.
        _ = try await command("set_temps", session: session, screenKey: nil, extra: [
            "temp2": String(degrees),
        ])
    }

    func togglePoolHeater(session: Session) async throws {
        _ = try await command("set_pool_heater", session: session, screenKey: nil)
    }

    /// The filter pump. A Jandy heater will not fire without circulation, so enabling heat
    /// while the pump is off achieves nothing.
    func togglePoolPump(session: Session) async throws {
        _ = try await command("set_pool_pump", session: session, screenKey: nil)
    }

    // MARK: - Transport

    /// Issues one `session.json` command. When `screenKey` is given, the named screen array
    /// is returned; a missing screen is reported as an expired session so the caller can
    /// re-login once and retry.
    @discardableResult
    private func command(
        _ name: String,
        session poolSession: Session,
        screenKey: String?,
        extra: [String: String] = [:]
    ) async throws -> [[String: Any]] {
        var components = URLComponents(string: "https://p-api.iaqualink.net/v1/mobile/session.json")!
        var items = [
            URLQueryItem(name: "actionID", value: "command"),
            URLQueryItem(name: "command", value: name),
            URLQueryItem(name: "serial", value: poolSession.serial),
            URLQueryItem(name: "sessionID", value: poolSession.sessionID),
        ]
        items.append(contentsOf: extra.map { URLQueryItem(name: $0.key, value: $0.value) })
        components.queryItems = items

        let (data, response) = try await session.data(from: components.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw PoolError.sessionExpired }
        guard status == 200 else { throw PoolError.badResponse("\(name) returned \(status)") }

        guard let screenKey else { return [] }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let screen = json[screenKey] as? [[String: Any]]
        else { throw PoolError.sessionExpired }
        return screen
    }
}
