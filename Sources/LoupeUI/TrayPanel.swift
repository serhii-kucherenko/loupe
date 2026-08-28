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
    /// One line rather than a panel. True while picking, so the page underneath
    /// stays reachable, and whenever there is nothing to show yet.
    var compact: Bool = false
    /// Rendered as a bottom sheet: full width, flush with the bottom edge. What
    /// `DESIGN.md` asks for on a phone, and the reason the panel is pushed down by
    /// its own corner radius - `UnevenRoundedRectangle` would say it better and is
    /// iOS 16.4, above the floor this package promises.
    var sheet: Bool = false
    /// The home indicator's height. A sheet flush with the edge has to keep it clear
    /// itself, since nothing outside is padding it any more.
    var safeBottom: CGFloat = 0
    var onClose: () -> Void

    @FocusState private var sendFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 340

    var body: some View {
        // A full-height panel saying "0 notes" and offering to send them would also
        // be competing with the popover for attention while someone types into it.
        if compact || model.annotations.isEmpty {
            // The one-line bar stays a floating pill even on a phone: it is a status
            // line, not a surface, and a full-width sheet saying "0 notes" would be
            // covering the app for no reason.
            bar.padding(.bottom, sheet ? safeBottom + LoupeTheme.Radius.panel : 0)
        } else {
            full
        }
    }

    private var bar: some View {
        HStack(spacing: LoupeTheme.Space.sm) {
            Text(barTitle)
                .font(LoupeTheme.Typography.body)
                .foregroundStyle(LoupeTheme.Colors.inkSoft.color)
            Spacer()
            if !model.annotations.isEmpty, model.mode == .picking(hover: nil) || model.mode == .browsing {
                Button("Review") { model.review() }
                    .buttonStyle(LoupeButtonStyle(kind: .quiet))
            }
            closeButton
        }
        .padding(.horizontal, LoupeTheme.Space.md)
        .padding(.vertical, LoupeTheme.Space.sm)
        .frame(width: Self.width)
        .loupePanel()
    }

    private var barTitle: String {
        switch model.annotations.count {
        case 0: return "Point at something that looks wrong."
        case 1: return "1 note · point at another"
        case let n: return "\(n) notes · point at another"
        }
    }

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

    private var header: some View {
        HStack(spacing: LoupeTheme.Space.sm) {
            Text(model.annotations.count == 1 ? "1 note" : "\(model.annotations.count) notes")
                .font(LoupeTheme.Typography.label)
                .foregroundStyle(LoupeTheme.Colors.ink.color)
            Spacer()
            Button("Pick another") { model.resumePicking() }
                .buttonStyle(LoupeButtonStyle(kind: .quiet))
                .disabled(model.mode != .browsing)
            closeButton
        }
        .padding(LoupeTheme.Space.md)
    }

    private var closeButton: some View {
        Button {
            onClose()
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(LoupeButtonStyle(kind: .quiet))
        .accessibilityLabel("Leave annotate mode")
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
