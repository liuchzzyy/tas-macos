import Foundation
import CZlib

final class GzipStream {
    private var state = z_stream()
    private let compressing: Bool
    private var ended = false
    init(compressing: Bool) throws {
        self.compressing = compressing
        let status = compressing
            ? deflateInit2_(&state, 6, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            : inflateInit2_(&state, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        try require(status == Z_OK, "无法初始化 gzip")
    }
    deinit { if compressing { deflateEnd(&state) } else { inflateEnd(&state) } }
    func update(_ input: Data, final: Bool = false, limit: Int = Int.max) throws -> Data {
        try require(!ended || input.isEmpty, "gzip 包含多余数据")
        if ended { return Data() }
        var result = Data()
        try input.withUnsafeBytes { bytes in
            state.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress)
            state.avail_in = UInt32(input.count)
            var buffer = [UInt8](repeating: 0, count: 65536)
            repeat {
                let count = buffer.count
                let status: Int32 = buffer.withUnsafeMutableBufferPointer { output in
                    state.next_out = output.baseAddress; state.avail_out = UInt32(count)
                    return compressing ? deflate(&state, final ? Z_FINISH : Z_NO_FLUSH) : inflate(&state, final ? Z_FINISH : Z_NO_FLUSH)
                }
                let written = count - Int(state.avail_out)
                try require(written <= limit - result.count, "解压数据超过上限")
                result.append(contentsOf: buffer.prefix(written))
                if status == Z_STREAM_END { ended = true; try require(state.avail_in == 0, "gzip 包含多余数据"); break }
                try require(status == Z_OK || (status == Z_BUF_ERROR && !final && state.avail_in == 0), "gzip 数据损坏或不完整")
                if state.avail_in == 0 && state.avail_out > 0 { break }
            } while true
            state.next_in = nil; state.next_out = nil
        }
        if final { try require(ended, "gzip 数据不完整") }
        return result
    }
}
public enum Gzip {
    public static func compress(_ data: Data) throws -> Data { let stream = try GzipStream(compressing: true); return try stream.update(data) + stream.update(Data(), final: true) }
    public static func decompress(_ data: Data, limit: Int = 256 * 1024 * 1024) throws -> Data {
        let stream = try GzipStream(compressing: false); var output = Data()
        for start in stride(from: 0, to: data.count, by: 65536) { output += try stream.update(data.subdata(in: start..<min(start+65536,data.count)), limit: limit - output.count); try require(output.count <= limit, "解压数据超过上限") }
        output += try stream.update(Data(), final: true); try require(output.count <= limit, "解压数据超过上限"); return output
    }
    public static func decompressFile(_ input: URL, to output: URL, limit: Int64) throws {
        let source = try FileHandle(forReadingFrom: input); defer { try? source.close() }
        let destination = try Paths.privateFile(output); defer { try? destination.close() }
        let stream = try GzipStream(compressing: false); var total: Int64 = 0
        while let data = try source.read(upToCount: 65536), !data.isEmpty {
            let plain = try stream.update(data, limit: Int(min(Int64(Int.max), limit - total))); total += Int64(plain.count); try require(total <= limit, "下载文件超过索引中的大小")
            try destination.write(contentsOf: plain)
        }
        let tail = try stream.update(Data(), final: true); total += Int64(tail.count); try require(total <= limit, "下载文件超过索引中的大小")
        try destination.write(contentsOf: tail); try destination.synchronize()
    }
}
