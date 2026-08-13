import SwiftUI

struct JetsCard: View {
    let isOn: Bool
    let setOn: (Bool) -> Void

    var body: some View {
        Card(title: "Jets", systemImage: "water.waves", accent: PoolTheme.jet) {
            VStack(spacing: 22) {
                Spacer(minLength: 0)

                // Jets has one control and a whole column to itself, so the target is a large
                // disc rather than the pill the other cards use — it fills the space instead
                // of leaving a void, and it's unmissable from across the deck.
                Button {
                    setOn(!isOn)
                } label: {
                    VStack(spacing: 14) {
                        Image(systemName: "power")
                            .font(.system(size: 62, weight: .thin))
                        Text(isOn ? "Running" : "Off")
                            .font(PoolFont.toggleLabel)
                    }
                    .foregroundStyle(isOn ? PoolTheme.jet : .white.opacity(0.6))
                    .frame(width: 210, height: 210)
                    .background(
                        Circle().fill(isOn ? PoolTheme.jet.opacity(0.16) : Color.white.opacity(0.06))
                    )
                    .overlay(
                        Circle().strokeBorder(
                            isOn ? PoolTheme.jet.opacity(0.6) : .white.opacity(0.12),
                            lineWidth: 2
                        )
                    )
                    .shadow(color: isOn ? PoolTheme.jet.opacity(0.3) : .clear, radius: 26)
                }
                .buttonStyle(.plain)
                .animation(.snappy(duration: 0.25), value: isOn)
                .accessibilityLabel("Jets. \(isOn ? "Running" : "Off")")
                .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)

                Text(isOn ? "Jets are on." : "Tap to turn on the jets.")
                    .font(PoolFont.body)
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#Preview(traits: .landscapeLeft) {
    ZStack {
        PoolBackground()
        JetsCard(isOn: true, setOn: { _ in })
            .frame(width: 380, height: 560)
    }
}
