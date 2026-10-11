import Foundation

public struct LibraryNode: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let file: StoredFile?
    public let children: [LibraryNode]
    public var isFolder: Bool { file == nil }
}

public struct LibraryRow: Identifiable, Hashable, Sendable {
    public let node: LibraryNode
    public let depth: Int
    public var id: String { node.id }
}

public enum LibraryTree {
    /// Preorder rows, with expansion keyed by folder `path`, not node ID.
    /// Use `expandAll` with a tree built from search results to reveal matches.
    public static func visibleRows(_ roots: [LibraryNode], expanded: Set<String>,
                                   expandAll: Bool = false) -> [LibraryRow] {
        var rows: [LibraryRow] = []
        func visit(_ nodes: [LibraryNode], depth: Int) {
            for node in nodes {
                rows.append(LibraryRow(node: node, depth: depth))
                if node.isFolder && (expandAll || expanded.contains(node.path)) {
                    visit(node.children, depth: depth + 1)
                }
            }
        }
        visit(roots, depth: 0)
        return rows
    }

    /// Builds a view of the supplied records; deleted records are not filtered.
    /// Only `/` separates folders. Stored logical paths are never normalized.
    public static func build(_ files: [StoredFile]) -> [LibraryNode] {
        let root = Branch()
        for file in files {
            let parts = file.filename.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            var branch = root
            for part in parts.dropLast() {
                if branch.folders[part] == nil { branch.folders[part] = Branch() }
                branch = branch.folders[part]!
            }
            branch.files.append(LibraryNode(id: "file:\(file.id)", name: parts.last ?? file.filename,
                                            path: file.filename, file: file, children: []))
        }
        return root.nodes(prefix: [])
    }

    private final class Branch {
        var folders: [String: Branch] = [:]
        var files: [LibraryNode] = []

        func nodes(prefix: [String]) -> [LibraryNode] {
            (folders.map { name, branch in
                let parts = prefix + [name]
                let path = parts.joined(separator: "/")
                return LibraryNode(id: "folder:\(path)", name: name, path: path,
                                   file: nil, children: branch.nodes(prefix: parts))
            } + files).sorted { lhs, rhs in
                if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
                let order = lhs.name.compare(rhs.name, options: [.numeric, .caseInsensitive],
                                             locale: Locale(identifier: "en_US_POSIX"))
                if order != .orderedSame { return order == .orderedAscending }
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                if let left = lhs.file, let right = rhs.file { return left.id < right.id }
                return lhs.id < rhs.id
            }
        }
    }
}
