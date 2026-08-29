#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Puts text on the system pasteboard.
///
/// It exists for one message: the reason a send failed. That text is written to be
/// pasted - into an agent, a bug report, a message to whoever owns the workspace -
/// and it can run to a few hundred characters of a server's own words. Reading it
/// off an iPad and retyping it is the kind of friction that ends with somebody
/// reporting "it said 400" and nothing else, which is exactly the failure the
/// message was added to end.
enum LoupeClipboard {

    /// - Returns: `false` when this platform has no pasteboard, so a caller can leave
    ///   the button out rather than draw one that does nothing.
    static var isAvailable: Bool {
        #if canImport(UIKit) || canImport(AppKit)
        return true
        #else
        return false
        #endif
    }

    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        #endif
    }
}
