import Foundation

/// An in-memory pool. Backs SwiftUI previews and the unit tests so nothing touches the real
/// controller. Reproduces the two traits that make the live API awkward: writes are toggles,
/// and reads lag behind writes.
nonisolated final class MockIAqualinkClient: IAqualinkClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _state: PoolState
    private var _failNextWrite = false
    private var _expireNextRead = false
    private var _lightBooting = false

    /// Artificial latency, in nanoseconds. Zero in tests, non-zero in previews.
    var latency: UInt64 = 0

    private(set) var commandLog: [String] = []

    init(state: PoolState = .demo) { self._state = state }

    var state: PoolState {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }

    /// Makes the next write throw, for exercising optimistic rollback.
    func failNextWrite() { lock.withLock { _failNextWrite = true } }

    /// Makes the next read throw `.sessionExpired`, for exercising re-login.
    func expireNextRead() { lock.withLock { _expireNextRead = true } }

    /// Models a colour fixture that boots: light commands are accepted and logged, but the
    /// reported state stays put, exactly as the real controller behaves for tens of seconds
    /// after the lamp is asked to come on.
    func simulateLightBoot(_ booting: Bool = true) { lock.withLock { _lightBooting = booting } }

    // MARK: - IAqualinkClient

    func login(email: String, password: String) async throws -> Session {
        try await pause()
        guard !password.isEmpty else { throw PoolError.loginFailed("empty password") }
        lock.withLock { commandLog.append("login") }
        return Session(token: "mock-token", userID: "1", sessionID: "mock-session", serial: "MOCK0000")
    }

    func loadState(_ session: Session) async throws -> PoolState {
        try await pause()
        return try lock.withLock {
            if _expireNextRead { _expireNextRead = false; throw PoolError.sessionExpired }
            commandLog.append("get_home")
            return _state
        }
    }

    func toggleAux(_ circuit: AuxCircuit, session: Session) async throws {
        try await write("set_aux_\(circuit.rawValue)") { state in
            switch circuit {
            case .light:
                // Read without re-locking: `write` already holds the lock.
                guard !self._lightBooting else { return }
                state.isLightOn.toggle()
                // Turning a color light on restores its last color; off clears it.
                state.lightColorIndex = state.isLightOn ? (state.lightColorIndex ?? 1) : nil
            case .jets:
                state.areJetsOn.toggle()
            }
        }
    }

    func setLightColor(index: Int, session: Session) async throws {
        try await write("set_light:\(index)") { state in
            guard !self._lightBooting else { return }
            state.lightColorIndex = index
            state.isLightOn = true  // setting a color implicitly turns the light on
        }
    }

    func setPoolSetPoint(_ degrees: Int, session: Session) async throws {
        try await write("set_temps:\(degrees)") { $0.poolSetPoint = degrees }
    }

    func togglePoolHeater(session: Session) async throws {
        try await write("set_pool_heater") { $0.isHeaterOn.toggle() }
    }

    func togglePoolPump(session: Session) async throws {
        try await write("set_pool_pump") { $0.isPumpOn.toggle() }
    }

    // MARK: - Helpers

    private func write(_ label: String, _ mutate: (inout PoolState) -> Void) async throws {
        try await pause()
        try lock.withLock {
            if _failNextWrite { _failNextWrite = false; throw PoolError.badResponse("injected failure") }
            commandLog.append(label)
            mutate(&_state)
        }
    }

    private func pause() async throws {
        if latency > 0 { try await Task.sleep(nanoseconds: latency) }
    }
}

nonisolated extension PoolState {
    /// A plausible summer afternoon, used for previews.
    static let demo = PoolState(
        poolTemp: 89, airTemp: 73, poolSetPoint: 88,
        isHeaterOn: false, isPumpOn: true,
        isLightOn: false, lightColorIndex: nil, areJetsOn: false
    )
}
