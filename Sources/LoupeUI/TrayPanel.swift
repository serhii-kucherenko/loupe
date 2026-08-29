import SwiftUI
import LoupeCore

extension Image {
    /// The crop, as a SwiftUI image. Returns nil rather than a placeholder: a row
    /// with no thumbnail is honest, a grey box pretending to be one is not.
    init?(loupePNG data: Data) {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        self.init(uiImage: image)
        #elseif canImport(AppKit)
        guard let image = NSImage(data: data) else { return nil }
        self.init(nsImage: image)
        #else
        return nil
        #endif
    }
}

/// Everything picked so far, and the one button that ships it.
///
/// The tray hugs one edge and never covers the centre of the screen, because the
/// centre is where the app being annotated lives.
struct TrayPanel: View {
    @ObservedObject var model: OverlayModel
    /// Rendered as a bottom sheet: full width, flush with the bottom edge. What
    /// `DESIGN.md` asks for on a phone, and the reason the panel is pushed down by
    /// its own corner radius - `UnevenRoundedRectangle` would say it better and is
    /// iOS 16.4, above the floor this package promises.
    var sheet: Bool = false
    /// The home indicator's height. A sheet flush with the edge has to keep it clear
    /// itself, since nothing outside is padding it any more.
    var safeBottom: CGFloat = 0

    @FocusState private var sendFocused: Bool

    /// Whether the failure reason is shown in full. It is capped at four lines
    /// otherwise, because a server's answer can be long enough to push the Send
    /// button off a drawer that does not scroll.
    @State private var showsWholeReason = false
    /// Whether the reason is on the pasteboard. Shown rather than announced, because
    /// a copy that looks like it did nothing gets pressed again.
    @State private var copiedReason = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 340

    // One shape now. The one-line bar it used to fall back to is gone: it only ever
    // rendered while picking or commenting, and nothing draws a tray in those modes
    // any more, because a bar that takes touches makes whatever is under it
    // unpickable.
    var body: some View { full }

    private var full: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(LoupeTheme.Colors.line.color)

