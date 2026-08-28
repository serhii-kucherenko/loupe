import SwiftUI
import LoupeCore

/// Where the comment popover sits relative to the element it is about.
///
/// `DESIGN.md`: it attaches to the picked element and flips side rather than
/// covering it. Covering the element is the one thing it must never do, because the
/// person is in the middle of describing what they can see.
enum PopoverPlacement {
    static let gap = LoupeTheme.Space.md

    static func frame(for element: CGRect,
                      popover size: CGSize,
                      in container: CGSize) -> CGRect {
        let below = element.maxY + gap
        let above = element.minY - gap - size.height

        // Prefer below, flip above when there is no room. If neither side fits,
        // take whichever has more space and let it clamp: half-visible beats
        // sitting on top of the thing being annotated.
        let y: CGFloat
        if below + size.height <= container.height {
            y = below
        } else if above >= 0 {
            y = above
        } else {
            y = (container.height - element.maxY) > element.minY ? below : max(0, above)
        }

        let x = min(max(0, element.midX - size.width / 2), max(0, container.width - size.width))
        return CGRect(x: x, y: min(max(0, y), max(0, container.height - size.height)),
                      width: size.width, height: size.height)
    }
}

/// Type what is wrong, tag it, save. Nothing else.
///
/// The overlay must never make someone wait to leave a note, so this panel has one
/// field, four chips and two buttons, and the field is focused the moment it opens.
struct CommentPopover: View {
    let pick: PendingPick
    var onSave: (String, AnnotationTag?) -> Void
    var onCancel: () -> Void

    @State private var comment = ""
    @State private var tag: AnnotationTag?
    @FocusState private var fieldFocused: Bool
    @FocusState private var chipFocused: AnnotationTag?
    @FocusState private var saveFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 320

    private var canSave: Bool {
        !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LoupeTheme.Space.md) {
            header

            TextField("What is wrong with this?", text: $comment, axis: .vertical)
                .textFieldStyle(.plain)
                .font(LoupeTheme.Typography.body)
                .foregroundStyle(LoupeTheme.Colors.ink.color)
                .lineLimit(2...6)
                .focused($fieldFocused)
                .padding(LoupeTheme.Space.sm)
                .background(
                    RoundedRectangle(cornerRadius: LoupeTheme.Radius.control, style: .continuous)
                        .strokeBorder(LoupeTheme.Colors.line.color,
                                      lineWidth: LoupeTheme.Stroke.hairline)
                )
                .loupeFocusRing(fieldFocused)
                .onSubmit { if canSave { onSave(comment, tag) } }

            TagChips(selection: $tag, focused: $chipFocused)

            HStack(spacing: LoupeTheme.Space.sm) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(LoupeButtonStyle(kind: .quiet))
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") { onSave(comment, tag) }
                    .buttonStyle(LoupeButtonStyle(kind: .primary, isFocused: saveFocused))
                    .focused($saveFocused)
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(LoupeTheme.Space.lg)
        .frame(width: Self.width)
        .loupePanel()
        .transition(.opacity)
        .onAppear { fieldFocused = true }
        .accessibilityLabel("Comment on \(pick.ref.label ?? pick.ref.className ?? "the picked element")")
    }

    private var header: some View {
        HStack(spacing: LoupeTheme.Space.sm) {
            BadgeView(number: pick.index)
            VStack(alignment: .leading, spacing: 0) {
                Text(pick.ref.label ?? pick.ref.accessibilityID ?? "Element")
                    .font(LoupeTheme.Typography.label)
                    .foregroundStyle(LoupeTheme.Colors.ink.color)
                    .lineLimit(1)
                if let detail = pick.ref.accessibilityID ?? pick.ref.className {
                    Text(detail)
                        .font(LoupeTheme.Typography.caption)
                        .foregroundStyle(LoupeTheme.Colors.inkSoft.color)
                        .lineLimit(1)
                }
            }
        }
    }
}
