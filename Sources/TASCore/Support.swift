import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct TASError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !value() { throw TASError(message) }
}
public typealias JSON = [String: Any]
func number(_ value: Any?) -> Int64 { (value as? NSNumber)?.int64Value ?? Int64(value as? String ?? "") ?? 0 }
func string(_ value: Any?) -> String { value as? String ?? (value as? NSNumber)?.stringValue ?? "" }
func jsonData(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]) }
func jsonObject(_ data: Data) throws -> JSON { guard let value = try JSONSerialization.jsonObject(with: data) as? JSON else { throw TASError("无效的 JSON 数据") }; return value }
func timestamp() -> String { ISO8601DateFormatter().string(from: Date()) }

public enum Paths {
    public static var dataDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["TAS_DATA_DIR"] { return URL(fileURLWithPath: override, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tas", isDirectory: true)
    }
    public static func logical(_ value: String) throws -> String {
        let parts = value.replacingOccurrences(of: "\\", with: "/").split(separator: "/");
        try require(!value.contains("\0") && !parts.isEmpty && !parts.contains(".") && !parts.contains(".."), "无效的文件逻辑路径")
        return parts.joined(separator: "/")
    }
    public static func contained(_ name: String, in root: URL) throws -> URL {
        let safe = try logical(name)
        try privateDirectory(root)
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        var destination = base
        for part in safe.split(separator: "/") {
            destination.appendPathComponent(String(part))
            if let values = try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true { throw TASError("恢复路径不能经过符号链接") }
        }
        try require(destination.path.hasPrefix(base.path + "/"), "文件路径越过目标目录")
        return destination
    }
    public static func privateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public static func privateFile(_ url: URL) throws -> FileHandle {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw TASError("无法创建文件：\(url.lastPathComponent)（\(String(cString: strerror(errno)))）") }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    public static func atomicWrite(_ data: Data, to destination: URL) throws {
        let parent = destination.deletingLastPathComponent()
        try privateDirectory(parent)
        let temporary = parent.appendingPathComponent(".tas-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let handle = try privateFile(temporary)
        try handle.write(contentsOf: data); try handle.synchronize(); try handle.close()
        try atomicReplace(temporary, destination)
    }
    public static func atomicReplace(_ temporary: URL, _ destination: URL) throws {
        guard rename(temporary.path, destination.path) == 0 else { throw TASError("无法保存文件：\(String(cString: strerror(errno)))") }
    }
    static func temporary(in directory: URL, prefix: String = ".tas-") throws -> URL {
        try privateDirectory(directory)
        return directory.appendingPathComponent("\(prefix)\(UUID().uuidString)")
    }
}

public final class VaultLock {
    private let url: URL
    private let nonce = UUID().uuidString
    public init(directory: URL) throws {
        try Paths.privateDirectory(directory)
        url = directory.appendingPathComponent("sync.lock")
        for _ in 0..<2 {
            do {
                let handle = try Paths.privateFile(url)
                try handle.write(contentsOf: jsonData(["pid": Int(getpid()), "nonce": nonce, "startedAt": timestamp()]))
                try handle.synchronize(); try handle.close(); return
            } catch {
                guard FileManager.default.fileExists(atPath: url.path) else { throw error }
                if let bytes = try? Data(contentsOf: url), let value = try? jsonObject(bytes), let pid = value["pid"] as? Int, pid > 0, pid <= Int(Int32.max) {
                    if kill(Int32(pid), 0) == 0 || errno == EPERM { throw TASError("文件库正被进程 \(pid) 使用，请先锁定或退出其他 TAS 客户端") }
                } else {
                    let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
                    if Date().timeIntervalSince(values.contentModificationDate ?? Date()) < 5 { throw TASError("另一个进程正在获取文件库锁，请稍后重试") }
                }
                try FileManager.default.removeItem(at: url)
            }
        }
        throw TASError("无法获取文件库锁")
    }
    deinit {
        if let data = try? Data(contentsOf: url), let raw = try? jsonObject(data), raw["nonce"] as? String == nonce { try? FileManager.default.removeItem(at: url) }
    }
}
