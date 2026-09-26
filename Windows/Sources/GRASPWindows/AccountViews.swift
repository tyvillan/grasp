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
        }    }
}

/// "Continue with Google" or email and password, for the same account as
/// the Mac and iPhone apps.
///
/// Google runs in the default browser, which comes back to GRASP through
/// the `grasp://auth-callback` link (registered when GRASP starts); the
/// sheet closes itself once that link has signed the account in.
struct SignInSheet: View {
    let account: Account
    let close: () -> Void
    @State var email = ""
    @State var password = ""
    @State var error: String?
    @State var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in to GRASP")
                .font(Font.system(size: 18, weight: .semibold))
                .foregroundColor(GRASPColor.textPrimary)
            Text("Use the account from your Mac or iPhone, and this PC syncs the same library.")
                .font(GRASPFont.body)
                .foregroundColor(GRASPColor.textSecondary)

            googleSection

            HStack(spacing: 10) {
                Rectangle().fill(GRASPColor.hairline).frame(width: 150.0, height: 1.0)
                Text("or").font(GRASPFont.meta).foregroundColor(GRASPColor.textTertiary)
                Rectangle().fill(GRASPColor.hairline).frame(width: 150.0, height: 1.0)
            }

            TextField("Email", text: $email)
            SecureField("Password", text: $password)
            if let error {
                Text(error).font(GRASPFont.meta).foregroundColor(GRASPColor.rejected)
            }
            if working {
                ProgressView("Signing in…")
            }
            HStack(spacing: 8) {
                Button("Create account") { submit(createAccount: true) }
                    .disabled(working || !canSubmit)
                    .fixedSize()
                Spacer()
                Button("Cancel") {
                    account.cancelGoogleSignIn()
                    close()
                }
                .disabled(working)
                .fixedSize()
                Button("Sign In") { submit(createAccount: false) }
                    .disabled(working || !canSubmit)
                    .fixedSize()
            }
        }
        .padding(24)
        .frame(width: 420.0)
        .background(GRASPColor.canvas)
        // Google finishes in the browser; once its link signs the account
        // in, there's nothing left for this sheet to do.
        .onChange(of: account.email) {
            if account.email != nil { close() }
        }
    }

    @ViewBuilder
    private var googleSection: some View {
        switch account.google {
        case .waiting:
            VStack(alignment: .leading, spacing: 6) {
                Text("Finish signing in with Google in your browser.")
                    .font(GRASPFont.rowTitle.weight(.semibold))
                    .foregroundColor(GRASPColor.textPrimary)
                Text("When the browser asks to open GRASP, allow it.")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textSecondary)
                Text("This window closes by itself once you're in.")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.textSecondary)
                HStack(spacing: 8) {
                    Button("Open the Browser Again") { openGoogle() }.fixedSize()
                    Button("Stop") { account.cancelGoogleSignIn() }.fixedSize()
                }
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                googleButton
                Text("Google sign-in didn't finish: \(message)")
                    .font(GRASPFont.meta)
                    .foregroundColor(GRASPColor.rejected)
            }
        case .idle:
            googleButton
        }
    }

    private var googleButton: some View {
        HStack(spacing: 8) {
            Text("G")
                .font(Font.system(size: 15, weight: .bold))
                .foregroundColor(GRASPColor.accent)
            Text("Continue with Google")
                .font(GRASPFont.rowTitle.weight(.semibold))
                .foregroundColor(GRASPColor.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(GRASPColor.surface)
        .cornerRadius(8)
        .onTapGesture { openGoogle() }
    }

    private func openGoogle() {
        error = nil
        ExternalLink.open(account.startGoogleSignIn())
    }

    private var canSubmit: Bool {
        email.contains("@") && password.count >= 6
    }

    private func submit(createAccount: Bool) {
        working = true
        error = nil
        account.cancelGoogleSignIn()
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
