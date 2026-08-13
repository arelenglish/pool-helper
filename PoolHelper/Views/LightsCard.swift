import SwiftUI

struct LightsCard: View {
    let isOn: Bool
    let colorIndex: Int?
    let setOn: (Bool) -> Void
    let setColor: (LightColor) -> Void

    private let columns = [GridItem(.adaptive(minimum: 60), spacing: 16)]

    private var selected: LightColor? { LightColor.named(colorIndex) }

    var body: some View {
        Card(title: "Lights", systemImage: "lightbulb.fill", accent: PoolTheme.glow) {
            VStack(spacing: 18) {
                // The selected color's name lives here rather than under every swatch. Fourteen
                // 11pt captions were unreadable at kiosk distance and crowded the grid; one
                // 23pt name says the same thing and frees the circles to be finger-sized.
                BigToggle(
                    isOn: isOn,
                    title: isOn ? (selected?.name ?? "On") : "Off",
                    subtitle: isOn ? "Tap a color to change it" : "Tap to turn on the lights",
                    tint: PoolTheme.glow,
                    action: setOn
                )

                // Centred in whatever room is left rather than pinned under the toggle: the
                // cards share a height, and on a 13" iPad that left the grid stranded at the
                // top of a mostly empty card.
                Spacer(minLength: 0)

                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(LightColor.all) { color in
                        ColorButton(
                            color: color,
                            isSelected: isOn && colorIndex == color.id,
                            action: { setColor(color) }
                        )
                    }
                }
                // Colors stay tappable while off — picking one turns the light on, which is
                // what someone reaching for a color actually wants.
                .opacity(isOn ? 1 : 0.6)
                .animation(.easeInOut(duration: 0.25), value: isOn)

                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

private struct ColorButton: View {
    let color: LightColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ColorSwatch(color: color)
                .frame(height: 66)
                .overlay(
                    Circle().strokeBorder(
                        isSelected ? .white : .white.opacity(0.25),
                        lineWidth: isSelected ? 4 : 1
                    )
                )
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                        .opacity(isSelected ? 1 : 0)
                )
                .shadow(color: isSelected ? .white.opacity(0.45) : .clear, radius: 12)
                .scaleEffect(isSelected ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.22), value: isSelected)
        .accessibilityLabel(color.name)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// A single color renders flat; a multi-color show renders as hard-edged pie segments so the
/// two kinds are distinguishable at a glance. A smooth angular gradient averages adjacent
/// hues into muddy purple and makes every show swatch look alike.
struct ColorSwatch: View {
    let color: LightColor

    var body: some View {
        Group {
            if color.isShow {
                AngularGradient(stops: segments, center: .center)
            } else {
                color.swatch[0]
            }
        }
        .clipShape(Circle())
    }

    private var segments: [Gradient.Stop] {
        let count = color.swatch.count
        return (0..<count).flatMap { index -> [Gradient.Stop] in
            let shade = color.swatch[index]
            return [
                Gradient.Stop(color: shade, location: Double(index) / Double(count)),
                Gradient.Stop(color: shade, location: Double(index + 1) / Double(count)),
            ]
        }
    }
}

#Preview(traits: .landscapeLeft) {
    ZStack {
        PoolBackground()
        LightsCard(isOn: true, colorIndex: 4, setOn: { _ in }, setColor: { _ in })
            .frame(width: 380, height: 560)
    }
}
