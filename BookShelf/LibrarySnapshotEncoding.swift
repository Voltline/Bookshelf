import Foundation
import os

nonisolated enum LibrarySnapshotEncoding {
    @concurrent
    static func library(_ snapshot: LibrarySnapshot) async throws -> Data {
        let trace = PerformanceTrace.signposter.beginInterval("LibraryEncode", id: PerformanceTrace.signposter.makeSignpostID())
        defer { PerformanceTrace.signposter.endInterval("LibraryEncode", trace) }
        try Task.checkCancellation()
        return try JSONEncoder().encode(snapshot)
    }

    @concurrent
    static func activity(_ snapshot: ReadingActivitySnapshot) async throws -> Data {
        let trace = PerformanceTrace.signposter.beginInterval("ActivityEncode", id: PerformanceTrace.signposter.makeSignpostID())
        defer { PerformanceTrace.signposter.endInterval("ActivityEncode", trace) }
        try Task.checkCancellation()
        return try JSONEncoder().encode(snapshot)
    }
}
