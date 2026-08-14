import SwiftUI

/// Owner-only. Reachable only by a three-second press in the top-left corner, so nothing on
/// the guest surface leads here and the account is never mentioned in front of guests.
struct SetupView: View {
    let store: PoolStore
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var errorMessage: String?
    @State private var isLocating = false
    @State private var locationMessage: String?
    @State private var locationFailed = false
    @State private var savedCoordinate: SolarClock.Coordinate?
    @State private var finder = LocationFinder()

    /// Nil until both fields parse as real coordinates, which is what disables Save.
    private var coordinate: SolarClock.Coordinate? {
        guard let lat = Double(latitude.trimmingCharacters(in: .whitespaces)),
              let lon = Double(longitude.trimmingCharacters(in: .whitespaces)),
              (-90...90).contains(lat), (-180...180).contains(lon)
        else { return nil }
        return SolarClock.Coordinate(latitude: lat, longitude: lon)
    }

    /// Fills the fields rather than saving straight off, so the owner sees what's about to be
    /// stored — and can still correct it — before it takes effect.
    private func useCurrentLocation() async {
        isLocating = true
        locationMessage = nil
        locationFailed = false
        defer { isLocating = false }
        do {
            let found = try await finder.currentCoordinate()
            latitude = String(found.latitude)
            longitude = String(found.longitude)
            locationMessage = "Found it. Tap Save location to use it."
        } catch {
            locationFailed = true
            locationMessage = error.localizedDescription
        }
    }

    private func saveLocation() {
        PoolLocationStore.save(coordinate)
        savedCoordinate = coordinate
        locationFailed = false
        locationMessage = "Saved. The lights will switch off at dawn from tomorrow."
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if store.isSignedIn {
                        // Stored credentials are never read back into editable fields — they
                        // stay in the Keychain. These rows exist so a signed-in account reads
                        // as present rather than as blank fields that look like data loss.
                        LabeledContent("Email") { Text(verbatim: "••••••••••") }
                        LabeledContent("Password") { Text(verbatim: "••••••••") }
                        Label(connectionSummary, systemImage: connectionSymbol)
                            .foregroundStyle(store.connection == .online ? .green : .secondary)
                        Button("Sign out", role: .destructive) { signOut() }
                    } else {
                        TextField("Email", text: $email)
                            .textContentType(.username)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        SecureField("Password", text: $password)
                            .textContentType(.password)

                        Button(isWorking ? "Signing in…" : "Sign in") {
                            Task { await signIn() }
                        }
                        .disabled(email.isEmpty || password.isEmpty || isWorking)
                    }
                } header: {
                    Text("Account")
                } footer: {
                    Text(store.isSignedIn
                         ? "Signed in. The credentials are in this iPad's Keychain and don't "
                           + "need entering again — including after a restart."
                         : "Entered once. Stored in this iPad's Keychain, excluded from "
                           + "backups, and never sent anywhere but iAqualink.")
                }

                Section {
                    Text("Guests pick both the temperature and how long to heat. Whatever "
                         + "they choose, the heater shuts off automatically after at most "
                         + "\(store.heatMaxHours) hours, and the jets after their timer. "
                         + "The lights switch off at dawn.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Automatic shutoff")
                }

                Section {
                    Button {
                        Task { await useCurrentLocation() }
                    } label: {
                        Label(
                            isLocating ? "Locating…" : "Use this iPad's location",
                            systemImage: "location.fill"
                        )
                    }
                    .disabled(isLocating)

                    LabeledContent("Latitude") {
                        TextField("e.g. 41.4", text: $latitude)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Longitude") {
                        TextField("e.g. -70.6", text: $longitude)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                    }
                    Button("Save location") { saveLocation() }
                        .disabled(coordinate == nil || coordinate == savedCoordinate)

                    if let locationMessage {
                        Text(locationMessage)
                            .font(.footnote)
                            .foregroundStyle(locationFailed ? .red : .secondary)
                    }
                } header: {
                    Text("Pool location")
                } footer: {
                    Text("Used only to work out when the sun rises, so the lights can switch "
                         + "themselves off at dawn. Location is read once, here — never while "
                         + "guests are using the app — and only what you save is kept: a "
                         + "coordinate rounded to about a kilometre, stored on this iPad and "
                         + "never sent anywhere. Leave it blank and the lights go off at 6am "
                         + "instead.")
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }

            }
            .navigationTitle("Setup")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            if let saved = PoolLocationStore.load() {
                latitude = String(saved.latitude)
                longitude = String(saved.longitude)
                savedCoordinate = saved
            }
        }
    }

    private var connectionSummary: String {
        switch store.connection {
        case .online:     return "Connected to the pool"
        case .connecting: return "Connecting…"
        case .offline:    return "Signed in — can't reach the pool right now"
        case .needsSetup: return "Signed in — credentials were rejected"
        }
    }

    private var connectionSymbol: String {
        store.connection == .online ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath"
    }

    private func signOut() {
        store.signOut()
        email = ""
        password = ""
        errorMessage = nil
    }

    private func signIn() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await store.signIn(email: email, password: password)
            password = ""
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    SetupView(store: PoolStore(client: MockIAqualinkClient()))
}
