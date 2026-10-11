import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct UploadCandidate: Sendable, Equatable {
    public let url: URL
    public let name: String

    public init(url: URL, name: String) {
        self.url = url
        self.name = name
    }
}

public enum UploadPlan {
    /// Synchronous preflight; call off the main actor before uploading anything.
    /// Recursive selection skips hidden entries. Explicitly selected hidden files
    /// are included. Empty folders produce no candidates (no directory records).
    /// Fails the entire plan on invalid, unreadable or conflicting sources. This
    /// checks readability, not a snapshot: continue to use Vault.upload with its
    /// source validation and replace=false; files may change after collection.
    public static func collect(_ urls: [URL]) throws -> [UploadCandidate] {
        try Task.checkCancellation()
        var candidates: [UploadCandidate] = []
        func visit(_ url: URL, name: String) throws {
            try Task.checkCancellation()
            try require(try Paths.logical(name) == name,
                        "文件名不能无损转换为逻辑路径：\(name)。请先重命名。")
            try require(url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost"),
                        "只能上传本地文件或文件夹：\(url.absoluteString)")
            try rejectSymlinkedAncestors(of: url)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            try require(values.isSymbolicLink != true, "不能上传符号链接：\(url.path)")
            try require(values.isDirectory == true || values.isRegularFile == true,
                        "请选择普通文件或文件夹：\(url.path)")
            if values.isDirectory == true {
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                          options: [.skipsHiddenFiles]) {
                    try visit(url.appendingPathComponent(child.lastPathComponent), name: name + "/" + child.lastPathComponent)
                }
            } else {
                // Like the core upload boundary, require a regular, non-symlink
                // source. Open without following a final symlink; O_NONBLOCK
                // prevents a concurrently substituted FIFO from hanging preflight.
                let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard descriptor >= 0 else {
                    throw TASError("无法读取文件：\(url.path)（\(String(cString: strerror(errno)))）")
                }
                defer { close(descriptor) }
                var status = stat()
                try require(fstat(descriptor, &status) == 0 && (status.st_mode & S_IFMT) == S_IFREG,
                            "请选择普通文件：\(url.path)")
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                _ = try handle.read(upToCount: 1)
                candidates.append(UploadCandidate(url: url, name: name))
            }
        }
        for url in urls { try visit(url, name: url.lastPathComponent) }
        var sourcesByName: [String: String] = [:]
        return try candidates.sorted { lhs, rhs in
            let order = lhs.name.compare(rhs.name, options: [.numeric, .caseInsensitive],
                                         locale: Locale(identifier: "en_US_POSIX"))
            if order != .orderedSame { return order == .orderedAscending }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.url.absoluteString < rhs.url.absoluteString
        }.filter { candidate in
            try Task.checkCancellation()
            let source = candidate.url.resolvingSymlinksInPath().standardizedFileURL.path
            if let previous = sourcesByName[candidate.name] {
                try require(previous == source,
                            "上传目标重名“\(candidate.name)”：\(previous) 与 \(source)。请分别选择或重命名；未开始上传。")
                return false
            }
            sourcesByName[candidate.name] = source
            return true
        }
    }

    private static func rejectSymlinkedAncestors(of url: URL) throws {
        var parent = url.deletingLastPathComponent()
        while parent.path != "/" && !parent.path.isEmpty {
            try Task.checkCancellation()
            let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                // macOS exposes these OS-owned aliases in ordinary file URLs
                // (including FileManager.temporaryDirectory). No user links.
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: parent.path)
                let systemAlias = ["/var": "private/var", "/tmp": "private/tmp", "/etc": "private/etc"]
                guard let expected = systemAlias[parent.path],
                      destination == expected || destination == "/" + expected else {
                    throw TASError("上传路径不能经过符号链接：\(parent.path)")
                }
            }
            parent.deleteLastPathComponent()
        }
    }
}
