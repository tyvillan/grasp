import Foundation
import GRASPCore
import SwiftCrossUI

/// The sidebar's account line: how sync is doing, or a way to sign in.
/// Sync Now and Sign Out live in Settings, as on the Mac.
struct AccountPanel: View {
    let account: Account
    @State var showingSignIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let email = account.email {
                Text(email).font(GRASPFont.meta).foregroundColor(GRASPColor.textSecondary).lineLimit(1)
                Text(account.isSyncing ? "Syncing…" : (account.status ?? "Signed in"))
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textTertiary)
            } else {
                if let status = account.status {
                    Text(status).font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
                }
                Button("Sign in to sync…") { showingSignIn = true }
            }
        }
        .sheet(isPresented: $showingSignIn) {
            SignInSheet(account: account) { showingSignIn = false }
        }
    }
}

/// Email and password, for the same account as the Mac and iPhone apps.
struct SignInSheet: View {
    let account: Account
    let close: () -> Void
    @State var email = ""
    @State var password = ""
    @State var error: String?
    @State var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in to GRASP").font(.title3)
            Text("Use your Mac or iPhone account to sync this PC.")
                .foregroundColor(.gray)
            TextField("Email", text: $email)
            SecureField("Password", text: $password)
            if let error {
                Text(error).foregroundColor(.red)
            }
            if working {
                ProgressView("Signing in…")
            }
            HStack(spacing: 8) {
                Button("Sign in") { submit(createAccount: false) }
                    .disabled(working || !canSubmit)
                    .fixedSize()
                Button("Create account") { submit(createAccount: true) }
                    .disabled(working || !canSubmit)
                    .fixedSize()
                Button("Cancel") { close() }
                    .disabled(working)
                    .fixedSize()
            }
            Text("Signed in with Google on the Mac? Google sign-in isn't on Windows yet. On the Mac, open Settings → Account & Sync → Password for other devices, set one, then use it here with the same email.")
                .font(.caption)
                .foregroundColor(.gray)
        }
        .padding(24)
        .frame(width: 420.0)
    }

    private var canSubmit: Bool {
        email.contains("@") && password.count >= 6
    }

    private func submit(createAccount: Bool) {
        working = true
        error = nil
        Task {
            do {
                try await account.signIn(email: email.trimmingCharacters(in: .whitespaces),
                                         password: password, createAccount: createAccount)
                working = false
                close()
            } catch {
                working = false
                self.error = error.localizedDescription
            }
        }
    }
}
