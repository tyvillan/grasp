import Foundation
import Testing
@testable import GRASPCore

@Suite("ICloudPath")
struct ICloudPathTests {
    @Test("an Obsidian vault note drops the app container's Documents folder")
    func obsidianContainer() {
        let path = "/Users/tyler/Library/Mobile Documents/iCloud~md~obsidian/Documents/Master Vault/College/Fall 2026/Econ/Lecture 1.md"
        #expect(ICloudPath.componentsInICloudDrive(macPath: path)
                == ["iCloud~md~obsidian", "Master Vault", "College", "Fall 2026", "Econ", "Lecture 1.md"])
    }

    @Test("an iCloud Drive file sits at the drive's root")
    func cloudDocs() {
        let path = "/Users/tyler/Library/Mobile Documents/com~apple~CloudDocs/Notes/a.md"
        #expect(ICloudPath.componentsInICloudDrive(macPath: path) == ["Notes", "a.md"])
    }

    @Test("Desktop and Documents map to their iCloud folders")
    func desktopAndDocuments() {
        #expect(ICloudPath.componentsInICloudDrive(macPath: "/Users/tyler/Desktop/guide.pdf") == ["Desktop", "guide.pdf"])
        #expect(ICloudPath.componentsInICloudDrive(macPath: "/Users/tyler/Documents/x/y.md") == ["Documents", "x", "y.md"])
    }

    @Test("paths outside iCloud, Windows paths and relative paths are nil")
    func notICloud() {
        #expect(ICloudPath.componentsInICloudDrive(macPath: "/Users/tyler/Downloads/a.pdf") == nil)
        #expect(ICloudPath.componentsInICloudDrive(macPath: "/tmp/a.md") == nil)
        #expect(ICloudPath.componentsInICloudDrive(macPath: #"C:\Users\Tyler\notes\a.md"#) == nil)
        #expect(ICloudPath.componentsInICloudDrive(macPath: "College/a.md") == nil)
        #expect(ICloudPath.componentsInICloudDrive(macPath: "/Users/tyler/Library/Mobile Documents/com~apple~CloudDocs") == nil)
    }
}
