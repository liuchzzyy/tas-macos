#if os(macOS)
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
#endif
