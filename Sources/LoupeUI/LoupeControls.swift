import SwiftUI
import LoupeCore

/// The overlay's buttons, in one place, with all eight states each.
///
/// Every control here is a tool sitting on top of someone else's product, so it
/// carries its own surface and never borrows the host app's button styling.
/// Public because anything built on top of Loupe - the Linear settings sheet, or a
/// host's own panel - has to look like Loupe rather than reinventing the tokens.
public struct LoupeButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case primary, secondary, quiet }

    public var kind: Kind = .secondary
    public var isFocused: Bool = false

    public init(kind: Kind = .secondary, isFocused: Bool = false) {
        self.kind = kind
        self.isFocused = isFocused
    }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(LoupeTheme.Typography.label)
            .foregroundStyle(foreground)
            .padding(.horizontal, LoupeTheme.Space.md)
            .frame(minHeight: minHeight)
            .background(
                RoundedRectangle(cornerRadius: LoupeTheme.Radius.control, style: .continuous)
                    .fill(background(pressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: LoupeTheme.Radius.control, style: .continuous)
                    .strokeBorder(LoupeTheme.Colors.line.color,
                                  lineWidth: kind == .secondary ? LoupeTheme.Stroke.hairline : 0)
            )
            .loupeFocusRing(isFocused)
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(LoupeTheme.Motion.resolved(LoupeTheme.Motion.hover,
                                                  reduceMotion: reduceMotion),
                       value: configuration.isPressed)
            .onHover { isHovering = $0 }
            .contentShape(Rectangle())
    }

    /// 44pt where a finger might land, 28 where only a pointer will.
    private var minHeight: CGFloat {
        #if canImport(UIKit)
        LoupeTheme.Hit.touch
        #else
        LoupeTheme.Hit.pointer
        #endif
    }

    private var foreground: Color {
        switch kind {
        case .primary: return LoupeTheme.Colors.surface.color
        case .secondary: return LoupeTheme.Colors.ink.color
        case .quiet: return LoupeTheme.Colors.inkSoft.color
        }
    }

    private func background(pressed: Bool) -> Color {
        let emphasis = pressed ? 0.82 : (isHovering ? 0.92 : 1)
        switch kind {
        case .primary: return LoupeTheme.Colors.action.color.opacity(emphasis)
        case .secondary: return LoupeTheme.Colors.surface.color.opacity(isHovering ? 1 : 0.6)
        case .quiet: return .clear
        }
    }
}

/// The four tags from `DESIGN.md`, as chips. They reuse the palette rather than
/// adding colours, so a tag never competes with the highlight for attention.
struct TagChips: View {
    @Binding var selection: AnnotationTag?
    @FocusState.Binding var focused: AnnotationTag?

    var body: some View {
        HStack(spacing: LoupeTheme.Space.sm) {
            ForEach(AnnotationTag.allCases, id: \.self) { tag in
                let isOn = selection == tag
                Button {
                    // Tapping the selected chip clears it: a tag is a hint, and you
                    // must be able to say "I do not know which of these it is".
                    selection = isOn ? nil : tag
                } label: {
                    Text(tag.rawValue)
                        .font(LoupeTheme.Typography.caption)
                        .foregroundStyle(isOn
                                         ? LoupeTheme.Colors.surface.color
                                         : LoupeTheme.color(for: tag).color)
                        .padding(.horizontal, LoupeTheme.Space.sm)
                        .frame(minHeight: chipHeight)
                        .background(
                            RoundedRectangle(cornerRadius: LoupeTheme.Radius.control,
                                             style: .continuous)
                                .fill(isOn ? LoupeTheme.color(for: tag).color : .clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: LoupeTheme.Radius.control,
                                             style: .continuous)
                                .strokeBorder(LoupeTheme.color(for: tag).color,
                                              lineWidth: LoupeTheme.Stroke.hairline)
                        )
                }
                .buttonStyle(.plain)
                .focused($focused, equals: tag)
                .loupeFocusRing(focused == tag)
                .accessibilityLabel("Tag as \(tag.rawValue)")
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
            }
        }
    }

    private var chipHeight: CGFloat {
        #if canImport(UIKit)
        LoupeTheme.Hit.touch
        #else
        LoupeTheme.Hit.pointer
        #endif
    }
}
