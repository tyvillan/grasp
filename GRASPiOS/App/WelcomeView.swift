import SwiftUI
import GRASPCore

/// The first screen: sign in to bring your library over, or open a profile
/// already on this phone.
///
/// Signing in is the main path here, unlike on the Mac: a phone has no
/// notes folder to import from, so a local-only profile starts empty.
struct WelcomeView: View {
    let onOpen: (Profile) -> Void

    @State private var profiles: [Profile] = []
    @State private var linking: SignedInAccount?
    @State private var showingNewProfile = false
    private let accounts = AccountService.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Text("GRASP")
                        .font(.system(size: 15, weight: .bold))
                        .tracking(5)
                        .foregroundStyle(GRASPColor.accent)
                    Text("Your notes, ready to study.")
                        .font(.system(size: 26, weight: .semibold))
                        .tracking(-0.5)
                        .foregroundStyle(GRASPColor.textPrimary)
                        .multilineTextAlignment(.center)
                    Text("Sign in with the account you use on your Mac and your whole library comes with you.")
                        .graspType(.body)
                        .foregroundStyle(GRASPColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 56)

                SignInButtons { account in signedIn(account) }
                if let linkError = accounts.linkError {
                    Text(linkError).graspType(.meta).foregroundStyle(GRASPColor.rejected)
                }

                if !profiles.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("On this iPhone")
                            .graspType(.eyebrow)
                            .foregroundStyle(GRASPColor.textTertiary)
                        ForEach(profiles) { profile in
                            Button { onOpen(profile) } label: {
                                ProfileRow(profile: profile)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button("Use GRASP without an account") { showingNewProfile = true }
                    .buttonStyle(.plain)
                    .graspType(.meta)
                    .foregroundStyle(GRASPColor.textTertiary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .background(GRASPColor.canvas.ignoresSafeArea())
        .task { load() }
        .sheet(item: $linking) { account in
            AccountLinkSheet(
                account: account,
                localProfiles: profiles.filter { $0.account == nil },
                onDone: { profile in
                    linking = nil
                    onOpen(profile)
                },
                onCancel: { linking = nil }
            )
            .presentationDetents([.medium, .large])
        }
        .alert("New profile", isPresented: $showingNewProfile) {
            Button("Create") { createLocalProfile() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A profile that stays on this iPhone. You can sign in later from Settings to sync it.")
        }
        .onChange(of: accounts.completedFromLink) { _, _ in
            if let account = accounts.consumeCompletedFromLink() { signedIn(account) }
        }
    }

    private func load() {
        profiles = (try? ProfileStore.loadOrMigrate(supportDirectory: AppPaths.supportDirectory())) ?? []
    }

    private func signedIn(_ account: SignedInAccount) {
        load()
        if let existing = profiles.first(where: { $0.account?.userId == account.userId }) {
            onOpen(existing)
        } else {
            linking = account
        }
    }

    private func createLocalProfile() {
        let profile = Profile(name: "My library")
        profiles.append(profile)
        try? ProfileStore.save(profiles, supportDirectory: AppPaths.supportDirectory())
        onOpen(profile)
    }
}

private struct ProfileRow: View {
    let profile: Profile

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: profile.account == nil ? "person.crop.circle" : "arrow.triangle.2.circlepath.circle")
                .font(.system(size: 26))
                .foregroundStyle(GRASPColor.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).graspType(.rowTitle).foregroundStyle(GRASPColor.textPrimary)
                Text(profile.account?.email ?? "Only on this iPhone")
                    .graspType(.meta).foregroundStyle(GRASPColor.textTertiary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(GRASPColor.textTertiary)
        }
        .padding(14)
        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
