import SwiftUI
import GRASPCore

/// Shown before the main app: pick (or create) a local profile. Purely a
/// local data-separation convenience for more than one person sharing an
/// installed copy of GRASP -- no network, no server, nothing shared
/// between profiles. See `ProfileStore`'s header comment for the full
/// design rationale, including why the PIN is not real security.
struct ProfilePickerView: View {
    let onSelect: (Profile) -> Void

    @State private var profiles: [Profile] = []
    @State private var showingNewProfile = false
    @State private var unlockingProfile: Profile?
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "text.book.closed.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(GRASPColor.accent)
                Text("GRASP")
                    .font(.graspHeading(34))
                    .foregroundStyle(GRASPColor.textPrimary)
                Text("Who's studying?")
                    .foregroundStyle(GRASPColor.textSecondary)
            }
            .padding(.top, 32)

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
                    Button {
                        showingNewProfile = true
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill").font(.system(size: 36))
                            Text("New Profile")
                        }
                        .frame(width: 140, height: 140)
                        .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(GRASPColor.stroke, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(24)
            }
        }
        .frame(minWidth: 480, minHeight: 420)
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
    }

    private func load() {
        do {
            profiles = try ProfileStore.loadOrMigrate(supportDirectory: Self.supportDirectory())
        } catch {
            loadError = "Couldn't load profiles: \(error.localizedDescription)"
        }
    }

    static func supportDirectory() -> URL {
        (try? GRASPDatabase.supportDirectory()) ?? FileManager.default.temporaryDirectory
    }
}

private struct ProfileTile: View {
    let profile: Profile
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Avatar(name: profile.name, size: 64, fontSize: 22)
                HStack(spacing: 4) {
                    Text(profile.name).lineLimit(1)
                    if profile.pinHash != nil {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 140, height: 140)
            .background(GRASPColor.surface, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(GRASPColor.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
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
