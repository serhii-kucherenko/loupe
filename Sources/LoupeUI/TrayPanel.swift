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
                                    onTag: { model.updateTag(id: annotation.id, tag: $0) })
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

            if case .failed(let why) = model.sendState {
                // The person reading this is a developer looking at their own staging
                // build. The real reason is more use to them than a soft sentence.
                Text(why)
                    .font(LoupeTheme.Typography.caption)
                    .foregroundStyle(LoupeTheme.Colors.highlight.color)
                    .accessibilityLabel("Send failed: \(why)")
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
            .disabled(model.annotations.isEmpty || model.sendState == .sending)
            .frame(maxWidth: .infinity)
        }
        .padding(LoupeTheme.Space.md)
    }

    private var sendTitle: String {
        switch model.sendState {
        case .sending: return "Sending"
        case .failed: return "Try again"
        case .sent(let n): return "Sent \(n)"
        case .idle: return model.annotations.count == 1 ? "Send 1 note" : "Send \(model.annotations.count) notes"
        }
    }
}

/// One annotation. The badge, the crop, what you said, and what the screen called.
struct TrayRow: View {
    let index: Int
    let annotation: Annotation
    var onRemove: () -> Void
    var onTag: (AnnotationTag?) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: LoupeTheme.Space.md) {
            BadgeView(number: index)

            VStack(alignment: .leading, spacing: LoupeTheme.Space.xs) {
                if let png = annotation.screenshotPNG, let image = Image(loupePNG: png) {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 96, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: LoupeTheme.Radius.highlight,
                                                    style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: LoupeTheme.Radius.highlight,
                                             style: .continuous)
                                .strokeBorder(LoupeTheme.Colors.line.color,
                                              lineWidth: LoupeTheme.Stroke.hairline)
                        )
                        .accessibilityHidden(true)
                }

                Text(annotation.comment)
                    .font(LoupeTheme.Typography.body)
                    .foregroundStyle(LoupeTheme.Colors.ink.color)
                    .fixedSize(horizontal: false, vertical: true)

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
