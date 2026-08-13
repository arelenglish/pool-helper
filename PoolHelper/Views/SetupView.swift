import SwiftUI

/// Owner-only. Reachable only by a three-second press in the top-left corner, so nothing on
/// the guest surface leads here and the account is never mentioned in front of guests.
struct SetupView: View {
    let store: PoolStore
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

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
                         + "\(Int(HeatSchedule.maxDuration / 3600)) hours.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Heating")
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