            Group {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.annotations.enumerated()), id: \.element.id) { index, annotation in
                            TrayRow(index: index + 1,
                                    annotation: annotation,
                                    onRemove: { model.remove(id: annotation.id) },
                                    onTag: { model.updateTag(id: annotation.id, tag: $0) },
                                    onEdit: { model.updateComment(id: annotation.id, comment: $0) },
                                    onPreview: { model.present(AnyView(CropPreview(png: $0) {
                                        model.dismissPanel()
                                    })) })
                            if annotation.id != model.annotations.last?.id {
                                Divider().overlay(LoupeTheme.Colors.line.color)
                            }
                        }
                    }
                }
            }

            Divider().overlay(LoupeTheme.Colors.line.color)
            footer
        }
        .padding(.bottom, sheet ? safeBottom + LoupeTheme.Radius.panel : 0)
        .frame(maxWidth: sheet ? .infinity : Self.width)
        .loupePanel()
        .animation(LoupeTheme.Motion.resolved(LoupeTheme.Motion.commit,
                                              reduceMotion: reduceMotion),
                   value: model.annotations.count)
    }

    /// Everything that is not the pull lives in here.
    ///
    /// The drawer is the single home for Loupe's chrome. There used to be three
    /// answers to "where does it live" - a pill in one corner, an xmark on the tray
    /// in another, a gear inside the tray - and two occlusion bugs came out of
    /// that. Now one object stands on the app, and it moves.
    private var header: some View {
        HStack(spacing: LoupeTheme.Space.sm) {
            Text(model.annotations.count == 1 ? "1 note" : "\(model.annotations.count) notes")
                .font(LoupeTheme.Typography.label)
                .foregroundStyle(LoupeTheme.Colors.ink.color)
            Spacer()

            if let onSettings = model.onSettings {
                Button(action: onSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(LoupeButtonStyle(kind: .quiet))
                    .accessibilityLabel("Where notes are sent")
            }

            // Secondary, not primary. Send is the important button in this panel and
            // two primaries in one panel means neither reads as the thing to press.
            Button {
                model.endAnnotating()
            } label: {
                Label("Done", systemImage: "checkmark")
            }
            .buttonStyle(LoupeButtonStyle(kind: .secondary))
            .accessibilityLabel(exitLabel)
        }
        .padding(LoupeTheme.Space.md)
    }

    private var exitLabel: String {
        switch model.annotations.count {
        case 0: return "Finish annotating"
        case 1: return "Finish annotating, 1 note"
        case let n: return "Finish annotating, \(n) notes"
        }
    }


    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: LoupeTheme.Space.sm) {
            if model.pendingCount > 0 {
                Button {
                    Task { await model.drainPending() }
                } label: {
                    Label(model.pendingCount == 1
                          ? "1 bundle waiting to send"
                          : "\(model.pendingCount) bundles waiting to send",
                          systemImage: "arrow.clockwise")
                }
                .buttonStyle(LoupeButtonStyle(kind: .quiet))
            }

            if case .failed(let why, let canRetry) = model.sendState {
                // The person reading this is a developer looking at their own staging
                // build. The real reason is more use to them than a soft sentence.
                //
                // Bounded, because it can now be a server's own words rather than a
                // sentence Loupe wrote - a few hundred characters of JSON in a drawer
                // this narrow pushes the Send button off the bottom, and there is
                // nothing to scroll. Tap to see the rest.
                Text(why)
                    .font(LoupeTheme.Typography.note)
                    .foregroundStyle(LoupeTheme.Colors.highlight.color)
                    .lineLimit(showsWholeReason ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { showsWholeReason.toggle() }
                    .accessibilityLabel("Send failed: \(why)")
                    .accessibilityHint(showsWholeReason ? "Shows less" : "Shows the whole reason")

                HStack(spacing: LoupeTheme.Space.sm) {
                    // A failure nothing can retry needs a way to fix it, not a button
                    // that cannot work. Almost every one of these is "Linear is not
                    // set up yet", and the panel is where that is set up.
                    if !canRetry, let onSettings = model.onSettings {
                        Button(action: onSettings) {
                            Label("Open Linear settings", systemImage: "gearshape")
                        }
                        .buttonStyle(LoupeButtonStyle(kind: .secondary))
                    }

                    // This message exists to be pasted - into an agent, an issue, a
                    // message to whoever owns the workspace. Retyping a server's
                    // answer off an iPad is how it turns back into "it said 400".
                    if LoupeClipboard.isAvailable {
                        Button {
                            LoupeClipboard.copy(why)
                            copiedReason = true
                        } label: {
                            Label(copiedReason ? "Copied" : "Copy reason",
                                  systemImage: copiedReason ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(LoupeButtonStyle(kind: .quiet))
                    }
                }
                // Both bits of state belong to this reason and not to the next one.
                // A "Copied" tick still showing over a different failure says the
                // wrong thing about what is on the pasteboard.
                .onChange(of: why) { _ in
                    copiedReason = false
                    showsWholeReason = false
                }
            }

            Button("Pick another") { model.resumePicking() }
                .buttonStyle(LoupeButtonStyle(kind: .quiet))
                .disabled(model.mode != .browsing)

            Button {
                Task { await model.send() }
            } label: {
                HStack(spacing: LoupeTheme.Space.sm) {
                    if model.sendState == .sending {
                        ProgressView().controlSize(.small)
                    }
                    Text(sendTitle)
                    Spacer()
                }
            }
            .buttonStyle(LoupeButtonStyle(kind: .primary, isFocused: sendFocused))
            .focused($sendFocused)
            .disabled(model.annotations.isEmpty || model.sendState == .sending || !canSend)
            .frame(maxWidth: .infinity)
        }
        .padding(LoupeTheme.Space.md)
    }

    /// A failure nothing can retry leaves the button off, so the only thing on screen
    /// worth doing is reading the message and fixing what it names.
    private var canSend: Bool {
        if case .failed(_, let canRetry) = model.sendState { return canRetry }
        return true
    }

    private var sendTitle: String {
        switch model.sendState {
        case .sending: return "Sending"
        // "Try again" only when trying again could work. A rejected credential will
        // be rejected again, and a button that cannot succeed teaches somebody it is
        // a lie. The message above it already says what to do instead.
        case .failed(_, let canRetry): return canRetry ? "Try again" : "Send failed"
        case .sent(let n): return "Sent \(n)"
        case .idle: return model.annotations.count == 1 ? "Send 1 note" : "Send \(model.annotations.count) notes"
        }
    }
}

/// One annotation. The badge, the crop, what you said, and what the screen called.
///
/// A drawer full of notes is a list you scan, not a gallery. The crop used to be a
/// 96pt-tall picture across the full width, so three notes filled the panel and
/// finding the fourth meant scrolling past pictures you had already recognised. It
/// is a thumbnail beside the text now, and tapping it opens the whole thing.
struct TrayRow: View {
    let index: Int
    let annotation: Annotation
    var onRemove: () -> Void
    var onTag: (AnnotationTag?) -> Void
    /// Editing the words is the one thing you could not do without deleting the note
    /// and picking the element again. The model could always do it; nothing offered it.
    var onEdit: (String) -> Void = { _ in }
    /// Shows the crop full size, since a thumbnail is for recognising rather than
    /// reading.
    var onPreview: (Data) -> Void = { _ in }

    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var editing: Bool

    /// Square, and the size of a touch target rather than a picture. Big enough to
    /// tell one note from another at a glance, which is all a thumbnail owes anybody.
    private var thumbnailSize: CGFloat { LoupeTheme.Hit.touch }

    var body: some View {
        HStack(alignment: .top, spacing: LoupeTheme.Space.md) {
            BadgeView(number: index)

            if let png = annotation.screenshotPNG, let image = Image(loupePNG: png) {
                Button { onPreview(png) } label: {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: thumbnailSize, height: thumbnailSize)
                        .clipShape(RoundedRectangle(cornerRadius: LoupeTheme.Radius.highlight,
                                                    style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: LoupeTheme.Radius.highlight,
                                             style: .continuous)
                                .strokeBorder(LoupeTheme.Colors.line.color,
                                              lineWidth: LoupeTheme.Stroke.hairline)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show the picture for note \(index)")
            }

            VStack(alignment: .leading, spacing: LoupeTheme.Space.xs) {
                comment

                if let detail = annotation.element.accessibilityID
                    ?? annotation.element.selector
                    ?? annotation.element.className {
                    Text(detail)
                        .font(LoupeTheme.Typography.caption)
                        .foregroundStyle(LoupeTheme.Colors.inkSoft.color)
                        .lineLimit(1)
                }

                // The endpoints are the point of the whole tool: they are what ties
                // this element to backend code.
                ForEach(endpoints, id: \.self) { endpoint in
                    Text(endpoint)
                        .font(LoupeTheme.Typography.caption)
                        .foregroundStyle(LoupeTheme.Colors.inkSoft.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let errors = errorSummary {
                    Text(errors)
                        .font(LoupeTheme.Typography.caption)
                        .foregroundStyle(LoupeTheme.Colors.highlight.color)
                        .lineLimit(1)
                }

                if let tag = annotation.tag {
                    Text(tag.rawValue)
                        .font(LoupeTheme.Typography.caption)
                        .foregroundStyle(LoupeTheme.color(for: tag).color)
                }
            }

            Button {
                onRemove()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(LoupeButtonStyle(kind: .quiet))
            .accessibilityLabel("Remove annotation \(index)")
        }
        .padding(LoupeTheme.Space.md)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// At most three, newest first. A wall of polling requests helps nobody.
    /// What you said, in two lines, until you tap it.
    ///
    /// Two rather than all of them because the list is for finding a note, and a
    /// paragraph pushes the next one off the screen. Tapping opens the whole thing to
    /// edit, which is also how you read past the second line.
    @ViewBuilder
    private var comment: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: LoupeTheme.Space.xs) {
                TextField("What is wrong", text: $draft, axis: .vertical)
                    .font(LoupeTheme.Typography.body)
                    .foregroundStyle(LoupeTheme.Colors.ink.color)
                    .textFieldStyle(.plain)
                    .focused($editing)
                    .padding(LoupeTheme.Space.sm)
                    .background(
                        RoundedRectangle(cornerRadius: LoupeTheme.Radius.control,
                                         style: .continuous)
                            .strokeBorder(LoupeTheme.Colors.line.color,
                                          lineWidth: LoupeTheme.Stroke.hairline))
                    .accessibilityLabel("Edit note \(index)")

                HStack(spacing: LoupeTheme.Space.sm) {
                    Button("Cancel") { isEditing = false }
                        .buttonStyle(LoupeButtonStyle(kind: .quiet))
                    Button("Save") { commit() }
                        .buttonStyle(LoupeButtonStyle(kind: .secondary))
                        // An empty note is a note nobody can act on. Deleting is what
                        // the bin is for, and doing it silently through an edit is not
                        // the same thing.
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        } else {
            Button {
                draft = annotation.comment
                isEditing = true
                editing = true
            } label: {
                Text(annotation.comment)
                    .font(LoupeTheme.Typography.body)
                    .foregroundStyle(LoupeTheme.Colors.ink.color)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Note \(index): \(annotation.comment)")
            .accessibilityHint("Opens it for editing")
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onEdit(trimmed)
        isEditing = false
    }

    private var endpoints: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for event in annotation.trace.reversed() {
            let path = URL(string: event.url)?.path ?? event.url
            let line = "\(event.method) \(path)\(event.statusCode.map { " \($0)" } ?? "")"
            if seen.insert(line).inserted { result.append(line) }
            if result.count == 3 { break }
        }
        return result
    }

    private var errorSummary: String? {
        let errors = annotation.logs.filter { $0.level == .error }
        guard let first = errors.first else { return nil }
        return errors.count == 1 ? first.message : "\(first.message) (+\(errors.count - 1) more)"
    }
}

/// The crop, big enough to read.
///
/// The thumbnail in the row is for telling one note from another; this is for
/// looking at what was actually captured. It reuses the overlay's own panel slot, so
/// it arrives over the scrim with everything else dimmed and a tap outside closes it.
struct CropPreview: View {
    let png: Data
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: LoupeTheme.Space.md) {
            HStack {
                Text("What was captured")
                    .font(LoupeTheme.Typography.label)
                    .foregroundStyle(LoupeTheme.Colors.ink.color)
                Spacer()
                Button("Close", action: onClose)
                    .buttonStyle(LoupeButtonStyle(kind: .quiet))
            }

            if let image = Image(loupePNG: png) {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    // Bounded, because a context shot of a whole iPad screen would
                    // otherwise fill the display and lose the panel around it.
                    .frame(maxWidth: 520, maxHeight: 520)
                    .clipShape(RoundedRectangle(cornerRadius: LoupeTheme.Radius.highlight,
                                                style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: LoupeTheme.Radius.highlight,
                                         style: .continuous)
                            .strokeBorder(LoupeTheme.Colors.line.color,
                                          lineWidth: LoupeTheme.Stroke.hairline))
                    .accessibilityLabel("The captured element")
            } else {
                Text("That picture could not be read.")
                    .font(LoupeTheme.Typography.note)
                    .foregroundStyle(LoupeTheme.Colors.inkSoft.color)
            }
        }
        .padding(LoupeTheme.Space.md)
        .fixedSize()
        .loupePanel()
    }
}
