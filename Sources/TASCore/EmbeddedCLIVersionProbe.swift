import Foundation
#if os(macOS)
import Darwin

/// Runs the bundled CLI off the main thread; output, time and child lifetime are bounded.
public enum EmbeddedCLIVersionProbe {
    public static func read(from path: URL, timeout: TimeInterval = 3) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path.path) else { return nil }
        let process = Process()
        process.executableURL = path
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let fd = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            var bytes: [UInt8] = []
            while Date() < deadline {
                var chunk = [UInt8](repeating: 0, count: 256)
                let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    guard bytes.count + count < 256 else {
                        kill(process.processIdentifier, SIGKILL)
                        process.waitUntilExit()
                        return nil
                    }
                    bytes.append(contentsOf: chunk.prefix(count))
                } else if count < 0 && errno != EAGAIN && errno != EINTR { break }
                if !process.isRunning {
                    // The direct child has exited; do not wait for a descendant to close stdout.
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else { return nil }
                    return String(bytes: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return nil
        } catch { return nil }
    }
}
#endif
