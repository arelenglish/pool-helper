import SwiftUI

struct ContentView: View {
    @State private var store: PoolStore
    @State private var showingSetup = false

    // Built in the body rather than as a default argument: default arguments are evaluated
    // in a nonisolated context, and PoolStore is main-actor bound.
    init(store: PoolStore? = nil) {
        _store = State(initialValue: store ?? PoolStore())
    }

    var body: some View {
        ForcedLandscape {
            ZStack {
                PoolBackground()

                VStack(spacing: 18) {
                    header

                    GeometryReader { proxy in
                        cards(forWidth: proxy.size.width)
                    }
                }
                // Safe areas are ignored by the rotation wrapper, so the inset is explicit.
                .padding(.horizontal, PoolTheme.screenPadding)
                .padding(.top, 14)
                .padding(.bottom, PoolTheme.screenPadding)

                if let banner = store.banner {
                    BannerView(message: banner)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .onAppear {
                            Task {
                                try? await Task.sleep(for: .seconds(4))
                                store.dismissBanner()
                            }
                        }
                }
            }
        }
        .animation(.snappy, value: store.banner)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .task {
            store.start()
            if store.connection == .needsSetup { showingSetup = true }
        }
        .onChange(of: store.connection) { _, connection in
            if connection == .needsSetup { showingSetup = true }
        }
        .fullScreenCover(isPresented: $showingSetup) {
            SetupView(store: store)
        }
    }

    @ViewBuilder
    private func cards(forWidth width: CGFloat) -> some View {
        switch CardLayout.forWidth(width) {
        case .threeColumn:
            HStack(alignment: .top, spacing: PoolTheme.cardGap) {
                lightsCard
                heatCard
                jetsCard
            }
        case .twoColumn:
            HStack(alignment: .top, spacing: PoolTheme.cardGap) {
                lightsCard
                VStack(spacing: PoolTheme.cardGap) {
                    heatCard
                    jetsCard
                }
            }
        case .stacked:
            ScrollView(showsIndicators: false) {
                VStack(spacing: 22) {
                    lightsCard.frame(minHeight: 460)
                    heatCard.frame(minHeight: 520)
                    jetsCard.frame(minHeight: 300)
                }
            }
        }
    }

    private var lightsCard: some View {
        LightsCard(
            isOn: store.state.isLightOn,
            colorIndex: store.state.lightColorIndex,
            setOn: store.setLight,
            setColor: store.setLightColor
        )
        .frame(maxWidth: .infinity)
    }

    private var heatCard: some View {
        HeatCard(
            poolTemp: store.state.poolTemp,
            targetTemperature: store.targetTemperature,
            presets: store.heatPresets,
            isHeaterOn: store.state.isHeaterOn,
            isPumpOn: store.state.isPumpOn,
            deadline: store.heatDeadline,
            adjustTarget: store.adjustTargetTemperature,
            startHeating: store.startHeating,
            stopHeating: store.stopHeating
        )
        .frame(maxWidth: .infinity)
    }

    private var jetsCard: some View {
        JetsCard(
            isOn: store.state.areJetsOn,
            presets: store.jetsPresets,
            deadline: store.jetsDeadline,
            startJets: store.startJets,
            stopJets: store.stopJets
        )
            .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(alignment: .center) {
            // The hidden way in. A three-second press in the corner is not something a guest
            // discovers, and nothing else on screen hints that the account exists.
            Color.clear
                .frame(width: 100, height: 60)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 3) { showingSetup = true }
                .accessibilityHidden(true)

            Spacer()

            VStack(spacing: 4) {
                Text("The Pool")
                    .font(PoolFont.screenTitle)
                    .foregroundStyle(.white)
                connectionLine
            }

            Spacer()

            HStack(spacing: 7) {
                Image(systemName: "sun.max.fill")
                Text(store.state.airTemp.map { "\($0)°" } ?? "--")
            }
            .font(.system(size: 21, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.65))
            .frame(width: 100, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var connectionLine: some View {
        switch store.connection {
        case .online:
            Text("Connected")
                .font(PoolFont.caption)
                .foregroundStyle(.white.opacity(0.45))
        case .connecting:
            Text("Connecting…")
                .font(PoolFont.caption)
                .foregroundStyle(.white.opacity(0.45))
        case .offline:
            // Guests get "showing last known", not a stack trace. The controls still work;
            // they just may be acting on stale state.
            Label("Reconnecting…", systemImage: "wifi.exclamationmark")
                .font(PoolFont.caption)
                .foregroundStyle(.orange.opacity(0.85))
        case .needsSetup:
            Text("Not signed in")
                .font(PoolFont.caption)
                .foregroundStyle(.orange.opacity(0.85))
        }
    }
}

private struct BannerView: View {
    let message: String

    var body: some View {
        VStack {
            Text(message)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
                .environment(\.colorScheme, .dark)
                .shadow(radius: 20)
                .padding(.top, 20)
            Spacer()
        }
    }
}

#Preview(traits: .landscapeLeft) {
    ContentView(store: PoolStore(client: MockIAqualinkClient(), pollInterval: .seconds(3)))
}
