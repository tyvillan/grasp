import SwiftUI
import GRASPCore

/// Shown before the main app: pick a profile, create a local one, or sign
/// in to an account to sync a library across devices. See `ProfileStore`
/// for why the PIN is not real security.
struct ProfilePickerView: View {
    let onSelect: (Profile) -> Void

    @State private var profiles: [Profile] = []
    @State private var showingNewProfile = false
    @State private var unlockingProfile: Profile?
    @State private var loadError: String?
    /// Someone who just signed in on this Mac with no profile of theirs here.
    @State private var linking: SignedInAccount?
    private let accounts = AccountService.shared

    var body: some View {
        VStack(spacing: 24) {
            // The wordmark is set wide-tracked rather than large: this is
            // a doorway, not a splash screen, and the profiles below are
            // what the eye should land on.
            VStack(spacing: 10) {
                Text("GRASP")
                    .font(.system(size: 15, weight: .bold))
                    .tracking(5)
                    .foregroundStyle(GRASPColor.accent)
                Text("Who's studying?")
                    .font(.system(size: 26, weight: .semibold))
                    .tracking(-0.5)
                    .foregroundStyle(GRASPColor.textPrimary)
            }
            .padding(.top, 40)

            if let loadError {
                Text(loadError).font(.caption).foregroundStyle(.red)
            }

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 160))], spacing: 16) {
                    ForEach(profiles) { profile in
                        ProfileTile(profile: profile) {
                            if profile.pinHash != nil {
                                unlockingProfile = profile
                            } else {
                                onSelect(profile)
                            }
                        }
                    }
                    // Dashed, unfilled: it's an empty slot to fill, not
                    // another profile sitting alongside the real ones.
                    Button {
                        showingNewProfile = true
                    } label: {
                        VStack(spacing: 10) {
                            Image(systemName: "plus")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(GRASPColor.textTertiary)
                                .frame(width: 64, height: 64)
                            Text("New profile")
                                .graspType(.rowTitle)
                                .foregroundStyle(GRASPColor.textTertiary)
                        }
                        .frame(width: 140, height: 140)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(
                                    GRASPColor.hairlineStrong,
                                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(24)
            }

            // Signing in is how a library follows you to another device.
            // Local profiles above stay exactly as they were.
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Rectangle().fill(GRASPColor.hairline).frame(height: 1)
                    Text("Sync across your devices")
                        .graspType(.eyebrow)
                        .foregroundStyle(GRASPColor.textTertiary)
                        .fixedSize()
                    Rectangle().fill(GRASPColor.hairline).frame(height: 1)
                }
                .frame(maxWidth: 420)
                SignInButtons { account in signedIn(account) }
                if let linkError = accounts.linkError {
                    Text(linkError).graspType(.meta).foregroundStyle(GRASPColor.rejected)
                }
            }
            .padding(.bottom, 28)
        }
        .frame(minWidth: 480, minHeight: 560)
        .background(GRASPColor.background)
        .tint(GRASPColor.accent)
        .task { load() }
        .sheet(isPresented: $showingNewProfile) {
            NewProfileSheet { profile in
                profiles.append(profile)
                try? ProfileStore.save(profiles, supportDirectory: Self.supportDirectory())
                onSelect(profile)
            }
        }
        .sheet(item: $unlockingProfile) { profile in
            UnlockProfileSheet(profile: profile) {
                onSelect(profile)
            }
        }
        .sheet(item: $linking) { account in
            AccountLinkSheet(
                account: account,
                localProfiles: profiles.filter { $0.account == nil },
                onDone: { profile in
                    linking = nil
                    onSelect(profile)
                },
                onCancel: { linking = nil }
            )
        }
        // A sign-in finished by a link opened from Mail.
        .onChange(of: accounts.completedFromLink) { _, _ in
            if let account = accounts.consumeCompletedFromLink() { signedIn(account) }
        }
    }

    /// Opens the profile that belongs to this account, or asks where its
    /// library should come from when this Mac has none yet. Signing in is
    /// a stronger check than a PIN, so a signed-in profile opens directly.
    private func signedIn(_ account: SignedInAccount) {
        load()
        if let existing = profiles.first(where: { $0.account?.userId == account.userId }) {
            onSelect(existing)
        } else {
            linking = account
        }
    }

    private func load() {
        do {
            profiles = try ProfileStore.loadOrMigrate(supportDirectory: Self.supportDirectory())
        } catch {
            loadError = "Couldn't load profiles: \(error.localizedDescription)"
        }
    }

    static func supportDirectory() -> URL { AppPaths.supportDirectory() }
}

private struct ProfileTile: View {
    let profile: Profile
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Avatar(name: profile.name, size: 64, fontSize: 22)
                HStack(spacing: 4) {
                    Text(profile.name)
                        .graspType(.rowTitle)
                        .foregroundStyle(GRASPColor.textPrimary)
                        .lineLimit(1)
                    if profile.pinHash != nil {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(GRASPColor.textTertiary)
                    }
                }
                if let account = profile.account {
                    Label(account.email ?? "Synced", systemImage: "arrow.triangle.2.circlepath")
                        .graspType(.meta)
                        .foregroundStyle(GRASPColor.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                }
            }
            .frame(width: 140, height: 140)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isHovering ? GRASPColor.surfaceRaised : GRASPColor.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isHovering ? GRASPColor.accent : GRASPColor.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct NewProfileSheet: View {
    let onCreate: (Profile) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var usePIN = false
    @State private var pin = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Profile").font(.headline)
            TextField("Name", text: $name)
            Toggle("Protect with a 4-digit PIN", isOn: $usePIN)
            if usePIN {
                SecureField("PIN", text: $pin)
                    .onChange(of: pin) { pin = String(pin.filter(\.isNumber).prefix(4)) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    let profile = Profile(
                        name: name.trimmingCharacters(in: .whitespaces),
                        pinHash: (usePIN && pin.count == 4) ? ProfileStore.hashPIN(pin) : nil
                    )
                    onCreate(profile)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (usePIN && pin.count != 4))
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

private struct UnlockProfileSheet: View {
    let profile: Profile
    let onUnlock: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var wrongPIN = false

    var body: some View {
        VStack(spacing: 16) {
            Text(profile.name).font(.headline)
            SecureField("PIN", text: $pin)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                .onChange(of: pin) {
                    pin = String(pin.filter(\.isNumber).prefix(4))
                    wrongPIN = false
                }
                .onSubmit(tryUnlock)
            if wrongPIN {
                Text("Wrong PIN").font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Button("Unlock", action: tryUnlock)
                    .keyboardShortcut(.defaultAction)
                    .disabled(pin.count != 4)
            }
        }
        .padding(20)
        .frame(width: 260)
    }

    private func tryUnlock() {
        guard pin.count == 4 else { return }
        if ProfileStore.hashPIN(pin) == profile.pinHash {
            dismiss()
            onUnlock()
        } else {
            wrongPIN = true
            pin = ""
        }
    }
}
