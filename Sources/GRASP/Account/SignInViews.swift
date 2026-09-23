import SwiftUI
import GRASPCore

/// "Continue with Google" and "Continue with email", shared by the profile
/// picker and Settings. Reports whoever signed in; what happens next is the
/// caller's decision.
struct SignInButtons: View {
    let onSignedIn: (SignedInAccount) -> Void

    private let accounts = AccountService.shared
    @State private var isWorking = false
    @State private var showingEmail = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 10) {
            Button {
                run { try await accounts.signInWithGoogle() }
            } label: {
                HStack(spacing: 8) {
                    Text("G")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(GRASPColor.accent)
                    Text("Continue with Google")
                }
                .frame(width: 240)
            }
            .buttonStyle(GRASPQuietButton())

            Button {
                showingEmail = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "envelope")
                    Text("Continue with email")
                }
                .frame(width: 240)
            }
            .buttonStyle(GRASPQuietButton())

            if isWorking {
                ProgressView().controlSize(.small)
            }
            if !accounts.isConfigured {
                Text("Sign-in isn't set up in this copy of GRASP yet -- see SYNC_SETUP.md.")
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
                    .multilineTextAlignment(.center)
            } else if let error {
                Text(error)
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.rejected)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .disabled(isWorking || !accounts.isConfigured)
        .sheet(isPresented: $showingEmail) {
            EmailSignInSheet { account in
                showingEmail = false
                onSignedIn(account)
            }
        }
    }

    private func run(_ signIn: @escaping () async throws -> SignedInAccount) {
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                onSignedIn(try await signIn())
            } catch {
                // Closing the Google window is a choice, not an error.
                let text = error.localizedDescription
                if !text.localizedCaseInsensitiveContains("cancel") { self.error = text }
            }
        }
    }
}

/// Email and password, or a sign-in link sent by email.
struct EmailSignInSheet: View {
    let onSignedIn: (SignedInAccount) -> Void

    @Environment(\.dismiss) private var dismiss
    private let accounts = AccountService.shared
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var message: String?
    @State private var isError = false

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespaces) }
    private var emailLooksValid: Bool { trimmedEmail.contains("@") && trimmedEmail.contains(".") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in with email")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(GRASPColor.textPrimary)
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .textContentType(.emailAddress)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .onSubmit { signIn() }

            if let message {
                Text(message)
                    .graspType(.meta)
                    .foregroundStyle(isError ? GRASPColor.rejected : GRASPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Email me a sign-in link") { sendLink() }
                    .buttonStyle(.link)
                    .disabled(!emailLooksValid || isWorking)
                    .help("No password needed: open the link on this Mac and you're signed in.")
                Spacer()
                if isWorking { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Account") { signUp() }
                    .disabled(!emailLooksValid || password.count < 8 || isWorking)
                    .help(password.count < 8 ? "Passwords need at least 8 characters." : "")
                Button("Sign In") { signIn() }
                    .buttonStyle(GRASPProminentButton())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!emailLooksValid || password.isEmpty || isWorking)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(GRASPColor.canvas)
    }

    private func signIn() {
        guard emailLooksValid, !password.isEmpty else { return }
        run { try await accounts.signIn(email: trimmedEmail, password: password) }
    }

    private func signUp() {
        run { try await accounts.signUp(email: trimmedEmail, password: password) }
    }

    private func sendLink() {
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await accounts.sendSignInLink(email: trimmedEmail)
                isError = false
                message = "Sent. Open the link in that email on this Mac and GRASP will sign you in."
            } catch {
                isError = true
                message = error.localizedDescription
            }
        }
    }

    private func run(_ action: @escaping () async throws -> SignedInAccount) {
        isWorking = true
        message = nil
        Task {
            defer { isWorking = false }
            do {
                onSignedIn(try await action())
            } catch AccountError.confirmEmail(let address) {
                isError = false
                message = AccountError.confirmEmail(address).errorDescription
            } catch {
                isError = true
                message = error.localizedDescription
            }
        }
    }
}

/// After signing in on a Mac where no profile belongs to that account yet:
/// download the account's library into a new profile, or bring an existing
/// profile's library up to the account.
struct AccountLinkSheet: View {
    let account: SignedInAccount
    let localProfiles: [Profile]
    let onDone: (Profile) -> Void
    let onCancel: () -> Void

    @State private var accountHasData: Bool?
    @State private var checked = false
    @State private var chosenProfileId: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Signed in as \(account.email ?? "your account")")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(GRASPColor.textPrimary)
                Text(explanation)
                    .graspType(.body)
                    .foregroundStyle(GRASPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !checked {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking your account…").graspType(.meta)
                }
            } else {
                option(
                    title: accountHasData == true ? "Download my library" : "Start a new profile",
                    detail: accountHasData == true
                        ? "A new profile on this Mac fills with your library from your other devices."
                        : "An empty profile that syncs from now on.",
                    recommended: accountHasData != false
                ) { finish(with: nil) }

                if !localProfiles.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        option(
                            title: "Use a profile on this Mac",
                            detail: accountHasData == true
                                ? "Its library is added to the one already in your account -- if both came from the same notes you'll get duplicates."
                                : "Its library is uploaded, and your other devices download it when they sign in.",
                            recommended: accountHasData == false
                        ) {
                            if let chosenProfileId,
                               let profile = localProfiles.first(where: { $0.id == chosenProfileId }) {
                                finish(with: profile)
                            }
                        }
                        Picker("Profile", selection: $chosenProfileId) {
                            ForEach(localProfiles) { profile in
                                Text(profile.name).tag(Optional(profile.id))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 240)
                        .padding(.leading, 12)
                    }
                }
            }

            if let error {
                Text(error).graspType(.meta).foregroundStyle(GRASPColor.rejected)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(GRASPColor.canvas)
        .task {
            chosenProfileId = localProfiles.first?.id
            accountHasData = await AccountService.shared.accountHasData(userId: account.userId)
            checked = true
        }
    }

    private var explanation: String {
        switch accountHasData {
        case .some(true): return "Your account already has a library from another device."
        case .some(false): return "Your account is new -- nothing has synced to it yet."
        case .none: return checked ? "GRASP couldn't reach your account to check what's in it." : ""
        }
    }

    private func option(title: String, detail: String, recommended: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).graspType(.rowTitle).foregroundStyle(GRASPColor.textPrimary)
                    if recommended {
                        Text("Recommended").graspType(.eyebrow).foregroundStyle(GRASPColor.accent)
                    }
                }
                Text(detail)
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Links `profile` (or a new one) to the account and hands it back.
    private func finish(with existing: Profile?) {
        do {
            let support = ProfilePickerView.supportDirectory()
            var profiles = try ProfileStore.loadOrMigrate(supportDirectory: support)
            var profile: Profile
            if let existing {
                profile = existing
            } else {
                let name = account.email.map { String($0.split(separator: "@").first ?? "") } ?? "My library"
                profile = Profile(name: name.isEmpty ? "My library" : name)
                profiles.append(profile)
            }
            // Link at the database level before the store opens it, so the
            // very first sync already knows which way to go.
            let database = try GRASPDatabase(path: profile.databaseURL(supportDirectory: support))
            try SyncEngine(database: database).enable(
                accountUserId: account.userId, uploadExisting: existing != nil
            )
            profile.account = account.linked
            if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[index] = profile
            }
            try ProfileStore.save(profiles, supportDirectory: support)
            onDone(profile)
        } catch {
            self.error = "Couldn't set up sync: \(error.localizedDescription)"
        }
    }
}
