import DefaultBackend
import Foundation
import SwiftCrossUI

// A diagnostic, not part of GRASP: shows one kind of control, chosen by
// the PROBE environment variable, so `grasp.cmd uia-probe` can walk each
// window with UI Automation and find which control crashes XAML's
// automation tree (and with it, screen readers like Narrator).

@main
struct UIAProbeApp: App {
    var body: some Scene {
        WindowGroup("UIA probe: \(probe)") {
            ProbeView()
                .padding(20)
        }
        .defaultSize(width: 500, height: 360)
    }
}

let probe = ProcessInfo.processInfo.environment["PROBE"] ?? "text"

struct Bar: Shape {
    func path(in bounds: Path.Rect) -> Path {
        Path().move(to: SIMD2(bounds.x, bounds.y)).addLine(to: SIMD2(bounds.maxX, bounds.maxY))
    }
}

struct ProbeView: View {
    @State var selection: String?
    @State var text = ""
    @State var on = false

    var body: some View {
        switch probe {
        case "text":
            Text("Hello")
        case "vstack":
            VStack(alignment: .leading, spacing: 8) {
                Text("One")
                HStack { Text("Two"); Text("Three") }
            }
        case "button":
            Button("Press") {}
        case "disabled-button":
            Button("Press") {}.disabled(true)
        case "list":
            List(["a", "b", "c"], id: \.self, selection: $selection) { item in
                Text(item)
            }
        case "split":
            NavigationSplitView {
                Text("Sidebar")
            } detail: {
                Text("Detail")
            }
        case "scroll":
            ScrollView {
                VStack { ForEach(Array(0..<30), id: \.self) { Text("Row \($0)") } }
            }
        case "shape":
            Bar().stroke(.gray, style: StrokeStyle(width: 2)).frame(width: 80.0, height: 80.0)
        case "rectangle":
            Rectangle().fill(.gray).frame(width: 80.0, height: 20.0)
        case "background":
            Text("Card").padding(12).background(Color.gray.opacity(0.2)).cornerRadius(8)
        case "divider":
            VStack { Text("Above"); Divider(); Text("Below") }
        case "textfield":
            TextField("Type", text: $text)
        case "toggle":
            Toggle("Switch", isOn: $on)
        case "spinner":
            ProgressView("Loading…")
        default:
            Text("Unknown probe \(probe)")
        }
    }
}
