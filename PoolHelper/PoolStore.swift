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
    private(set) var jetsDeadline: Date?
    private(set) var lightsDeadline: Date?
    /// Transient message shown when an action fails and gets rolled back.
    private(set) var banner: String?

    /// True while the light has been asked for but the fixture hasn't reported in yet.
    private(set) var isLightStarting = false

    /// The temperature the guest has dialed in. Normally mirrors the controller's setpoint,
    /// but runs ahead of it while an adjustment is still being debounced.
    private(set) var targetTemperature: Int = PoolState.placeholder.poolSetPoint

    /// Last state the controller actually confirmed. Writes reconcile against this, never
    /// against the optimistic `state`, or a double-tap would compute the wrong toggle.
    private var confirmed: PoolState = .placeholder

    private let client: IAqualinkClient
    private let schedule: ShutoffSchedule
    private let jetsSchedule: ShutoffSchedule
    private let lightsSchedule: ShutoffSchedule
    private let solar: SolarClock
    private let pump: PumpOwnership
    private let credentials: CredentialProvider
    private var session: Session?
    private var pollTask: Task<Void, Never>?
    /// Serializes writes so two quick taps can't interleave and cancel each other out.
    private var writeChain: Task<Void, Never> = Task {}
    /// Pending debounced setpoint write. Non-nil means the guest is mid-adjustment, which
    /// also suppresses polling from yanking the number back under their finger.
    private var setPointTask: Task<Void, Never>?

    /// A colour light doesn't switch on — it boots, taking tens of seconds, and reports
    /// itself off the whole time. Without this the guest sees their choice register, flip
    /// back to "Off" on the next poll, then come on again by itself. Holds the requested
    /// state on screen until the controller catches up or the window lapses.
    private var pendingLight: (isOn: Bool, colorIndex: Int?, until: Date)?
    /// Generous: changing colour on these fixtures power-cycles the lamp.
    private static let lightBootWindow: TimeInterval = 60

    private let pollInterval: Duration
    private let setPointDebounce: Duration

    init(
        client: IAqualinkClient = LiveIAqualinkClient(),
        schedule: ShutoffSchedule = .heater(),
        jetsSchedule: ShutoffSchedule = .jets(),
        lightsSchedule: ShutoffSchedule = .lights(),
        solar: SolarClock = SolarClock(coordinate: PoolLocationStore.load()),
        pump: PumpOwnership = PumpOwnership(),
        credentials: CredentialProvider = .keychain,
        pollInterval: Duration = .seconds(15),
        setPointDebounce: Duration = .milliseconds(1200)
    ) {
        self.client = client
        self.schedule = schedule
        self.jetsSchedule = jetsSchedule
        self.lightsSchedule = lightsSchedule
        self.solar = solar
        self.pump = pump
        self.credentials = credentials
        self.pollInterval = pollInterval
        self.setPointDebounce = setPointDebounce
        self.heatDeadline = schedule.deadline
        self.jetsDeadline = jetsSchedule.deadline
        self.lightsDeadline = lightsSchedule.deadline
    }

    /// Waits for a pending debounced setpoint write, then for the write queue to drain.
    /// Tests only — awaiting the debounce rather than sleeping past it keeps them from
    /// racing the clock on a loaded machine.
    func settle() async {
        if let setPointTask { _ = await setPointTask.value }
        _ = await writeChain.value
    }

    var heatPresets: [TimeInterval] { schedule.presets }
    var jetsPresets: [TimeInterval] { jetsSchedule.presets }
    /// For the owner-facing copy on the setup screen.
    var heatMaxHours: Int { Int((schedule.maxDuration ?? 0) / 3600) }

    // MARK: - Lifecycle

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                await self?.enforceDeadlines()
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
            // `confirmed` deliberately keeps the controller's raw answer — write
            // reconciliation must run against the truth — while `state` may hold the guest's
            // pending light choice for display.
            applyLightHold()
            // Sync here rather than in the write's completion hook: hooks run before the
            // follow-up refresh, so they'd be deciding against state we already know is stale.
            syncLightsDawn()
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
        // A booting light still reports itself off, so reconciling against the controller
        // would decide "already off" and send nothing — leaving the guest unable to cancel
        // a light that is about to come on. Our pending intent is the better truth here.
        let believedOn = pendingLight?.isOn
        markLightPending(isOn: on, colorIndex: on ? state.lightColorIndex : nil)
        apply(
            { $0.isLightOn = on },
            action: { [client] session, confirmed in
                guard (believedOn ?? confirmed.isLightOn) != on else { return }
                try await client.toggleAux(.light, session: session)
            },
            failureMessage: "Couldn't reach the light.",
            onFailure: { [weak self] in self?.clearLightPending() }
        )
    }

    func setLightColor(_ color: LightColor) {
        markLightPending(isOn: true, colorIndex: color.id)
        apply(
            { $0.lightColorIndex = color.id; $0.isLightOn = true },
            action: { [client] session, _ in
                // set_light is an assignment, not a toggle, and turns the light on implicitly,
                // so it needs no reconciliation.
                try await client.setLightColor(index: color.id, session: session)
            },
            failureMessage: "Couldn't change the color.",
            onFailure: { [weak self] in self?.clearLightPending() }
        )
    }

    /// Runs the jets for a fixed stretch, then shuts them off — the same arrangement as the
    /// heater, and for the same reason: the API has no duration, so the app owns it.
    func startJets(for duration: TimeInterval) {
        // Armed before the write for the same reason as the heater: a spare deadline for a
        // pump that never started is harmless, a running pump with no deadline is not.
        jetsDeadline = jetsSchedule.arm(for: duration)
        apply(
            { $0.areJetsOn = true },
            action: { [client] session, confirmed in
                guard !confirmed.areJetsOn else { return }
                try await client.toggleAux(.jets, session: session)
            },
            failureMessage: "Couldn't start the jets.",
            onFailure: { [weak self, jetsSchedule] in
                jetsSchedule.disarm()
                self?.jetsDeadline = nil
            }
        )
    }

    func stopJets() {
        apply(
            { $0.areJetsOn = false },
            action: { [client] session, confirmed in
                guard confirmed.areJetsOn else { return }
                try await client.toggleAux(.jets, session: session)
            },
            failureMessage: "Couldn't stop the jets.",
            // Disarm only once the jets are confirmed off, so a failed stop still has a
            // deadline left to retry against.
            onSuccess: { [weak self, jetsSchedule] in
                jetsSchedule.disarm()
                self?.jetsDeadline = nil
            },
            onFailure: { [weak self, jetsSchedule] in self?.jetsDeadline = jetsSchedule.deadline }
        )
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
                guard let self else { return }
                self.targetTemperature = self.confirmed.poolSetPoint
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
            action: { [client, pump] session, confirmed in
                if confirmed.poolSetPoint != target {
                    try await client.setPoolSetPoint(target, session: session)
                }
                // Circulation first: the heater simply will not fire without it, so asking
                // for heat with the pump off would start a timer and warm nothing.
                if !confirmed.isPumpOn {
                    try await client.togglePoolPump(session: session)
                    pump.startedForHeat = true
                }
                guard !confirmed.isHeaterOn else { return }
                try await client.togglePoolHeater(session: session)
            },
            failureMessage: "Couldn't start the heater.",
            onFailure: { [weak self, schedule] in
                schedule.disarm()
                self?.heatDeadline = nil
            }
        )
    }

    func stopHeating() {
        apply(
            { $0.isHeaterOn = false },
            action: { [client, pump] session, confirmed in
                if confirmed.isHeaterOn {
                    try await client.togglePoolHeater(session: session)
                }
                // Hand the pump back only if we were the ones who started it.
                if pump.startedForHeat, confirmed.isPumpOn {
                    try await client.togglePoolPump(session: session)
                }
                pump.release()
            },
            failureMessage: "Couldn't stop the heater.",
            // Disarm only once the heater is actually off. Disarming up front would mean a
            // failed stop leaves the heater running with nothing left to switch it off.
            onSuccess: { [weak self, schedule] in
                schedule.disarm()
                self?.heatDeadline = nil
            },
            onFailure: { [weak self, schedule] in self?.heatDeadline = schedule.deadline }
        )
    }

    // MARK: - Automatic shutoffs

    /// Called on every poll tick. Checking the clock here rather than scheduling timers means
    /// a missed or failed shutoff is retried automatically on the next tick, and a deadline
    /// that elapsed while the app was dead fires on the first tick after launch.
    func enforceDeadlines(now: Date = Date()) async {
        syncLightsDawn(now: now)
        await enforceHeater(now: now)
        await enforceJets(now: now)
        await enforceLights(now: now)
    }

    private func markLightPending(isOn: Bool, colorIndex: Int?) {
        pendingLight = (isOn, colorIndex, Date().addingTimeInterval(Self.lightBootWindow))
        isLightStarting = isOn
    }

    private func clearLightPending() {
        pendingLight = nil
        isLightStarting = false
    }

    /// Shows the guest's choice until the fixture agrees, or the window lapses and the
    /// controller wins. Only `state` is touched — never `confirmed`.
    private func applyLightHold(now: Date = Date()) {
        guard let pending = pendingLight else { return }
        let agrees = confirmed.isLightOn == pending.isOn
            && (pending.colorIndex == nil || confirmed.lightColorIndex == pending.colorIndex)
        if agrees || now >= pending.until {
            clearLightPending()
            return
        }
        state.isLightOn = pending.isOn
        if let index = pending.colorIndex { state.lightColorIndex = index }
        isLightStarting = pending.isOn
    }

    /// Keeps the lights' dawn deadline in step with reality. Armed whenever the lights are
    /// seen on without one — which covers being switched on from the official app, or the
    /// iPad restarting mid-evening — and cleared when they go off.
    private func syncLightsDawn(now: Date = Date()) {
        if confirmed.isLightOn || state.isLightOn {
            if lightsSchedule.deadline == nil {
                lightsDeadline = lightsSchedule.arm(until: solar.nextDawn(after: now))
            }
        } else if lightsSchedule.deadline != nil {
            lightsSchedule.disarm()
            lightsDeadline = nil
        }
    }

    private func enforceHeater(now: Date) async {
        guard schedule.hasExpired(now: now) else {
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
        if pump.startedForHeat, confirmed.isPumpOn {
            do {
                try await client.togglePoolPump(session: session)
                state.isPumpOn = false
                confirmed.isPumpOn = false
            } catch {
                return  // retried on the next tick; the deadline is still armed
            }
        }
        pump.release()
        schedule.disarm()
        heatDeadline = nil
        state.isHeaterOn = false
        confirmed.isHeaterOn = false
    }

    private func enforceJets(now: Date) async {
        guard jetsSchedule.hasExpired(now: now) else {
            jetsDeadline = jetsSchedule.deadline
            return
        }
        guard let session = try? await activeSession() else { return }

        if confirmed.areJetsOn {
            do {
                try await client.toggleAux(.jets, session: session)
            } catch {
                return
            }
        }
        jetsSchedule.disarm()
        jetsDeadline = nil
        state.areJetsOn = false
        confirmed.areJetsOn = false
    }

    /// Lights go off at dawn rather than after a duration — nobody sets a timer for "until
    /// it's light out", and a light left on overnight is the one that actually gets forgotten.
    private func enforceLights(now: Date) async {
        guard lightsSchedule.hasExpired(now: now) else {
            lightsDeadline = lightsSchedule.deadline
            return
        }
        guard let session = try? await activeSession() else { return }

        if confirmed.isLightOn {
            do {
                try await client.toggleAux(.light, session: session)
            } catch {
                return
            }
        }
        lightsSchedule.disarm()
        lightsDeadline = nil
        state.isLightOn = false
        confirmed.isLightOn = false
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
        jetsSchedule.disarm()
        lightsSchedule.disarm()
        session = nil
        heatDeadline = nil
        jetsDeadline = nil
        lightsDeadline = nil
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
        // Main-actor isolated, unlike `action`: these run after the write settles and touch
        // store state, so they must not hop off the actor.
        onSuccess: (() -> Void)? = nil,
        onFailure: (() -> Void)? = nil
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
                onSuccess?()
                // Re-read so the next queued write reconciles against fresh truth.
                await self.refresh()
            } catch {
                self.state = rollback
                self.banner = failureMessage
                onFailure?()
            }
        }
    }

    func dismissBanner() { banner = nil }
}
