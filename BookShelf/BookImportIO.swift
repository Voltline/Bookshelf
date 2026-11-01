import Foundation

nonisolated enum BookImportIO {
    @concurrent
    static func copy(from source: URL, to destination: URL) async throws {
        try Task.checkCancellation()
        try FileManager.default.copyItem(at: source, to: destination)
    }

    @concurrent
    static func write(_ data: Data, to destination: URL) async throws {
        try Task.checkCancellation()
        try data.write(to: destination, options: .atomic)
    }
}
