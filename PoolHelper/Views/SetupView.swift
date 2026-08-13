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

    /// Nil until both fields parse as real coordinates, which is what disables Save.
    private var coordinate: SolarClock.Coordinate? {
        guard let lat = Double(latitude.trimmingCharacters(in: .whitespaces)),
              let lon = Double(longitude.trimmingCharacters(in: .whitespaces)),
              (-90...90).contains(lat), (-180...180).contains(lon)
        else { return nil }
        return SolarClock.Coordinate(latitude: lat, longitude: lon)
    }

    private func saveLocation() { PoolLocationStore.save(coordinate) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
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
                        .disabled(coordinate == nil)
                } header: {
                    Text("Pool location")
                } footer: {
                    Text("Used only to work out when the sun rises, so the lights can switch "
                         + "themselves off at dawn. It stays on this iPad, is never sent "
                         + "anywhere, and no location permission is requested. Leave it blank "
                         + "and the lights simply go off at 6am instead.")
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }

                Section {
                    Button("Sign out", role: .destructive) {
                        store.signOut()
                        email = ""
                        password = ""
                    }
                } footer: {
                    Text("Credentials are stored in this iPad's Keychain, are excluded from "
                         + "backups, and never leave the device.")
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
            }
        }
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
