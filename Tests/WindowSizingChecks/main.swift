import AppKit
import SwiftUI

@MainActor
private final class Scenario: ObservableObject {
    @Published var expanded = false
}

private struct GrowingContent: View {
    @ObservedObject var scenario: Scenario
    var body: some View {
        VStack {
            Text("Window sizing regression fixture")
            if scenario.expanded {
                // Simulates expanded details, large previews, and long search results.
                Text(String(repeating: "Long details that must not resize the window.\n", count: 300))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: 1400, minHeight: 4000)
            } else {
                Text("Collapsed").frame(minWidth: 200, minHeight: 100)
            }
        }
    }
}

@main
@MainActor
struct WindowSizingChecks {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let scenario = Scenario()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 980, height: 680),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 480)
        let host = WindowHosting.install(GrowingContent(scenario: scenario), in: window)
        let control = CommandLine.arguments.contains("--automatic-sizing-control")
        if control { host.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize] }
        func settle() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        settle()
        let initial = window.frame
        let initialMinimum = window.minSize
        for iteration in 0..<8 {
            scenario.expanded = iteration.isMultiple(of: 2)
            settle()
            guard window.frame == initial, window.minSize == initialMinimum else {
                if control {
                    window.close()
                    print("PASS Automatic content sizing reproduces the window-growth bug")
                    return
                }
                fputs("FAIL: content changes resized the window or increased its minimum size\n", stderr)
                exit(1)
            }
        }
        if control {
            fputs("FAIL: the automatic-sizing control did not reproduce window growth\n", stderr)
            exit(1)
        }
        // The fix must still allow explicit user resizing and resize the hosted content.
        window.setContentSize(NSSize(width: 1100, height: 740))
        settle()
        guard host.frame.size == window.contentView!.bounds.size,
              abs(host.frame.width - 1100) < 1, abs(host.frame.height - 740) < 1 else {
            fputs("FAIL: hosted content did not follow an explicit window resize\n", stderr)
            exit(1)
        }
        window.close()
        print("PASS Window frame and minimum size remain stable across eight content changes")
        print("PASS Hosted content follows explicit window resizing")
    }
}
