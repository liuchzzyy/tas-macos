import XCTest
import Darwin
@testable import TASCore

final class VaultLockSafetyTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tas-lock-test-\(UUID().uuidString)")
        try Paths.privateDirectory(url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testRealProcessesContendAndRelease() throws {
        let root = try directory()
        var children: [Process] = []
        for index in 0..<6 {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["-XCTest", "TASCoreTests.VaultLockSafetyTests/testLockChild", Bundle(for: VaultLockSafetyTests.self).bundlePath]
            var env = ProcessInfo.processInfo.environment.filter { ["PATH", "HOME", "TMPDIR", "DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH"].contains($0.key) }
            env["TAS_LOCK_CHILD_DIR"] = root.path
            env["TAS_LOCK_CHILD_ID"] = String(index)
            child.environment = env
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            children.append(child)
        }
        for child in children { child.waitUntilExit(); XCTAssertEqual(child.terminationStatus, 0) }
        for index in 0..<6 {
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("done-\(index)"), encoding: .utf8), "12")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("overlap").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("sync.lock").path))
        let kernel = root.appendingPathComponent("sync.kernel.lock")
        let before = try FileManager.default.attributesOfItem(atPath: kernel.path)[.systemFileNumber] as? NSNumber
        var lock: VaultLock? = try VaultLock(directory: root)
        XCTAssertNotNil(lock)
        lock = nil
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: kernel.path)[.systemFileNumber] as? NSNumber, before)
    }

    func testLockChild() throws {
        guard let path = ProcessInfo.processInfo.environment["TAS_LOCK_CHILD_DIR"],
              let id = ProcessInfo.processInfo.environment["TAS_LOCK_CHILD_ID"] else { return }
        let root = URL(fileURLWithPath: path)
        let sentinel = root.appendingPathComponent("critical-section")
        let deadline = Date().addingTimeInterval(20)
        var completed = 0
        while completed < 12 && Date() < deadline {
            // One independent process uses the legacy O_EXCL/PID protocol.
            // It intentionally knows nothing about sync.kernel.lock.
            if id == "5" {
                let marker = root.appendingPathComponent("sync.lock")
                let fd = open(marker.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
                guard fd >= 0 else { usleep(1_000); continue }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                try handle.write(contentsOf: jsonData(["pid": Int(getpid()), "nonce": "legacy-child"]))
                try handle.close()
                let critical = open(sentinel.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
                if critical < 0 { try? Data().write(to: root.appendingPathComponent("overlap")) }
                else { usleep(2_000); close(critical); unlink(sentinel.path) }
                unlink(marker.path)
                completed += 1
                continue
            }
            guard let lock = try? VaultLock(directory: root) else { usleep(1_000); continue }
            withExtendedLifetime(lock) {
                let fd = open(sentinel.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
                if fd < 0 { try? Data().write(to: root.appendingPathComponent("overlap")) }
                else {
                    usleep(2_000)
                    close(fd)
                    unlink(sentinel.path)
                }
            }
            completed += 1
        }
        XCTAssertEqual(completed, 12)
        try String(completed).write(to: root.appendingPathComponent("done-\(id)"), atomically: true, encoding: .utf8)
    }

    func testProtocolMarkerIsAlwaysLiveToLegacyClientsAndRecoverable() throws {
        let root = try directory()
        var lock: VaultLock? = try VaultLock(directory: root)
        let marker = root.appendingPathComponent("sync.lock")
        let value = try jsonObject(Data(contentsOf: marker))
        XCTAssertEqual(value["pid"] as? Int, 1)
        XCTAssertEqual(value["ownerPID"] as? Int, Int(getpid()))
        XCTAssertEqual(value["lockingProtocol"] as? String, "kernel-v1")
        XCTAssertTrue(kill(1, 0) == 0 || errno == EPERM)
        withExtendedLifetime(lock) {}
        lock = nil
        // Equivalent on-disk residue of an abruptly exited kernel-aware owner.
        try jsonData(value).write(to: marker)
        XCTAssertNoThrow(try VaultLock(directory: root))
    }

    func testLegacyLiveAndStaleMarkersAreNeverUnlinked() throws {
        let root = try directory()
        let marker = root.appendingPathComponent("sync.lock")
        for pid in [Int(getpid()), Int(Int32.max)] {
            let bytes = try jsonData(["pid": pid, "nonce": "legacy"])
            try bytes.write(to: marker)
            XCTAssertThrowsError(try VaultLock(directory: root))
            XCTAssertEqual(try Data(contentsOf: marker), bytes)
        }
        try FileManager.default.removeItem(at: marker)
        var lock: VaultLock? = try VaultLock(directory: root)
        XCTAssertNotNil(lock)
        let legacy = open(marker.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        XCTAssertEqual(legacy, -1, "Legacy O_EXCL acquisition must remain blocked")
        if legacy >= 0 { close(legacy) }
        lock = nil
        XCTAssertNoThrow(try VaultLock(directory: root))
    }

    func testKernelLockProtectsStaleMarkerReclamation() throws {
        let root = try directory()
        let kernel = root.appendingPathComponent("sync.kernel.lock")
        let fd = open(kernel.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let marker = root.appendingPathComponent("sync.lock")
        let stale = try jsonData(["pid": Int(Int32.max), "nonce": "stale"])
        try stale.write(to: marker)
        XCTAssertThrowsError(try VaultLock(directory: root), "A held kernel lock must prevent stale-path unlink")
        XCTAssertEqual(try Data(contentsOf: marker), stale)
    }
}
