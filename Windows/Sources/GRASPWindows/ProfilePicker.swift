import Foundation
import GRASPCore
import SwiftCrossUI

/// "Who's studying?", after the Mac's `ProfilePickerView`: a tile per
/// profile on this PC (with a lock when it has a PIN) and a New Profile
/// tile. Each profile is its own library, settings and account; signing in
/// happens inside a profile, from the sidebar.
struct ProfilePicker: View {
    let profiles: [Profile]
    let open: (Profile) -> Void
    let create: (Profile) -> Void

    @State var unlocking: Profile?
    @State var pin = ""
    @State var wrongPIN = false
    @State var creating = false
    @State var newName = ""
    @State var newPIN = ""

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Text("G R A S P").font(Font.system(size: 15, weight: .bold)).foregroundColor(GRASPColor.accent)
                Text("Who's studying?").font(Font.system(size: 32, weight: .heavy)).foregroundColor(GRASPColor.textPrimary)
            }
            .padding(.top, 60)

            HStack(spacing: 16) {
                ForEach(profiles, id: \.id) { profile in
                    ProfileTile(name: profile.name, locked: profile.pinHash != nil,
                                isSelected: unlocking?.id == profile.id) {
                        choose(profile)
                    }
                }
                NewProfileTile(isSelected: creating) {
                    creating = true
                    unlocking = nil
                }
            }

            if let unlocking {
                panel {
                    Text("Enter \(unlocking.name)'s PIN").font(GRASPFont.rowTitle).foregroundColor(GRASPColor.textPrimary)
                    HStack(spacing: 8) {
                        SecureField("PIN", text: $pin).frame(width: 120.0).onSubmit { tryUnlock(unlocking) }
                        Button("Unlock") { tryUnlock(unlocking) }.disabled(pin.count != 4).fixedSize()
                        Button("Cancel") { self.unlocking = nil; pin = "" }.fixedSize()
                    }
                    if wrongPIN {
                        Text("Wrong PIN").font(GRASPFont.meta).foregroundColor(GRASPColor.rejected)
                    }
                }
            } else if creating {
                panel {
                    Text("New Profile").font(GRASPFont.rowTitle).foregroundColor(GRASPColor.textPrimary)
                    TextField("Name", text: $newName).frame(width: 260.0)
                    HStack(spacing: 8) {
                        SecureField("4-digit PIN (optional)", text: $newPIN).frame(width: 180.0)
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        Button("Create") {
                            let trimmed = newName.trimmingCharacters(in: .whitespaces)
                            create(Profile(name: trimmed, pinHash: newPIN.count == 4 ? ProfileStore.hashPIN(newPIN) : nil))
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                                  || !(newPIN.isEmpty || (newPIN.count == 4 && newPIN.allSatisfy(\.isNumber))))
                        .fixedSize()
                        Button("Cancel") { creating = false }.fixedSize()
                    }
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GRASPColor.canvas)
    }

    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(18)
            .background(GRASPColor.surface)
            .cornerRadius(10)
    }

    private func choose(_ profile: Profile) {
        creating = false
        if profile.pinHash == nil {
            open(profile)
        } else {
            unlocking = profile
            pin = ""
            wrongPIN = false
        }
    }

    private func tryUnlock(_ profile: Profile) {
        if ProfileStore.hashPIN(pin) == profile.pinHash {
            open(profile)
        } else {
            wrongPIN = true
            pin = ""
        }
    }
}

/// The Mac's avatar: the first initial in ink on a solid yellow circle.
struct Avatar: View {
    let name: String
    let size: Double

    var body: some View {
        Text(initial)
            .font(Font.system(size: size * 0.38, weight: .bold))
            .foregroundColor(GRASPColor.ink)
            .frame(width: size, height: size)
            .background(GRASPColor.brand)
            .cornerRadius(Int(size / 2))
    }

    private var initial: String {
        name.first.map { String($0).uppercased() } ?? "?"
    }
}

private struct ProfileTile: View {
    let name: String
    let locked: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Avatar(name: name, size: 68)
            Text(name + (locked ? " \u{1F512}" : ""))
                .font(Font.system(size: 15, weight: .medium))
                .foregroundColor(GRASPColor.textPrimary)
                .lineLimit(1)
        }
        .frame(width: 148.0, height: 148.0)
        .edged(fill: isSelected ? GRASPColor.surfaceRaised : GRASPColor.surface,
               edge: isSelected ? GRASPColor.hairlineStrong : GRASPColor.hairline, radius: GRASPRadius.card)
        .onTapGesture(perform: action)
    }
}

private struct NewProfileTile: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        // The Mac draws this one dashed; SwiftCrossUI strokes have no dash,
        // so it is the bare canvas with a strong hairline.
        VStack(spacing: 14) {
            Text("+")
                .font(Font.system(size: 30, weight: .light))
                .foregroundColor(GRASPColor.textSecondary)
                .frame(width: 68.0, height: 68.0)
            Text("New profile").font(Font.system(size: 15)).foregroundColor(GRASPColor.textSecondary)
        }
        .frame(width: 148.0, height: 148.0)
        .edged(fill: isSelected ? GRASPColor.surfaceRaised : GRASPColor.canvas,
               edge: GRASPColor.hairlineStrong, radius: GRASPRadius.card)
        .onTapGesture(perform: action)
    }
}
