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

    /// Bound to the model, not local state: an outside tap has to be able to decide
    /// what to do with what has been typed, and a view cannot be asked.
    @Binding var comment: String
    @Binding var tag: AnnotationTag?
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
        // `.contain`, not a bare label: a label on the container is pushed down onto
        // every child, so the field, the four tag chips, Cancel and Save all reported
        // the same sentence and VoiceOver could not tell Save from Cancel.
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Comment on \(pick.ref.label ?? pick.ref.className ?? fallbackName)")
    }

    /// A region is not an element and must not be labelled as one. Calling a
    /// rectangle somebody drew "Element / nil" is the panel disagreeing with what
    /// they just did.
    private var title: String {
        switch pick.ref.kind {
        case .region: return "Region"
        case .view: return pick.ref.label ?? pick.ref.accessibilityID ?? "Element"
        }
    }

    private var subtitle: String? {
        switch pick.ref.kind {
        case .region:
            return "\(Int(pick.ref.bounds.width))×\(Int(pick.ref.bounds.height))"
        case .view:
            return pick.ref.accessibilityID ?? pick.ref.className
        }
    }

    private var fallbackName: String {
        pick.ref.kind == .region ? "the area you drew" : "the picked element"
    }

    private var header: some View {
        HStack(spacing: LoupeTheme.Space.sm) {
            BadgeView(number: pick.index)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(LoupeTheme.Typography.label)
                    .foregroundStyle(LoupeTheme.Colors.ink.color)
                    .lineLimit(1)
                if let detail = subtitle {
                    Text(detail)
                        .font(LoupeTheme.Typography.caption)
                        .foregroundStyle(LoupeTheme.Colors.inkSoft.color)
                        .lineLimit(1)
                }
            }
        }
    }
}
