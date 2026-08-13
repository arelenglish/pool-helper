import SwiftUI

/// Shared look. Kept in one place so the three cards can't drift apart visually.
enum PoolTheme {
    static let cardCorner: CGFloat = 32
    static let cardPadding: CGFloat = 24
    static let cardGap: CGFloat = 20
    static let screenPadding: CGFloat = 24

    static let deepWater = Color(red: 0.02, green: 0.08, blue: 0.19)
    static let midWater = Color(red: 0.03, green: 0.22, blue: 0.42)
    static let brightWater = Color(red: 0.06, green: 0.44, blue: 0.64)

    static let glow = Color(red: 0.48, green: 0.86, blue: 1.0)
    static let flame = Color(red: 1.0, green: 0.60, blue: 0.28)
    static let jet = Color(red: 0.42, green: 0.93, blue: 0.86)
}

/// Type scale.
///
/// This screen is read standing up, from a few feet away, by people who have never seen it
/// before and may be wet. Everything is a step or two above the on-device default, and
/// nothing is smaller than 15pt — Apple's HIG floor for sustained reading is 11pt, which is
/// far too small at kiosk distance.
enum PoolFont {
    static let cardTitle = Font.system(size: 27, weight: .semibold, design: .rounded)
    static let hugeNumber = Font.system(size: 72, weight: .thin, design: .rounded)
    static let bigNumber = Font.system(size: 52, weight: .medium, design: .rounded)
    static let toggleLabel = Font.system(size: 23, weight: .semibold, design: .rounded)
    static let button = Font.system(size: 21, weight: .semibold, design: .rounded)
    static let body = Font.system(size: 18, weight: .regular, design: .rounded)
    static let caption = Font.system(size: 16, weight: .regular, design: .rounded)
    static let status = Font.system(size: 18, weight: .medium, design: .rounded)
    static let screenTitle = Font.system(size: 34, weight: .semibold, design: .rounded)
}

/// Keeps the interface in landscape no matter how the iPad is held.
///
/// A landscape-only app on a portrait iPad doesn't rotate under iPadOS 26 — it gets a
/// landscape-shaped *window* letterboxed into a portrait screen, which is where the black
/// bars and the clipped cards came from. So the app accepts every orientation and rotates
/// itself instead, always filling the screen with a landscape canvas.
struct ForcedLandscape<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            let isPortrait = proxy.size.height > proxy.size.width
            let width = isPortrait ? proxy.size.height : proxy.size.width
            let height = isPortrait ? proxy.size.width : proxy.size.height

            content
                .frame(width: width, height: height)
                // SwiftUI rotates hit-testing along with the view, so touches stay correct.
                .rotationEffect(.degrees(isPortrait ? 90 : 0))
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .ignoresSafeArea()
    }
}

/// The background. A still gradient with a slow shimmer — enough to feel like water without
/// becoming a distraction on a screen that's on all day.
struct PoolBackground: View {
    @State private var drift = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [PoolTheme.deepWater, PoolTheme.midWater, PoolTheme.brightWater],
                startPoint: .top, endPoint: .bottom
            )

            RadialGradient(
                colors: [PoolTheme.glow.opacity(0.22), .clear],
                center: drift ? .topLeading : .init(x: 0.35, y: 0.15),
                startRadius: 40, endRadius: 640
            )
            RadialGradient(
                colors: [PoolTheme.glow.opacity(0.14), .clear],
                center: drift ? .init(x: 0.75, y: 0.85) : .bottomTrailing,
                startRadius: 60, endRadius: 720
            )
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 16).repeatForever(autoreverses: true), value: drift)
        .onAppear { drift = true }
    }
}

/// The frosted panel every control sits on.
struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    let accent: Color
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(accent)
                Text(title)
                    .font(PoolFont.cardTitle)
                    .foregroundStyle(.white)
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(PoolTheme.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: PoolTheme.cardCorner))
        .overlay(
            RoundedRectangle(cornerRadius: PoolTheme.cardCorner)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
    }
}

/// "15 minutes", "1 hour", "4 hours" — the jets run in minutes and the heater in hours, so
/// one formatter covers both rather than each card inventing its own.
nonisolated enum DurationLabel {
    static func text(for duration: TimeInterval) -> String {
        let minutes = Int(duration.rounded() / 60)
        if minutes < 60 { return "\(minutes) minutes" }
        let hours = minutes / 60
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }
}

/// Starts a timed run. Shared by Heat and Jets so the two timers look and behave identically.
struct DurationButton: View {
    let duration: TimeInterval
    let systemImage: String
    let tint: Color
    let enabled: Bool
    var padding: CGFloat = 15
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                Text(DurationLabel.text(for: duration))
                Spacer(minLength: 0)
            }
            .font(PoolFont.button)
            .foregroundStyle(enabled ? tint : .white.opacity(0.22))
            .padding(.horizontal, 20)
            .padding(.vertical, padding)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(enabled ? tint.opacity(0.16) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(
                        enabled ? tint.opacity(0.38) : .white.opacity(0.06), lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("Run for \(DurationLabel.text(for: duration))")
    }
}

/// The matching "stop early" control.
struct StopButton: View {
    let title: String
    let enabled: Bool
    var padding: CGFloat = 14
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PoolFont.button)
                .foregroundStyle(enabled ? .white : .white.opacity(0.3))
                .frame(maxWidth: .infinity)
                .padding(.vertical, padding)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white.opacity(enabled ? 0.16 : 0.05))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// The primary on/off control. A wide pill rather than a tall block — it reads as one big
/// target and leaves the vertical room the cards actually need.
struct BigToggle: View {
    let isOn: Bool
    let title: String
    let subtitle: String?
    let tint: Color
    let action: (Bool) -> Void

    var body: some View {
        Button {
            action(!isOn)
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "power")
                    .font(.system(size: 30, weight: .medium))
                    .frame(width: 58, height: 58)
                    .background(
                        Circle().fill(isOn ? tint.opacity(0.22) : Color.white.opacity(0.07))
                    )
                    .overlay(
                        Circle().strokeBorder(
                            isOn ? tint.opacity(0.7) : .white.opacity(0.14), lineWidth: 2
                        )
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(PoolFont.toggleLabel)
                    if let subtitle {
                        Text(subtitle)
                            .font(PoolFont.caption)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(isOn ? tint : .white.opacity(0.62))
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(isOn ? tint.opacity(0.16) : Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(isOn ? tint.opacity(0.45) : .white.opacity(0.10), lineWidth: 1.5)
            )
            .shadow(color: isOn ? tint.opacity(0.25) : .clear, radius: 18)
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.25), value: isOn)
        .accessibilityLabel("\(title). \(isOn ? "On" : "Off")")
        .accessibilityAddTraits(isOn ? [.isSelected, .isButton] : .isButton)
    }
}
