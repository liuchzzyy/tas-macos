import Foundation

/// Filesystem transaction only. The caller must validate paths/signatures, stage
/// the candidate and wait for the old process to exit before invoking this.
public enum UpdateInstallationTransaction {
    public struct Outcome {
        public let reportWarning: String?
    }

    public static func install(staging: URL, target: URL, backup: URL, failed: URL,
                               verify: (URL) throws -> Void,
                               launch: (URL) throws -> Void,
                               writeReport: () throws -> Void,
                               move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws -> Outcome {
        let fm = FileManager.default
        try move(target, backup)
        do {
            try move(staging, target)
            try verify(target)
            try launch(target)
        } catch {
            let updateError = error
            if fm.fileExists(atPath: target.path) {
                do { try move(target, failed) }
                catch { throw TASError("无法移走失败的新应用；旧版应用保存在 \(backup.path)，请手动恢复。\(error.localizedDescription)") }
            }
            do {
                try move(backup, target)
                try? fm.removeItem(at: failed)
            } catch {
                throw TASError("回滚失败；旧版应用保存在 \(backup.path)，请手动恢复。\(error.localizedDescription)")
            }
            throw updateError
        }
        // Launch success commits the install. Reporting must never move a
        // running bundle or consume its only recovery copy.
        do { try writeReport(); return Outcome(reportWarning: nil) }
        catch { return Outcome(reportWarning: error.localizedDescription) }
    }
}
