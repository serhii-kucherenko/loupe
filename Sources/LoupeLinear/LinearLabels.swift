import Foundation
import LoupeCore

/// A label as Linear reports it, and the rule for choosing one for a tag.
///
/// **Loupe never creates a label.** A workspace's labels are somebody's taxonomy,
/// and filing a note from an iPad is not the moment to add to it. So a tag either
/// finds a label that already exists, or it is written into the issue body instead.
/// Never invented, and never silently dropped either - the person picked it.
struct LinearLabel: Equatable, Sendable {
    let id: String
    let name: String
    /// nil for a workspace-level label, which every team may use.
    let teamID: String?
}

extension LinearLabel {

    /// The label id to file with, or nil when this workspace has no label of that
    /// name.
    ///
    /// - Matching ignores case: "Bug" and "bug" are the same word to everybody
    ///   except a string comparison.
    /// - A label on this team beats a workspace-level one of the same name, because
    ///   the team's own is the more specific answer.
    /// - Another team's label never wins. It is not Loupe's to use, and Linear
    ///   would refuse the issue anyway.
    static func id(for tag: AnnotationTag,
                   in labels: [LinearLabel],
                   teamID: String) -> String? {
        let wanted = tag.rawValue.lowercased()
        let matching = labels.filter { $0.name.lowercased() == wanted }
        return matching.first { $0.teamID == teamID }?.id
            ?? matching.first { $0.teamID == nil }?.id
    }

    /// Reads the `issueLabels` connection.
    ///
    /// A node missing an id or a name is skipped rather than failing the send: the
    /// label is a nicety, the note is not.
    static func list(from data: [String: Any]) -> [LinearLabel] {
        let nodes = (data["issueLabels"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        return nodes.compactMap {
            guard let id = $0["id"] as? String, let name = $0["name"] as? String else {
                return nil
            }
            return LinearLabel(id: id, name: name,
                               teamID: ($0["team"] as? [String: Any])?["id"] as? String)
        }
    }
}
