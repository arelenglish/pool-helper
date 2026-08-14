import Foundation

/// Remembers whether *this app* started the filter pump to make heating possible.
///
/// A Jandy heater won't fire without circulation, so asking for heat with the pump off does
/// nothing. The app starts the pump in that case — but then it owns it: leaving a pump running
/// forever is the same failure the shutoff deadlines exist to prevent. So it is switched back
/// off when heating ends, and only if the app was the one that started it. A pump already
/// running on the owner's own filtration schedule is left strictly alone.
///
/// Persisted, because the heater deadline outlives app launches and the pump has to be
/// releasable on a later run.
nonisolated struct PumpOwnership {
    private static let key = "pump.startedForHeat"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// True when the app turned the pump on itself and still owes an off.
    var startedForHeat: Bool {
        get { defaults.bool(forKey: Self.key) }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }

    func release() { defaults.removeObject(forKey: Self.key) }
}
