import CryptoKit
import Foundation

/// Read in bounded chunks off the main actor, even for very large local books.
nonisolated enum FileFingerprint {
    @concurrent
    static func sha256(of url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        return "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
