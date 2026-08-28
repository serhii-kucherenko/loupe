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
    /// Where the controls are right now, mid-drag. Reset on release, when the corner
    /// takes over - so nothing has to be persisted in points.
    @State private var dragOffset: CGSize = .zero

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
        GeometryReader { geometry in
            ZStack {
                chrome.opacity(model.mode.isVisible ? 1 : 0)

                // Outside the opacity gate on purpose: in `.off` the overlay draws
                // nothing, and the way in has to still be there.
                //
                // Not while a panel is open. It sits outside `chrome`, so it would
                // draw on top of the panel's own scrim - which put three primary
                // buttons on one screen with nothing to say which was the live one.
                // A modal owns the screen and carries its own way out.
                if model.panel == nil {
                    if model.mode == .off {
                        if showsControl {
                            enterControl
                                .frame(maxWidth: .infinity, maxHeight: .infinity,
                                       alignment: .bottomTrailing)
                                .padding(LoupeTheme.Space.lg)
                                .padding(.bottom, safeArea.bottom)
                                .padding(.trailing, safeArea.trailing)
                        }
                    } else {
                        pull(in: geometry.size)
                    }
                }
            }
        }
    }

    private var showsControl: Bool {
        #if canImport(UIKit)
        return true
        #else
        // On a Mac the way in is the hotkey. The pull still appears once annotate
        // mode is open, because a mode you cannot see your way out of is worse than
        // one more thing on screen.
        return true
        #endif
    }

    /// The way in, and nothing else. One pill over somebody's app at rest.
    private var enterControl: some View {
        Button { model.toggleAnnotating() } label: {
            Label("Annotate", systemImage: "scope")
        }
        .buttonStyle(LoupeButtonStyle(kind: .primary))
        .loupePanel()
        .accessibilityLabel("Start annotating")
        // Small, and the only way in - so it must never be one of the touches the
        // overlay passes through. See `InteractiveRegions.swift`.
        .loupeInteractive()
    }

    /// The drawer's pull: the only thing Loupe leaves on the app while annotating.
    ///
    /// Asked for in these words: "ideally, you make it a sliding panel, when it only
    /// leaves a handler I click on and the side panel with appear / also that handler
    /// should be draggeble as sometimes I might need to move it as it might be
    /// blocking element I need to annotate".
    ///
    /// Two gestures on one object, and neither needs a long press. Dragging **along**
    /// the edge slides the pull clear of whatever is under it. Dragging **away** from
    /// the edge opens the drawer, which is the gesture the shape already suggests. A
    /// tap does the same as the second, for anyone who tries neither.
    @ViewBuilder
    private func pull(in size: CGSize) -> some View {
        let height = size.height
        Button { model.toggleTray() } label: {
            VStack(spacing: LoupeTheme.Space.xs) {
                // Says "drag me", which nothing else here did: "handler doesn't look
                // like draggable btw". Horizontal bars on a pull that travels
                // vertically - the grip runs across the direction of travel, the way
                // every sheet grabber does.
                Image(systemName: "line.3.horizontal")
                    .font(LoupeTheme.Typography.note)
                    .foregroundStyle(LoupeTheme.Colors.inkSoft.color)
                Image(systemName: model.trayExpanded ? "chevron.right" : "chevron.left")
                Text("\(model.annotations.count)")
                    .font(LoupeTheme.Typography.label)
                    .monospacedDigit()
            }
            .padding(.vertical, LoupeTheme.Space.sm)
        }
        .buttonStyle(LoupeButtonStyle(kind: .secondary))
        .loupePanel()
        .accessibilityLabel(pullAccessibilityLabel)
        .accessibilityHint("Slides the notes panel in and out. Drag it up or down to "
                           + "move it off whatever is underneath.")
        .loupeInteractive()
        .position(x: pullX(in: size), y: pullY(in: size))
        // High priority, not a plain `.gesture`. The pull is a `Button`, and a
        // button's own tap recogniser will otherwise win a race it should lose: a
        // quick flick was swallowed roughly half the time, which is exactly the
        // gesture someone makes when they want the thing out of the way *now*.
        // Below the minimum distance nothing here fires at all, so the tap still
        // works.
        .highPriorityGesture(
            // Has to travel before it counts, or a tap on the pull would be read as
            // the beginning of a move.
            DragGesture(minimumDistance: LoupeTheme.Space.md)
                .onChanged { dragOffset = $0.translation }
                .onEnded { value in
                    dragOffset = .zero
                    // Away from the trailing edge means open. It is the direction the
                    // drawer would travel, so it is the one the pull should answer to.
                    if value.translation.width < -openThreshold,
                       abs(value.translation.width) > abs(value.translation.height) {
                        model.setTrayExpanded(true)
                    } else if value.translation.width > openThreshold,
                              abs(value.translation.width) > abs(value.translation.height) {
                        model.setTrayExpanded(false)
                    } else {
                        model.moveHandle(toFraction: DrawerHandle.fraction(
                            forY: model.handle.centreY(in: height) + value.translation.height,
                            in: height))
                    }
                }
        )
        .animation(LoupeTheme.Motion.resolved(LoupeTheme.Motion.panel,
                                              reduceMotion: reduceMotion),
                   value: model.handle)
        .animation(LoupeTheme.Motion.resolved(LoupeTheme.Motion.panel,
                                              reduceMotion: reduceMotion),
                   value: model.trayExpanded)
    }

    /// Where the pull sits horizontally: against the screen's edge when the drawer is
    /// shut, and against the drawer's own edge when it is open.
    ///
    /// Travelling with the drawer is what makes it a pull rather than a button that
    /// happens to show a panel. Left where it was, it floated in the middle of the
    /// screen with the drawer somewhere behind it, attached to nothing.
    ///
    /// A phone is the exception: the tray is a bottom sheet there, so the trailing
    /// edge stays free and the pull does not move.
    private func pullX(in size: CGSize) -> CGFloat {
        let half = LoupeTheme.Hit.touch / 2
        let shut = size.width - safeArea.trailing - LoupeTheme.Space.sm - half
        guard model.trayExpanded, !isCompact else { return shut }
        let drawerLeading = size.width - safeArea.trailing - LoupeTheme.Space.lg - TrayPanel.width
        return drawerLeading - half - LoupeTheme.Space.xs
    }

    /// Where the pull sits vertically: wherever it was put, except that on a phone
    /// the drawer is a bottom sheet, and the pull has to stay above it rather than
    /// straddling its top corner.
    private func pullY(in size: CGSize) -> CGFloat {
        let wanted = model.handle.centreY(in: size.height) + dragOffset.height
        guard model.trayExpanded, isCompact else { return wanted }
        let sheetTop = size.height - sheetHeight(in: size)
        return min(wanted, sheetTop - LoupeTheme.Hit.touch / 2 - LoupeTheme.Space.sm)
    }

    /// Half the screen, which is what the sheet gets in `trayPanel`.
    private func sheetHeight(in size: CGSize) -> CGFloat { size.height * 0.5 }

    /// Far enough that a wobble while sliding the pull up the edge is not read as
    /// "open", and near enough that a deliberate flick is.
    private var openThreshold: CGFloat { LoupeTheme.Hit.touch }

    private var pullAccessibilityLabel: String {
        let notes = model.annotations.count == 1 ? "1 note" : "\(model.annotations.count) notes"
        return model.trayExpanded ? "Hide notes, \(notes)" : "Show notes, \(notes)"
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
        // Only when it has been asked for, and then in any annotating mode.
        //
        // It used to render itself in `.browsing` and nowhere else, which meant it
        // appeared the instant a note was saved and could not be reached before
        // that. Both halves were wrong: the layout changed under someone's hands at
        // the moment they were least expecting it, and the tray was unreachable for
        // the whole of a first session.
        //
        // It still must not be in the way when nobody asked for it - once it
        // registers an interactive region it *takes* every touch that lands on it,
        // so anything underneath becomes unpickable. That is the difference between
        // this and the one-line bar that used to sit here: this one is opened.
        if model.trayExpanded, model.mode != .off {
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
                panel.frame(maxHeight: sheetHeight(in: size))
            }
            // Pushed down by one corner radius so the sheet's lower corners fall off
            // the screen and it reads as hugging the edge rather than floating.
            .padding(.bottom, -LoupeTheme.Radius.panel)
            .transition(.move(edge: .bottom))
        } else {
            // The full height of the trailing edge, because it is a drawer and the
            // pull rides on its leading edge. A panel sized to its contents left the
            // pull attached to nothing whenever the two disagreed about where that
            // edge was, which was most of the time.
            HStack {
                Spacer()
                panel.frame(maxHeight: .infinity)
            }
            .padding(LoupeTheme.Space.lg)
            .padding(.top, insets.top)
            .padding(.bottom, insets.bottom)
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
