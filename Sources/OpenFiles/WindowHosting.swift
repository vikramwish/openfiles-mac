import AppKit
import SwiftUI

/// The user owns the window size. Dynamic SwiftUI content must lay out inside it,
/// rather than increasing NSWindow's minimum/ideal size after every interaction.
@MainActor
enum WindowHosting {
    @discardableResult
    static func install<Content: View>(_ content: Content, in window: NSWindow) -> NSHostingView<Content> {
        let host = NSHostingView(rootView: content)
        host.sizingOptions = []
        host.frame = window.contentView?.bounds ?? NSRect(origin: .zero, size: window.contentLayoutRect.size)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        return host
    }
}
