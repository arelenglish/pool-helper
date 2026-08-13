import Foundation
import Observation

/// The app's single source of truth. Polls the controller, applies guest actions
/// optimistically, and enforces the heater deadline.
@Observable
@MainActor
final class PoolStore {
    enum Connection: Equatable {
        case connecting
        case online
        case offline(String)
        case needsSetup
    }

    /// What the UI renders — `confirmed` plus any in-flight optimistic change.
    private(set) var state: PoolState = .placeholder
    private(set) var connection: Connection = .connecting
    private(set) var heatDeadline: Date?
    /// Transient message shown when an action fails and gets rolled back.
    private(set) var banner: String?

    /// The temperature the guest has dialed in. Normally mirrors the controller's setpoint,
    /// but runs ahead of it while an adjustment is still being debounced.
    private(set) var targetTemperature: Int = PoolState.placeholder.poolSetPoint

    /// Last state the controller actually confirmed. Writes reconcile against this, never
    /// against the optimistic `state`, or a double-tap would compute the wrong toggle.
    private var confirmed: PoolState = .placeholder

    private let client: IAqualinkClient
    private let schedule: HeatSchedule
    private let credentials: CredentialProvider
    private var session: Session?
    private var pollTask: Task<Void, Never>?
    /// Serializes writes so two quick taps can't interleave and cancel each other out.
    private var writeChain: Task<Void, Never> = Task {}
    /// Pending debounced setpoint write. Non-nil means the guest is mid-adjustment, which
    /// also suppresses polling from yanking the number back under their finger.
    private var setPointTask: Task<Void, Never>?

    private let pollInterval: Duration
    private let setPointDebounce: Duration

    init(
        client: IAqualinkClient = LiveIAqualinkClient(),
        schedule: HeatSchedule = HeatSchedule(),
        credentials: CredentialProvider = .keychain,
        pollInterval: Duration = .seconds(15),
        setPointDebounce: Duration = .milliseconds(1200)
    ) {
        self.client = client
        self.schedule = schedule
        self.credentials = credentials
        self.pollInterval = pollInterval
        self.setPointDebounce = setPointDebounce
        self.heatDeadline = schedule.deadline
    }

    /// Waits for any queued write (and its follow-up refresh) to finish. Tests only.
    func settle() async { _ = await writeChain.value }

