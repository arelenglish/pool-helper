import SwiftUI

struct JetsCard: View {
    let isOn: Bool
    let presets: [TimeInterval]
    let deadline: Date?
    let startJets: (TimeInterval) -> Void
    let stopJets: () -> Void

    var body: some View {
        Card(title: "Jets", systemImage: "water.waves", accent: PoolTheme.jet) {
            VStack(spacing: 16) {
                Spacer(minLength: 0)

                // An indicator, not a button. With duration buttons below, a tappable disc
                // would beg the question "on for how long?" — the durations answer it.
                indicator

                Spacer(minLength: 4).frame(maxHeight: 32)

                VStack(spacing: 10) {
                    ForEach(presets, id: \.self) { duration in
                        DurationButton(
                            duration: duration,
                            systemImage: "water.waves",
                            tint: PoolTheme.jet,
                            enabled: true
                        ) {
                            startJets(duration)
                        }
                    }

                    StopButton(title: "Stop jets", enabled: isOn, action: stopJets)
                }

                status
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var indicator: some View {
        VStack(spacing: 12) {
            Image(systemName: "power")
                .font(.system(size: 52, weight: .thin))
                .frame(width: 128, height: 128)
                .background(
                    Circle().fill(isOn ? PoolTheme.jet.opacity(0.16) : Color.white.opacity(0.06))
                )
                .overlay(
                    Circle().strokeBorder(
                        isOn ? PoolTheme.jet.opacity(0.6) : .white.opacity(0.12), lineWidth: 2
                    )
                )
                .shadow(color: isOn ? PoolTheme.jet.opacity(0.3) : .clear, radius: 22)

            Text(isOn ? "Running" : "Off")
                .font(PoolFont.toggleLabel)
        }
        .foregroundStyle(isOn ? PoolTheme.jet : .white.opacity(0.6))
        .frame(maxWidth: .infinity)
        .animation(.snappy(duration: 0.25), value: isOn)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Jets \(isOn ? "running" : "off")")
    }

    @ViewBuilder
    private var status: some View {
        Group {
            if isOn, let deadline {
                Text("Running until \(deadline.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(PoolTheme.jet)
            } else if isOn {
                Text("Running").foregroundStyle(PoolTheme.jet)
            } else {
                Text("Pick how long to run them").foregroundStyle(.white.opacity(0.5))
            }
        }
        .font(PoolFont.status)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
    }
}

#Preview(traits: .landscapeLeft) {
    ZStack {
        PoolBackground()
        JetsCard(
            isOn: true,
            presets: [15 * 60, 30 * 60, 60 * 60],
            deadline: Date().addingTimeInterval(1800),
            startJets: { _ in }, stopJets: {}
        )
        .frame(width: 380, height: 620)
    }
}
