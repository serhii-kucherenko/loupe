import SwiftUI
import LoupeCore

/// Everything the overlay draws, over any host app, on any Apple platform.
///
/// The layout rule from `DESIGN.md`: the tray hugs one edge and never covers the
/// centre of the screen. On a phone that edge is the bottom; everywhere else it is
/// the side.
public struct OverlayRoot: View {
    @ObservedObject var model: OverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    #if canImport(UIKit)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }
    #else
    private var isCompact: Bool { false }
    #endif

    public init(model: OverlayModel) {
        self.model = model
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if model.mode.swallowsInput {
                    // Dimming only while picking. In browsing the app underneath has
                    // to look and behave exactly as it normally does.
                    LoupeTheme.Colors.scrim.color
                        .ignoresSafeArea()
                        .accessibilityHidden(true)
                }

                highlight

                if case .commenting(let pick) = model.mode {
                    let element = rect(pick.ref.bounds)
                    let frame = PopoverPlacement.frame(
                        for: element,
                        popover: CGSize(width: CommentPopover.width, height: 260),
                        in: geometry.size)

                    CommentPopover(
                        pick: pick,
                        onSave: { model.saveComment($0, tag: $1) },
                        onCancel: { model.cancelComment() })
                    .frame(width: frame.width, alignment: .topLeading)
                    .position(x: frame.midX, y: frame.minY + frame.height / 2)
                }

                tray(in: geometry.size)
            }
            .animation(LoupeTheme.Motion.resolved(LoupeTheme.Motion.panel,
                                                  reduceMotion: reduceMotion),
                       value: model.mode)
        }
        .opacity(model.mode.isVisible ? 1 : 0)
    }

    @ViewBuilder
    private var highlight: some View {
        switch model.mode {
        case .picking(let hovered):
            if let hovered {
                HighlightLayer(rect: rect(hovered.bounds),
                               badge: model.annotations.count + 1,
                               isPinned: false)
            }
        case .commenting(let pick):
            HighlightLayer(rect: rect(pick.ref.bounds), badge: pick.index, isPinned: true)
        case .off, .browsing:
            EmptyView()
        }
    }

    @ViewBuilder
    private func tray(in size: CGSize) -> some View {
        // The full tray belongs to browsing. While you are picking it would cover
        // part of the app, and anything under it could not be pointed at - which is
        // the one thing this tool must never take away.
        let panel = TrayPanel(model: model,
                              compact: model.mode != .browsing,
                              onClose: { model.endAnnotating() })

        if isCompact {
            VStack {
                Spacer()
                panel
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: size.height * 0.5)
            }
            .padding(LoupeTheme.Space.md)
            .transition(.move(edge: .bottom))
        } else {
            // Top of the trailing edge, not the middle of it. The tray grows
            // downward as notes land, and a panel that floats in the vertical
            // centre reads as a dialog rather than as a docked tool.
            HStack(alignment: .top) {
                Spacer()
                panel.frame(maxHeight: size.height - LoupeTheme.Space.xxl)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(LoupeTheme.Space.lg)
            .transition(.move(edge: .trailing))
        }
    }

    /// `ElementRef.bounds` is top-left origin in viewport points on every platform,
    /// which is the same space this view draws in. See `docs/bundle-format.md`.
    private func rect(_ bounds: Rect) -> CGRect {
        CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
    }
}
