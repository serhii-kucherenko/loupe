#if os(macOS)
import SwiftUI
import LoupeCore

/// The other half of the loop: what an agent actually receives.
///
/// It reads the same folder `FileTransport` writes, with the same types, decoding
/// from disk rather than from memory. If the on-disk shape were wrong, this screen
/// would be the first thing to show it.
struct AgentInbox: View {
    @State private var bundles: [LoadedBundle] = []
    @State private var selected: LoadedBundle.ID?

    private var directory: URL { FileTransport.defaultDirectory(appName: "LoupeDemo") }

    var body: some View {
        HSplitView {
            list
            detail
        }
        .task { reload() }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Received").font(.title2).bold()
                Spacer()
                Button("Reload", action: reload)
            }

            if bundles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nothing received yet.")
                    Text("Annotate something and press Send.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            List(bundles, selection: $selected) { bundle in
                VStack(alignment: .leading, spacing: 2) {
                    Text(bundle.value.sentAt.formatted(date: .abbreviated, time: .shortened))
                    Text("\(bundle.value.annotations.count) notes · \(bundle.value.app.platform)"
                         + (bundle.value.app.commitSHA.map { " · \($0)" } ?? ""))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .tag(bundle.id)
            }
        }
        .padding(16)
        .frame(minWidth: 280)
    }

    @ViewBuilder
    private var detail: some View {
        if let bundle = bundles.first(where: { $0.id == selected }) ?? bundles.first {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(bundle.folder.lastPathComponent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    ForEach(Array(bundle.value.annotations.enumerated()), id: \.element.id) { index, annotation in
                        AnnotationCard(index: index + 1, annotation: annotation, folder: bundle.folder)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Select a bundle").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        bundles = folders.compactMap { folder -> LoadedBundle? in
            let file = folder.appendingPathComponent("bundle.json")
            guard let data = try? Data(contentsOf: file),
                  let value = try? decoder.decode(AnnotationBundle.self, from: data)
            else { return nil }
            return LoadedBundle(folder: folder, value: value)
        }
        .sorted { $0.value.sentAt > $1.value.sentAt }
    }
}

struct LoadedBundle: Identifiable {
    let folder: URL
    let value: AnnotationBundle
    var id: String { folder.lastPathComponent }
}

/// One annotation, laid out the way an agent would want to read it: what was said,
/// what it was said about, and what the app was doing at the time.
struct AnnotationCard: View {
    let index: Int
    let annotation: Annotation
    let folder: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(index)").font(.caption.monospaced().bold())
                Text(annotation.comment).font(.body)
                Spacer()
                if let tag = annotation.tag {
                    Text(tag.rawValue).font(.caption).foregroundStyle(.secondary)
                }
            }

            // On disk the PNG sits beside the JSON, named by annotation id.
            if let image = NSImage(contentsOf: folder.appendingPathComponent("\(annotation.id.uuidString).png")) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 420, maxHeight: 200, alignment: .leading)
                    .border(Color.secondary.opacity(0.3))
            }

            field("element", elementSummary)
            if let screen = annotation.screen { field("screen", screen) }

            if !annotation.trace.isEmpty {
                field("trace", annotation.trace.map {
                    "\($0.method) \(URL(string: $0.url)?.path ?? $0.url)"
                    + ($0.statusCode.map { c in " → \(c)" } ?? "")
                    + " (\($0.durationMs)ms)"
                }.joined(separator: "\n"))
            }

            if !annotation.logs.isEmpty {
                field("logs", annotation.logs.map {
                    "[\($0.level.rawValue)] \($0.subsystem.map { s in "\(s): " } ?? "")\($0.message)"
                }.joined(separator: "\n"))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    private var elementSummary: String {
        [annotation.element.accessibilityID,
         annotation.element.selector,
         annotation.element.label,
         annotation.element.className]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func field(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(name)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
