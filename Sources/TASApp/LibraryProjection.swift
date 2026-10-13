#if os(macOS)
import Foundation
import TASCore

/// Structure is invalidated only by record changes, never by selection,
/// progress, language or folder expansion. Visible rows are a separate cache.
struct LibraryProjection {
    private var files: [StoredFile] = []
    private var roots: [LibraryNode] = []
    private var expanded: Set<String> = []
    private var expandAll = false
    private(set) var rows: [LibraryRow] = []
    private(set) var folderPaths: Set<String> = []
    private(set) var structureBuildCount = 0

    mutating func update(files: [StoredFile], expanded: Set<String>, expandAll: Bool) {
        let changed = structureBuildCount == 0 || self.files != files
        if changed {
            self.files = files
            roots = LibraryTree.build(files)
            folderPaths = Set(LibraryTree.visibleRows(roots, expanded: [], expandAll: true)
                .filter { $0.node.isFolder }.map { $0.node.path })
            structureBuildCount += 1
        }
        guard changed || self.expanded != expanded || self.expandAll != expandAll else { return }
        self.expanded = expanded
        self.expandAll = expandAll
        rows = LibraryTree.visibleRows(roots, expanded: expanded, expandAll: expandAll)
    }
}

/// Selection is keyed by persistent file IDs; folder rows never become batch targets.
enum LibrarySelection {
    static func resolve(_ ids: Set<String>, rows: [LibraryRow]) -> [StoredFile] {
        rows.compactMap { ids.contains($0.id) ? $0.node.file : nil }
    }

    static func downloadNames(_ files: [StoredFile]) -> [String] {
        let leaves = files.map { URL(fileURLWithPath: $0.filename).lastPathComponent }
        let duplicates = Dictionary(grouping: leaves, by: { $0.lowercased() })
        var reserved = Set(leaves.map { $0.lowercased() })
        return zip(files, leaves).map { file, leaf in
            guard duplicates[leaf.lowercased(), default: []].count > 1 else { return leaf }
            let name = NSString(string: leaf)
            let ext = name.pathExtension
            let suffix = ext.isEmpty ? "" : ".\(ext)"
            var candidate = "\(name.deletingPathExtension)-\(file.id)\(suffix)"
            var index = 2
            while reserved.contains(candidate.lowercased()) {
                candidate = "\(name.deletingPathExtension)-\(file.id)-\(index)\(suffix)"
                index += 1
            }
            reserved.insert(candidate.lowercased())
            return candidate
        }
    }
}
#endif
