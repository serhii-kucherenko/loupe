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

    /// The host window's own safe area.
    ///
    /// Not `geometry.safeAreaInsets`: the overlay deliberately ignores the safe area
    /// so its coordinates match the window the picker measures in, and a view that
    /// ignores the safe area is reported as having none. Reading it there gave a
    /// bottom sheet that sat 15pt under the home indicator. Whoever owns the window
    /// knows the real numbers, so they are passed in.
    var safeArea: EdgeInsets = EdgeInsets()

    /// How much of the bottom of the window the keyboard is covering.
    ///
    /// The popover places itself below the element when there is room. "Room" was
    /// measured against the whole window, which does not know its bottom 400pt is
    /// unusable - so picking anything low on an iPad put Cancel and Save under the
    /// keyboard, with no way to commit the note at all. Return does not help: the
    /// field is `axis: .vertical`, so Return inserts a newline.
    var keyboardInset: CGFloat = 0

    public init(model: OverlayModel,
                safeArea: EdgeInsets = EdgeInsets(),
                keyboardInset: CGFloat = 0) {
        self.model = model
        self.safeArea = safeArea
        self.keyboardInset = keyboardInset
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            chrome.opacity(model.mode.isVisible ? 1 : 0)

            // Outside the opacity gate on purpose: in `.off` the overlay draws
            // nothing, and the way in has to still be there.
            //
            // On a Mac the way in is the hotkey, so the control appears only once
            // annotate mode is open - but it does appear, because the tray's xmark
            // is gone and a mode you cannot see your way out of is worse than the
            // duplicate control was.
            //
            // Not while a panel is open. It sits outside `chrome`, so it would draw
            // on top of the panel's own scrim - which put three primary buttons on
            // one screen with nothing to say which was the live one. A modal owns
            // the screen, and it carries its own way out.
            if showsControl, model.panel == nil {
                controls
                    .padding(LoupeTheme.Space.lg)
                    .padding(.bottom, safeArea.bottom)
                    .padding(.trailing, safeArea.trailing)
            }
        }
    }

    private var showsControl: Bool {
        #if canImport(UIKit)
        return true
        #else
        return model.mode != .off
        #endif
    }

    private var chrome: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if model.mode.swallowsInput {
                    // Dimming only while picking. In browsing the app underneath has
                    // to look and behave exactly as it normally does.
                    LoupeTheme.Colors.scrim.color
                        .ignoresSafeArea()
                        // Dimming, never a target: the tap belongs to whatever the
                        // person is pointing at underneath it.
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                highlight

                if case .commenting(let pick) = model.mode {
                    let element = rect(pick.ref.bounds)
                    let frame = PopoverPlacement.frame(
                        for: element,
                        popover: CGSize(width: CommentPopover.width, height: 260),
                        in: CGSize(width: geometry.size.width,
                                   height: geometry.size.height - keyboardInset))

                    CommentPopover(
                        pick: pick,
                        onSave: { model.saveComment($0, tag: $1) },
                        onCancel: { model.cancelComment() },
                        comment: $model.draftComment,
                        tag: $model.draftTag)
                    .frame(width: frame.width, alignment: .topLeading)
                    .position(x: frame.midX, y: frame.minY + frame.height / 2)
                    // So a click outside it can be told from a click on it, on
                    // every platform. See `InteractiveRegions.swift`.
                    .loupeInteractive()
                }

                tray(in: geometry.size, insets: safeArea)

                if let panel = model.panel {
                    // Over everything, centred, with the scrim under it: a panel
                    // asking for a credential is the only thing that matters while
                    // it is open.
                    //
                    // The heavier of the two scrims. The picking scrim is 8%, which
                    // is right when the app underneath is what you are reading, and
                    // far too light to make a modal read as a modal.
                    LoupeTheme.Colors.scrimModal.color
                        .ignoresSafeArea()
                        .onTapGesture { model.dismissPanel() }
                    panel
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .loupeInteractive()
                }
            }
            .animation(LoupeTheme.Motion.resolved(LoupeTheme.Motion.panel,
                                                  reduceMotion: reduceMotion),
                       value: model.mode)
        }
    }

    /// The overlay's own corner: settings, and the way in and out.
    ///
    /// The gear used to live in the tray. The tray only exists in `.browsing`, and
    /// the only way into `.browsing` is to save a note - so on a fresh install the
    /// step that configures where notes are sent sat behind the step that sends
    /// them, and there was no way to reach it at all. Reported by someone who could
    /// not find it: "annotate sidepanel isn't visible when I enter annotate mode,
    /// also unclear how to make it visible".
    ///
    /// Not in `.off`: the resting state over somebody's app is one pill, and nobody
    /// needs to configure delivery before they have decided to annotate anything.
    @ViewBuilder
    private var controls: some View {
        HStack(spacing: LoupeTheme.Space.sm) {
            if let onSettings = model.onSettings, model.mode != .off {
                Button(action: onSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(LoupeButtonStyle(kind: .secondary))
                    .loupePanel()
                    .accessibilityLabel("Where notes are sent")
                    .loupeInteractive()
            }
            enterExitControl
        }
    }

    /// One control, in one place, that means "annotate mode" both ways.
    ///
    /// It used to be two objects in two corners: a pill bottom-trailing to get in,
    /// an xmark on the tray top-trailing to get out. Nothing said the second was the
    /// way out of the first, and the pill vanished the moment you were in. Someone
    /// who found their way in can now leave by looking where they came from.
    @ViewBuilder
    private var enterExitControl: some View {
        let isOff = model.mode == .off
        Button {
            model.toggleAnnotating()
        } label: {
            Label(isOff ? "Annotate" : exitTitle, systemImage: isOff ? "scope" : "checkmark")
        }
        .buttonStyle(LoupeButtonStyle(kind: .primary))
        .loupePanel()
        .accessibilityLabel(isOff ? "Start annotating" : exitAccessibilityLabel)
        // Small, and the only way out - so it must never be one of the touches the
        // overlay passes through. See `InteractiveRegions.swift`.
        .loupeInteractive()
    }

    private var exitTitle: String {
        model.annotations.isEmpty ? "Done" : "Done · \(model.annotations.count)"
    }

    private var exitAccessibilityLabel: String {
        switch model.annotations.count {
        case 0: return "Finish annotating"
        case 1: return "Finish annotating, 1 note"
        case let n: return "Finish annotating, \(n) notes"
        }
    }

    @ViewBuilder
    private var highlight: some View {
        // A shape being drawn is drawn, whatever mode is underneath it. It used to
        // live inside the `.picking` branch, so a drag begun while a comment was
        // open showed nothing until release.
        if let dragged = model.dragRegion {
            DragRegionLayer(rect: rect(dragged))
        }

        switch model.mode {
        case .picking(let hovered):
            if model.dragRegion == nil, let hovered {
                HighlightLayer(rect: rect(hovered.bounds),
                               badge: model.annotations.count + 1,
                               isPinned: false)
            }
        case .commenting(let pick):
            // The pinned pick stays visible while a new shape is drawn over it, so
            // the previous note does not simply vanish mid-gesture.
            HighlightLayer(rect: rect(pick.ref.bounds), badge: pick.index, isPinned: true)
                .opacity(model.dragRegion == nil ? 1 : 0.35)
        case .off, .browsing:
            EmptyView()
        }
    }

    @ViewBuilder
    private func tray(in size: CGSize, insets: EdgeInsets) -> some View {
        // No tray at all while picking or commenting. The one-line bar that used to
        // sit here was not merely visually in the way: once it registered an
        // interactive region it *took* every touch that landed on it, so anything
        // underneath became unpickable - the exact thing this file's own comment
        // said must never happen. Reported by someone who could not annotate the
        // trailing edge of his own app.
        if case .browsing = model.mode {
            trayPanel(in: size, insets: insets)
        }
    }

    @ViewBuilder
    private func trayPanel(in size: CGSize, insets: EdgeInsets) -> some View {
        let panel = TrayPanel(model: model,
                              sheet: isCompact,
                              safeBottom: insets.bottom)
            .loupeInteractive()

        if isCompact {
            VStack(spacing: 0) {
                Spacer()
                panel.frame(maxHeight: size.height * 0.5)
            }
            // Pushed down by one corner radius so the sheet's lower corners fall off
            // the screen and it reads as hugging the edge rather than floating.
            .padding(.bottom, -LoupeTheme.Radius.panel)
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
            .padding(.top, insets.top)
            .padding(.trailing, insets.trailing)
            .transition(.move(edge: .trailing))
        }
    }

    /// `ElementRef.bounds` is top-left origin in viewport points on every platform,
    /// which is the same space this view draws in. See `docs/bundle-format.md`.
    private func rect(_ bounds: Rect) -> CGRect {
        CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
    }
}
