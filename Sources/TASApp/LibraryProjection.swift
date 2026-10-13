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

/// Selection is keyed by persistent file IDs. File rows resolve to the stored
/// file they represent; a folder row stands for every stored file below its
/// logical path, so collapsed and filtered-out rows still resolve.
enum LibrarySelection {
    /// Resolves only the file rows that are currently visible; folder rows are
    /// ignored. Kept for callers that must never widen a selection.
    static func resolve(_ ids: Set<String>, rows: [LibraryRow]) -> [StoredFile] {
        rows.compactMap { ids.contains($0.id) ? $0.node.file : nil }
    }

    /// Resolves selected rows, including every descendant of selected folders.
    /// Pass the complete file set (not search-filtered or collapsed rows) so
    /// operations apply to the entire folder.
    static func resolve(_ ids: Set<String>, rows: [LibraryRow], allFiles: [StoredFile]) -> [StoredFile] {
        _ = rows
        return targets(ids, allFiles: allFiles)
    }

    /// Target files for a selection: directly selected files plus the subtree of
    /// every selected folder. Order and identity follow `allFiles`; a file that
    /// is selected both directly and through a folder appears exactly once.
    static func targets(_ ids: Set<String>, allFiles: [StoredFile]) -> [StoredFile] {
        let selected = fileIDs(in: ids)
        let folders = folderPaths(in: ids)
        guard !selected.isEmpty || !folders.isEmpty else { return [] }
        return allFiles.filter { file in
            selected.contains(file.id) || folders.contains { file.filename.hasPrefix($0 + "/") }
        }
    }

    static func fileIDs(in ids: Set<String>) -> Set<Int64> {
        Set(ids.filter { $0.hasPrefix("file:") }.compactMap { Int64($0.dropFirst("file:".count)) })
    }

    /// Folder rows are identified by their logical path, never by a record ID.
    static func folderPaths(in ids: Set<String>) -> [String] {
        ids.filter { $0.hasPrefix("folder:") }.map { String($0.dropFirst("folder:".count)) }.sorted()
    }

    /// Writes a hierarchy-preserving destination for every file, refusing paths
    /// that would escape the chosen directory.
    static func hierarchicalDestinations(_ files: [StoredFile], in root: URL) throws -> [URL] {
        try files.map { try Paths.contained($0.filename, in: root) }
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
