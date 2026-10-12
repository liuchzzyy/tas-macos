import Foundation
import CryptoSwift
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(CCommonCrypto)
import CCommonCrypto
import CryptoKit
import Security
#endif

public enum Crypto {
    public static let iterations = 600_000
    public static let chunkSize = 19 * 1024 * 1024
    public static let headerSize = 64
    private static let blockSize = 1024 * 1024

    /// Walk from a trusted root using directory FDs. Never resolve user links,
    /// and never reopen the path after validation (including the fast path).
    static func openSource(_ url: URL) throws -> FileHandle {
        var path = url.path
        #if os(macOS)
        // Fixed OS aliases, not user-controlled symlink canonicalization.
        for alias in ["/var/", "/tmp/", "/etc/"] where path.hasPrefix(alias) {
            path = "/private" + path
            break
        }
        #endif
        let parts = path.split(separator: "/")
        try require(path.hasPrefix("/") && !parts.isEmpty && !parts.contains("..") && !parts.contains(".") && !path.contains("\0"), "源文件路径无效")
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw TASError("无法打开源目录") }
        defer { close(directory) }
        for part in parts.dropLast() {
            let next = openat(directory, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw TASError("源文件祖先目录不可读取或包含符号链接") }
            close(directory)
            directory = next
        }
        let fd = openat(directory, String(parts.last!), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TASError("源文件不可读取或是符号链接") }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            throw TASError("源文件必须是普通文件")
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    static func key(_ password: String, salt: [UInt8]) throws -> [UInt8] {
        #if canImport(CCommonCrypto)
        var output = [UInt8](repeating: 0, count: 32)
        let bytes = Array(password.utf8) + [0]
        let status = bytes.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBufferPointer { saltBuffer in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBuffer.baseAddress!.assumingMemoryBound(to: Int8.self), bytes.count - 1, saltBuffer.baseAddress!, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), UInt32(iterations), &output, 32)
            }
        }
        try require(status == kCCSuccess, "密钥派生失败")
        return output
        #else
        return try PKCS5.PBKDF2(password: Array(password.utf8), salt: salt, iterations: iterations, keyLength: 32, variant: .sha2(.sha512)).calculate()
        #endif
    }
    public static func passwordHash(_ password: String) throws -> String {
        try key(password, salt: Array("tas-password-verify-v2".utf8)).toHexString()
    }
    public static func verifyPassword(_ password: String, hash: String) throws -> Bool {
        let current = try passwordHash(password)
        if constantTimeEqual(Array(current.utf8), Array(hash.utf8)) { return true }
        return constantTimeEqual(Array((Array((password + "was-verify").utf8).sha256().toHexString()).utf8), Array(hash.utf8))
    }
    private static func constantTimeEqual(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices { difference |= lhs[index] ^ rhs[index] }
        return difference == 0
    }
    private static func random(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        #if canImport(Security)
        try require(SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess, "安全随机数生成失败")
        #else
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
        #endif
        return bytes
    }
    public static func encrypt(_ data: Data, password: String) throws -> Data {
        let salt = try random(32); let iv = try random(12); let derived = try key(password, salt: salt)
        #if canImport(CryptoKit)
        let sealed = try CryptoKit.AES.GCM.seal(data, using: SymmetricKey(data: derived), nonce: CryptoKit.AES.GCM.Nonce(data: iv))
        return Data(salt + iv) + sealed.ciphertext + sealed.tag
        #else
        let mode = GCM(iv: iv, mode: .detached)
        let encrypted = try CryptoSwift.AES(key: derived, blockMode: mode, padding: .noPadding).encrypt(Array(data))
        guard let tag = mode.authenticationTag else { throw TASError("缺少认证标签") }
        return Data(salt + iv + encrypted + tag)
        #endif
    }
    public static func decrypt(_ data: Data, password: String) throws -> Data {
        try require(data.count >= 60, "加密数据不完整")
        let salt = Array(data.prefix(32)); let iv = Array(data.dropFirst(32).prefix(12))
        let derived = try key(password, salt: salt)
        #if canImport(CryptoKit)
        let sealed = try CryptoKit.AES.GCM.SealedBox(nonce: CryptoKit.AES.GCM.Nonce(data: iv), ciphertext: data.dropFirst(44).dropLast(16), tag: data.suffix(16))
        return try CryptoKit.AES.GCM.open(sealed, using: SymmetricKey(data: derived))
        #else
        let mode = GCM(iv: iv, authenticationTag: Array(data.suffix(16)), mode: .detached)
        var cipher = try CryptoSwift.AES(key: derived, blockMode: mode, padding: .noPadding).makeDecryptor()
        return Data(try cipher.update(withBytes: Array(data.dropFirst(44).dropLast(16))) + cipher.finish())
        #endif
    }
    /// Streaming v1 envelope keeps large legacy files compatible without whole-file allocation.
    public static func encryptFile(_ input: URL, to output: URL, password: String, compressed: Bool) throws {
        let source = try openSource(input); defer { try? source.close() }
        #if canImport(CryptoKit)
        // Keep the legacy envelope while using Apple's accelerated AES for common files.
        // The fixed cap bounds allocation; large inputs continue through the streaming path.
        if let plain = try boundedData(source, limit: 8 * 1024 * 1024) {
            try Task.checkCancellation()
            let encrypted = try encrypt(compressed ? Gzip.compress(plain) : plain, password: password)
            let destination = try Paths.privateFile(output); defer { try? destination.close() }
            try destination.write(contentsOf: encrypted); try destination.synchronize(); return
        }
        #endif
        try source.seek(toOffset: 0)
        let destination = try Paths.privateFile(output); defer { try? destination.close() }
        let salt = try random(32); let iv = try random(12)
        let mode = GCM(iv: iv, mode: .detached)
        var cipher = try CryptoSwift.AES(key: key(password, salt: salt), blockMode: mode, padding: .noPadding).makeEncryptor()
        let gzip = compressed ? try GzipStream(compressing: true) : nil
        try destination.write(contentsOf: Data(salt + iv))
        while let data = try source.read(upToCount: blockSize), !data.isEmpty {
            try Task.checkCancellation()
            let processed = try gzip?.update(data) ?? data
            try destination.write(contentsOf: Data(cipher.update(withBytes: Array(processed))))
        }
        if let tail = try gzip?.update(Data(), final: true) { try destination.write(contentsOf: Data(cipher.update(withBytes: Array(tail)))) }
        try destination.write(contentsOf: Data(cipher.finish()))
        guard let tag = mode.authenticationTag else { throw TASError("缺少认证标签") }
        try destination.write(contentsOf: Data(tag)); try destination.synchronize()
    }
    public static func decryptFile(_ input: URL, to output: URL, password: String) throws {
        let source = try openSource(input); defer { try? source.close() }
        let size = try source.seekToEnd(); try require(size >= 60, "加密文件不完整")
        #if canImport(CryptoKit)
        if size <= 8 * 1024 * 1024 + 60 {
            try Task.checkCancellation()
            try source.seek(toOffset: 0)
            let bytes = try source.read(upToCount: Int(size) + 1) ?? Data()
            try require(bytes.count == Int(size), "加密文件在读取期间发生变化")
            let plain = try decrypt(bytes, password: password)
            let destination = try Paths.privateFile(output); defer { try? destination.close() }
            try destination.write(contentsOf: plain); try destination.synchronize(); return
        }
        #endif
        try source.seek(toOffset: 0); let prefix = try source.read(upToCount: 44) ?? Data()
        try require(prefix.count == 44, "加密文件头不完整")
        try source.seek(toOffset: size - 16); let tag = try source.read(upToCount: 16) ?? Data()
        let mode = GCM(iv: Array(prefix.suffix(12)), authenticationTag: Array(tag), mode: .detached)
        var cipher = try CryptoSwift.AES(key: key(password, salt: Array(prefix.prefix(32))), blockMode: mode, padding: .noPadding).makeDecryptor()
        let destination = try Paths.privateFile(output); defer { try? destination.close() }
        try source.seek(toOffset: 44)
        var remaining = size - 60
        do {
            while remaining > 0 {
                try Task.checkCancellation()
                let chunk = try source.read(upToCount: Int(min(UInt64(blockSize), remaining))) ?? Data()
                try require(!chunk.isEmpty, "加密文件意外结束")
                remaining -= UInt64(chunk.count)
                try destination.write(contentsOf: Data(cipher.update(withBytes: Array(chunk))))
            }
            try destination.write(contentsOf: Data(cipher.finish())); try destination.synchronize()
        } catch { try? destination.close(); try? FileManager.default.removeItem(at: output); throw error }
    }
    private static func boundedData(_ file: FileHandle, limit: Int) throws -> Data? {
        guard try file.seekToEnd() <= UInt64(limit) else { return nil }
        try file.seek(toOffset: 0)
        let data = try file.read(upToCount: limit + 1) ?? Data()
        return data.count <= limit ? data : nil
    }
    public static func hashFile(_ url: URL) throws -> String {
        try Task.checkCancellation()
        let file = try openSource(url); defer { try? file.close() }
        #if canImport(CCommonCrypto)
        var context = CC_SHA256_CTX(); CC_SHA256_Init(&context)
        while let data = try file.read(upToCount: blockSize), !data.isEmpty { try Task.checkCancellation(); _ = data.withUnsafeBytes { CC_SHA256_Update(&context, $0.baseAddress, CC_LONG(data.count)) } }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH)); CC_SHA256_Final(&digest, &context)
        return digest.toHexString()
        #else
        var hash = SHA2(variant: .sha256)
        while let data = try file.read(upToCount: blockSize), !data.isEmpty { try Task.checkCancellation(); _ = try hash.update(withBytes: Array(data)) }
        return try hash.finish().toHexString()
        #endif
    }
    public static func header(index: Int, total: Int, compressed: Bool) throws -> Data {
        try require(index >= 0 && total > 0 && index < total && total <= 65535, "分块数量越界")
        var h = [UInt8](repeating: 0, count: headerSize); h.replaceSubrange(0..<4, with: Array("WAS1".utf8)); h[4] = 1; h[6] = compressed ? 1 : 0
        h[16] = UInt8(index & 255); h[17] = UInt8(index >> 8); h[18] = UInt8(total & 255); h[19] = UInt8(total >> 8)
        return Data(h)
    }
    public static func parseHeader(_ bytes: Data) throws -> (index: Int, total: Int, compressed: Bool) {
        let h = Array(bytes.prefix(headerSize))
        try require(h.count == headerSize && Array(h.prefix(4)) == Array("WAS1".utf8), "无效的 WAS1 文件头")
        try require(h[4] == 1 && h[5] == 0 && Int(h[20]) + Int(h[21])*256 <= 42, "不支持的 WAS1 文件头")
        return (Int(h[16]) + Int(h[17])*256, Int(h[18]) + Int(h[19])*256, h[6] & 1 == 1)
    }
    public static func shouldCompress(_ name: String) -> Bool {
        let skip: Set<String> = ["jpg","jpeg","png","gif","webp","avif","heic","heif","mp4","mkv","avi","mov","webm","m4v","mp3","aac","m4a","ogg","opus","flac","wma","zip","rar","7z","gz","bz2","xz","tgz","pdf","docx","xlsx","pptx","epub","dmg","iso","apk","ipa"]
        return !skip.contains((name as NSString).pathExtension.lowercased())
    }
}
