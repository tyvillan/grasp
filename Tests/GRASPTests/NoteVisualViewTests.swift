import Testing
import SwiftUI
import GRASPCore
@testable import GRASP

@Suite("Note visual views")
struct NoteVisualViewTests {
    static let sample = """
    ## The Compilation Pipeline

    ```
    source (.cpp, plain text)
       → compiler checks syntax → object file
       → linker joins your objects + OS/library objects
       → executable / application
       → loaded and run
    ```

    ## Data Types Introduced

    | Type | Notes |
    | --- | --- |
    | `int` | whole numbers |
    | `double` | **twice the size of an int**; the class uses `double` rather than `float` |
    | `char` | **single** quotation marks, the character '1' is not the number 1 |
    | `string` | requires an include of string |

    ```cpp
    #include <iostream>   // needed in every program in this class
    #include <string>     // needed whenever you use the string class
    using namespace std;

    int main()
    {
        int numPies, numSlices, totalSlices;
        int count = 6;
        return 0;         // 0 means it ran correctly
    }
    ```
    """

    /// The real Module 1 note when it is there, else the sample above.
    private func note() -> String {
        let real = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/grasp-fixtures/cpp-intro-lecture.md")
        return (try? String(contentsOf: real, encoding: .utf8)) ?? Self.sample
    }

    /// Renders every visual to PNG at a Mac and a phone width, light and dark.
    /// Files go to `GRASP_FIGURE_DIR`, else the temp folder.
    @MainActor @Test("every kind of note visual renders at a Mac and a phone width")
    func renders() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GRASP_FIGURE_DIR"] ?? NSTemporaryDirectory())
        let visuals = NoteVisuals.visuals(in: note())
        #expect(visuals.count >= 3)
        for (index, visual) in visuals.enumerated() {
            for width in [640.0, 340.0] {
                for scheme in [ColorScheme.light, .dark] {
                    let view = NoteVisualView(visual: visual)
                        .environment(\.colorScheme, scheme)
                        .frame(width: width)
                        .padding(20)
                        .background(GRASPColor.canvas)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    let image = try #require(renderer.cgImage)
                    #expect(image.width >= Int(width) * 2 && image.height > 80)
                    let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                    try data.write(to: dir.appendingPathComponent("visual\(index)-\(Int(width))-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
