import Foundation
import GRASPCore
#if os(Windows)
import WinSDK
#endif

/// Keeps a signed-in session between launches, in the profile's folder.
///
/// On Windows it's encrypted with DPAPI (`CryptProtectData`), which ties it
/// to the Windows user account: another user on the PC, or the file copied
/// elsewhere, can't read it -- the same promise the Mac's Keychain makes.
/// On a Mac this app only runs for development, and stores it as plain JSON.
nonisolated enum SessionVault {
    static func load(from url: URL) -> SupabaseSession? {
        guard let stored = try? Data(contentsOf: url), let plain = unprotect(stored) else { return nil }
        return try? JSONDecoder().decode(SupabaseSession.self, from: plain)
    }

    static func save(_ session: SupabaseSession?, to url: URL) {
        guard let session else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let plain = try? JSONEncoder().encode(session), let stored = protect(plain) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? stored.write(to: url)
    }

    #if os(Windows)
    private static func protect(_ data: Data) -> Data? {
        transform(data) { input, output in CryptProtectData(input, nil, nil, nil, nil, 0, output) }
    }

    private static func unprotect(_ data: Data) -> Data? {
        transform(data) { input, output in CryptUnprotectData(input, nil, nil, nil, nil, 0, output) }
    }

    private static func transform(
        _ data: Data,
        // Swift's WinSDK import hands these back as Bool, not WindowsBool.
        _ call: (UnsafeMutablePointer<DATA_BLOB>, UnsafeMutablePointer<DATA_BLOB>) -> Bool
    ) -> Data? {
        var bytes = [UInt8](data)
        return bytes.withUnsafeMutableBufferPointer { buffer -> Data? in
            var input = DATA_BLOB(cbData: DWORD(buffer.count), pbData: buffer.baseAddress)
            var output = DATA_BLOB()
            guard call(&input, &output) else { return nil }
            defer { LocalFree(output.pbData) }
            return Data(bytes: output.pbData, count: Int(output.cbData))
        }
    }
    #else
    private static func protect(_ data: Data) -> Data? { data }
    private static func unprotect(_ data: Data) -> Data? { data }
    #endif
}
