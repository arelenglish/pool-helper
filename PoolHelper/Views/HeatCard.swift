import SwiftUI

struct HeatCard: View {
    let poolTemp: Int?
    let targetTemperature: Int
    let isHeaterOn: Bool
    let isPumpOn: Bool
    let deadline: Date?
    let adjustTarget: (Int) -> Void
    let startHeating: (TimeInterval) -> Void
    let stopHeating: () -> Void

    /// The heater will not produce heat unless the target is above the water. Offering a
    /// duration here would start a timer that can't do anything.
    private var wouldHeat: Bool {
        guard let poolTemp else { return true }
        return targetTemperature > poolTemp
    }

    /// Heat has more to say than the other two cards, and an iPad mini in landscape is only
    /// 744pt tall. Rather than shrink the type everywhere to satisfy the smallest device,
    /// the card offers a roomy layout and a tighter one and takes whichever fits.
    private struct Metrics {
        let water: CGFloat
        let degree: CGFloat
        let target: CGFloat
        let stepper: CGFloat
        let buttonPadding: CGFloat
        let spacing: CGFloat
        let rowGap: CGFloat

        static let roomy = Metrics(water: 72, degree: 38, target: 52, stepper: 64,
                                   buttonPadding: 15, spacing: 14, rowGap: 10)
        static let tight = Metrics(water: 54, degree: 30, target: 42, stepper: 52,
                                   buttonPadding: 11, spacing: 8, rowGap: 7)
    }

    var body: some View {
        Card(title: "Heat", systemImage: "thermometer.medium", accent: PoolTheme.flame) {
            ViewThatFits(in: .vertical) {
                content(.roomy)
                content(.tight)
            }
        }
    }

    private func content(_ m: Metrics) -> some View {
        VStack(spacing: m.spacing) {
            // Outer spacers centre the whole group; the middle one is capped so the reading
            // and the buttons don't drift to opposite ends of a tall card.
            Spacer(minLength: 0)

            currentTemperature(m)
            targetPicker(m)

            Spacer(minLength: 4).frame(maxHeight: 40)

            VStack(spacing: m.rowGap) {
                ForEach(HeatSchedule.presets, id: \.self) { duration in
                    DurationButton(duration: duration, enabled: wouldHeat, padding: m.buttonPadding) {
                        startHeating(duration)
                    }
                }

                Button(action: stopHeating) {
                    Text("Stop heating")
                        .font(PoolFont.button)
                        .foregroundStyle(isHeaterOn ? .white : .white.opacity(0.3))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, m.buttonPadding)
                        .background(
                            RoundedRectangle(cornerRadius: 20)
                                .fill(Color.white.opacity(isHeaterOn ? 0.16 : 0.05))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!isHeaterOn)
            }

            status
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }

    private func currentTemperature(_ m: Metrics) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 2) {
                Text(poolTemp.map(String.init) ?? "--")
                    .font(.system(size: m.water, weight: .thin, design: .rounded))
                    .contentTransition(.numericText())
                Text("°")
                    .font(.system(size: m.degree, weight: .thin, design: .rounded))
                    .padding(.top, 8)
            }
            .foregroundStyle(.white)

            Text(poolTemp == nil ? "waiting for a reading" : "water now")
                .font(PoolFont.caption)
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
        .animation(.snappy, value: poolTemp)
    }

    /// Guests pick the exact temperature. Steppers rather than a slider — a slider is hard to
    /// land on a precise degree with wet hands, and the whole range is only 40 wide.
    private func targetPicker(_ m: Metrics) -> some View {
        VStack(spacing: 8) {
            Text("Warm it to")
                .font(PoolFont.body)
                .foregroundStyle(.white.opacity(0.65))

            HStack(spacing: 12) {
                StepButton(symbol: "minus", size: m.stepper,
                           enabled: targetTemperature > PoolState.minSetPoint) {
                    adjustTarget(targetTemperature - 1)
                }

                Text("\(targetTemperature)°")
                    .font(.system(size: m.target, weight: .medium, design: .rounded))
                    .foregroundStyle(PoolTheme.flame)
                    .contentTransition(.numericText())
                    .frame(minWidth: 104)
                    .animation(.snappy(duration: 0.2), value: targetTemperature)

                StepButton(symbol: "plus", size: m.stepper,
                           enabled: targetTemperature < PoolState.maxSetPoint) {
                    adjustTarget(targetTemperature + 1)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Target temperature \(targetTemperature) degrees")
    }

    /// Every branch states something the app can actually check — the setpoint against the
    /// water, or whether the pump is running. An earlier version keyed off the raw
    /// `pool_heater` flag and asserted "pool is at target" while the water sat 11°F below it.
    /// Report the numbers; don't narrate the controller's internals.
    @ViewBuilder
    private var status: some View {
        Group {
            if let poolTemp, !wouldHeat {
                // This line does the job the disabled buttons imply. An earlier version also
                // showed a separate notice box above them, which said the same thing twice
                // and pushed the card's content past its own bottom edge on an iPad mini.
                Text("Already \(poolTemp)° — tap + to warm it further")
                    .foregroundStyle(.white.opacity(0.75))
            } else if isHeaterOn, !isPumpOn {
                Text("Heater on — waiting for the pump")
                    .foregroundStyle(.white.opacity(0.65))
            } else if isHeaterOn, let deadline {
                // A wall-clock time reads better than a countdown — guests are deciding
                // whether to get in, not watching a timer.
                Text("Heating until \(deadline.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(PoolTheme.flame)
            } else if isHeaterOn {
                Text("Heating").foregroundStyle(PoolTheme.flame)
            } else {
                Text("Heater is off").foregroundStyle(.white.opacity(0.5))
            }
        }
        .font(PoolFont.status)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }
}

private struct StepButton: View {
    let symbol: String
    let size: CGFloat
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(enabled ? PoolTheme.flame : .white.opacity(0.18))
                .frame(width: size, height: size)
                .background(
                    Circle().fill(
                        enabled ? PoolTheme.flame.opacity(0.16) : Color.white.opacity(0.04)
                    )
                )
                .overlay(
                    Circle().strokeBorder(
                        enabled ? PoolTheme.flame.opacity(0.45) : .white.opacity(0.07),
                        lineWidth: 1.5
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(symbol == "plus" ? "Warmer" : "Cooler")
    }
}

private struct DurationButton: View {
    let duration: TimeInterval
    let enabled: Bool
    let padding: CGFloat
    let action: () -> Void

    private var label: String {
        let hours = Int(duration / 3600)
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 18, weight: .semibold))
                Text(label)
                Spacer(minLength: 0)
            }
            .font(PoolFont.button)
            .foregroundStyle(enabled ? PoolTheme.flame : .white.opacity(0.22))
            .padding(.horizontal, 20)
            .padding(.vertical, padding)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(enabled ? PoolTheme.flame.opacity(0.16) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(
                        enabled ? PoolTheme.flame.opacity(0.38) : .white.opacity(0.06),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("Heat for \(label)")
    }
}

#Preview(traits: .landscapeLeft) {
    ZStack {
        PoolBackground()
        HeatCard(
            poolTemp: 95, targetTemperature: 104, isHeaterOn: true, isPumpOn: true,
            deadline: Date().addingTimeInterval(7200),
            adjustTarget: { _ in }, startHeating: { _ in }, stopHeating: {}
        )
        .frame(width: 380, height: 620)
    }
}