    // MARK: - Lifecycle

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                await self?.enforceHeatDeadline()
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(15))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Reads

    /// Pulls current state, re-logging in once if the session has lapsed.
    func refresh() async {
        do {
            let session = try await activeSession()
            let fresh: PoolState
            do {
                fresh = try await client.loadState(session)
            } catch PoolError.sessionExpired {
                // Sessions are short-lived; a silent re-login is the expected path, not an error.
                let renewed = try await signInFromKeychain()
                fresh = try await client.loadState(renewed)
            }
            confirmed = fresh
            state = fresh
            // Don't overwrite a number the guest is actively adjusting.
            if setPointTask == nil { targetTemperature = fresh.poolSetPoint }
            connection = .online
        } catch PoolError.noCredentials {
            connection = .needsSetup
        } catch {
            // Keep showing the last known state rather than blanking the screen.
            connection = .offline(error.localizedDescription)
        }
    }

    // MARK: - Guest actions

    func setLight(on: Bool) {
        apply({ $0.isLightOn = on }, action: { [client] session, confirmed in
            guard confirmed.isLightOn != on else { return }
            try await client.toggleAux(.light, session: session)
        }, failureMessage: "Couldn't reach the light.")
    }

    func setLightColor(_ color: LightColor) {
        apply({ $0.lightColorIndex = color.id; $0.isLightOn = true }, action: { [client] session, _ in
            // set_light is an assignment, not a toggle, and turns the light on implicitly,
            // so it needs no reconciliation.
            try await client.setLightColor(index: color.id, session: session)
        }, failureMessage: "Couldn't change the color.")
    }

    func setJets(on: Bool) {
        apply({ $0.areJetsOn = on }, action: { [client] session, confirmed in
            guard confirmed.areJetsOn != on else { return }
            try await client.toggleAux(.jets, session: session)
        }, failureMessage: "Couldn't reach the jets.")
    }

    /// Moves the dialed-in temperature. The number changes instantly and the controller is
    /// written to once the guest stops tapping — a write per tap would flood a slow API and
    /// arrive out of order.
    func adjustTargetTemperature(to degrees: Int) {
        let clamped = PoolState.clampSetPoint(degrees)
        targetTemperature = clamped
        banner = nil

        setPointTask?.cancel()
        setPointTask = Task { [weak self] in
            try? await Task.sleep(for: self?.setPointDebounce ?? .milliseconds(1200))
            guard !Task.isCancelled, let self else { return }
            self.setPointTask = nil
            self.commitTargetTemperature(clamped)
        }
    }

    private func commitTargetTemperature(_ degrees: Int) {
        apply(
            { $0.poolSetPoint = degrees },
            action: { [client] session, confirmed in
                guard confirmed.poolSetPoint != degrees else { return }
                try await client.setPoolSetPoint(degrees, session: session)
            },
            failureMessage: "Couldn't change the temperature.",
            onFailure: { [weak self] in
                // Snap the dial back to what the controller actually has.
                if let self { self.targetTemperature = self.confirmed.poolSetPoint }
                return self?.heatDeadline
            }
        )
    }

    func startHeating(for duration: TimeInterval) {
        // Any debounced temperature edit is folded into this write rather than left pending,
        // so tapping a duration right after tapping "+" still heats to the chosen number.
        setPointTask?.cancel()
        setPointTask = nil
        let target = targetTemperature

        // Armed before the write, not after: if the app dies mid-request, an extra deadline
        // for a heater that never came on is harmless, but a heater that came on with no
        // deadline runs until someone notices.
        heatDeadline = schedule.arm(for: duration)
        apply(
            { $0.isHeaterOn = true; $0.poolSetPoint = target },
            action: { [client] session, confirmed in
                if confirmed.poolSetPoint != target {
                    try await client.setPoolSetPoint(target, session: session)
                }
                guard !confirmed.isHeaterOn else { return }
                try await client.togglePoolHeater(session: session)
            },
            failureMessage: "Couldn't start the heater.",
            onFailure: { [schedule] in schedule.disarm(); return nil }
        )
    }

    func stopHeating() {
        apply(
            { $0.isHeaterOn = false },
            action: { [client] session, confirmed in
                guard confirmed.isHeaterOn else { return }
                try await client.togglePoolHeater(session: session)
            },
            failureMessage: "Couldn't stop the heater.",
            // Disarm only once the heater is actually off. Disarming up front would mean a
            // failed stop leaves the heater running with nothing left to switch it off.
            onSuccess: { [schedule] in schedule.disarm(); return nil },
            onFailure: { [schedule] in schedule.deadline }
        )
    }

    // MARK: - Heat deadline

    /// Called on every poll tick. Checking the clock here rather than scheduling a timer
    /// means a missed or failed shutoff is retried automatically on the next tick, and a
    /// deadline that elapsed while the app was dead fires on the first tick after launch.
    func enforceHeatDeadline() async {
        guard schedule.hasExpired() else {
            heatDeadline = schedule.deadline
            return
        }
        guard let session = try? await activeSession() else { return }

        if confirmed.isHeaterOn {
            do {
                try await client.togglePoolHeater(session: session)
            } catch {
                // Leave the deadline armed so the next tick tries again.
                return
            }
        }
        schedule.disarm()
        heatDeadline = nil
        state.isHeaterOn = false
        confirmed.isHeaterOn = false
    }

    // MARK: - Setup

    func signIn(email: String, password: String) async throws {
        let session = try await client.login(email: email, password: password)
        try credentials.save(.init(email: email, password: password))
        self.session = session
        await refresh()
    }

    func signOut() {
        credentials.clear()
        schedule.disarm()
        session = nil
        heatDeadline = nil
        connection = .needsSetup
    }

    // MARK: - Plumbing

    private func activeSession() async throws -> Session {
        if let session { return session }
        return try await signInFromKeychain()
    }

    @discardableResult
    private func signInFromKeychain() async throws -> Session {
        guard let saved = credentials.load() else { throw PoolError.noCredentials }
        let session = try await client.login(email: saved.email, password: saved.password)
        self.session = session
        return session
    }

    /// Shows the change immediately, sends it, and puts the screen back if it didn't land.
    /// The API takes a second or two to respond; without this, guests tap again.
    /// `onSuccess` / `onFailure` run once the write's fate is known and return the deadline
    /// the UI should now show. They exist so heat bookkeeping can be committed only when the
    /// corresponding command actually landed.
    private func apply(
        _ optimistic: (inout PoolState) -> Void,
        action: @escaping @Sendable (Session, PoolState) async throws -> Void,
        failureMessage: String,
        // Main-actor isolated, unlike `action`: these run after the write settles and read
        // back store state, so they must not hop off the actor.
        onSuccess: (() -> Date?)? = nil,
        onFailure: (() -> Date?)? = nil
    ) {
        let rollback = state
        optimistic(&state)
        banner = nil

        let previous = writeChain
        writeChain = Task { [weak self] in
            _ = await previous.value
            guard let self else { return }
            do {
                let session = try await self.activeSession()
                do {
                    try await action(session, self.confirmed)
                } catch PoolError.sessionExpired {
                    let renewed = try await self.signInFromKeychain()
                    try await action(renewed, self.confirmed)
                }
                if let onSuccess { self.heatDeadline = onSuccess() }
                // Re-read so the next queued write reconciles against fresh truth.
                await self.refresh()
            } catch {
                self.state = rollback
                self.banner = failureMessage
                if let onFailure { self.heatDeadline = onFailure() }
            }
        }
    }

    func dismissBanner() { banner = nil }
}
