import Foundation

/// A persisted "turn this off at" deadline.
///
/// Nothing in the iAqualink API accepts a duration, so every automatic shutoff in this app is
/// the app's own doing — which makes the iPad the only thing that will ever switch the
/// equipment back off. Deadlines are therefore written to disk the moment something is turned
/// on, not held in memory: a crash, a force-quit, or a reboot must not be able to strand a
/// heater, a pump, or a light in the on state. On launch `PoolStore` reads them back and
/// either re-arms or fires immediately, depending on whether the deadline has already passed.
///
/// One instance per circuit, each with its own key.
nonisolated struct ShutoffSchedule {
    /// Hard ceiling applied to `arm(for:)`, regardless of what is requested.
    /// Nil means no cap — the lights use an absolute dawn time, which can be many hours out.
    let maxDuration: TimeInterval?

    /// What the guest can pick. Empty for circuits that aren't driven by duration buttons.
    let presets: [TimeInterval]

    private let key: String
    private let defaults: UserDefaults

    init(key: String, maxDuration: TimeInterval?, presets: [TimeInterval],
         defaults: UserDefaults = .standard) {
        self.key = key
        self.maxDuration = maxDuration
        self.presets = presets
        self.defaults = defaults
    }

    /// The heater: hours, capped at four.
    static func heater(defaults: UserDefaults = .standard) -> ShutoffSchedule {
        ShutoffSchedule(
            key: "heat.deadline",
            maxDuration: 4 * 60 * 60,
            presets: [1 * 60 * 60, 2 * 60 * 60, 4 * 60 * 60],
            defaults: defaults
        )
    }

    /// The jets: minutes, not hours. Nobody sits in a plunge pool for four hours, and a pump
    /// left running overnight is noise and wear for no benefit.
    static func jets(defaults: UserDefaults = .standard) -> ShutoffSchedule {
        ShutoffSchedule(
            key: "jets.deadline",
            maxDuration: 2 * 60 * 60,
            presets: [15 * 60, 30 * 60, 60 * 60],
            defaults: defaults
        )
    }

    /// The lights: no presets and no cap — armed to the next dawn rather than a duration.
    static func lights(defaults: UserDefaults = .standard) -> ShutoffSchedule {
        ShutoffSchedule(key: "lights.deadline", maxDuration: nil, presets: [], defaults: defaults)
    }

    /// The pending shutoff, or nil when nothing is scheduled.
    var deadline: Date? {
        get {
            let stamp = defaults.double(forKey: key)
            return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        }
        nonmutating set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }

    /// Starts the clock, clamped to `maxDuration`. Returns the stored deadline.
    @discardableResult
    func arm(for duration: TimeInterval, now: Date = Date()) -> Date {
        var seconds = max(duration, 0)
        if let maxDuration { seconds = min(seconds, maxDuration) }
        let target = now.addingTimeInterval(seconds)
        deadline = target
        return target
    }

    /// Starts the clock at an absolute time — used for "off at dawn".
    @discardableResult
    func arm(until date: Date) -> Date {
        deadline = date
        return date
    }

    func disarm() { deadline = nil }

    /// True when a deadline exists and has passed — the trigger to send the off command.
    func hasExpired(now: Date = Date()) -> Bool {
        guard let deadline else { return false }
        return now >= deadline
    }

    func remaining(now: Date = Date()) -> TimeInterval? {
        guard let deadline else { return nil }
        return max(0, deadline.timeIntervalSince(now))
    }
}
