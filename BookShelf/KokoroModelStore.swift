import Combine
import CryptoKit
import Foundation

enum KokoroError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { message } else { nil } }
}

struct KokoroAsset: Decodable, Sendable {
    let path: String
    let size: Int64
    let sha256: String?
    let gitSHA1: String
}

nonisolated enum KokoroModel {
    // Pin both URLs and hashes: never execute an arbitrary downloaded model.
    static let revision = "155831f1b4ba23b1f5c058be6a61df90cefb2a37"
    static let directory = URL.applicationSupportDirectory.appendingPathComponent("Kokoro-v1.1-int8", isDirectory: true)
    static let assets: [KokoroAsset] = {
        guard let url = Bundle.main.url(forResource: "KokoroManifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let files = try? JSONDecoder().decode([KokoroAsset].self, from: data) else { return [] }
        return files
    }()
    static var isInstalled: Bool {
        guard !assets.isEmpty,
              (try? String(contentsOf: directory.appendingPathComponent("installed"), encoding: .utf8)) == revision else { return false }
        return assets.allSatisfy {
            let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent($0.path).path)
            return (attributes?[.size] as? NSNumber)?.int64Value == $0.size
        }
    }
}

@MainActor
final class KokoroModelStore: ObservableObject {
    static let shared = KokoroModelStore()
    @Published private(set) var installed = KokoroModel.isInstalled
    @Published private(set) var downloading = false
    @Published private(set) var removing = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = ""
    @Published var error: String?
    private var downloadTask: Task<Void, Never>?
    private var downloadID = UUID()
    var hasFiles: Bool { FileManager.default.fileExists(atPath: KokoroModel.directory.path) }

    func download() {
        guard !downloading, !removing else { return }
        downloading = true
        let id = UUID()
        downloadID = id
        progress = 0
        error = nil
        status = "正在连接模型源…"
        downloadTask = Task {
            defer { downloading = false; downloadTask = nil }
            do {
                try await KokoroDownloader().install { fraction, file in
                    Task { @MainActor in
                        guard self.downloading, self.downloadID == id else { return }
                        self.progress = fraction
                        self.status = "正在下载：\(file)"
                    }
                }
                installed = KokoroModel.isInstalled
                status = "模型已就绪，可离线使用"
            } catch is CancellationError {
                status = "下载已取消，已校验的文件会保留，下次继续"
            } catch {
                if Task.isCancelled {
                    status = "下载已取消，已校验的文件会保留，下次继续"
                } else {
                    self.error = "模型下载失败：\(error.localizedDescription)。可稍后重试，已完成文件无需重新下载。"
                }
            }
        }
    }

    func cancel() { downloadTask?.cancel() }

    func remove() async {
        guard !downloading, !removing else { return }
        removing = true
        defer { removing = false }
        // Wait for any in-flight synthesis to release its model before deletion.
        await KokoroWorker.shared.unload()
        do {
            if FileManager.default.fileExists(atPath: KokoroModel.directory.path) {
                try FileManager.default.removeItem(at: KokoroModel.directory)
            }
            installed = false
            progress = 0
            status = "模型已删除，可重新下载"
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private final class KokoroDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (Int64) -> Void
    init(update: @escaping @Sendable (Int64) -> Void) { self.update = update }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                               totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { update(totalBytesWritten) }
}

actor KokoroDownloader {
    private var receivedByPath: [String: Int64] = [:]
    private func update(_ received: Int64, asset: KokoroAsset, total: Int64,
                        progress: @Sendable (Double, String) -> Void) {
        receivedByPath[asset.path] = max(receivedByPath[asset.path] ?? 0, min(received, asset.size))
        progress(Double(receivedByPath.values.reduce(0, +)) / Double(total), asset.path)
    }

    func install(progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let assets = KokoroModel.assets
        let directory = KokoroModel.directory
        let revision = KokoroModel.revision
        guard !assets.isEmpty else { throw KokoroError.message("缺少模型下载清单") }
        let total = assets.reduce(Int64(0)) { $0 + $1.size }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = assets.sorted { $0.size > $1.size }.makeIterator()
            func enqueue(_ asset: KokoroAsset) {
                group.addTask {
                    try await self.download(asset, directory: directory, revision: revision, session: session, total: total, progress: progress)
                }
            }
            for _ in 0..<4 { if let asset = iterator.next() { enqueue(asset) } }
            while try await group.next() != nil {
                if let asset = iterator.next() { enqueue(asset) }
            }
        }
        try Task.checkCancellation()
        try revision.write(to: directory.appendingPathComponent("installed"), atomically: true, encoding: .utf8)
    }

    private func download(_ asset: KokoroAsset, directory: URL, revision: String, session: URLSession, total: Int64,
                          progress: @escaping @Sendable (Double, String) -> Void) async throws {
            let fm = FileManager.default
            try Task.checkCancellation()
            // Paths originate only in our bundled manifest, never from a remote response.
            guard !asset.path.hasPrefix("/"), !asset.path.split(separator: "/").contains("..") else {
                throw KokoroError.message("无效的模型资源路径")
            }
            let destination = directory.appendingPathComponent(asset.path)
            if try verified(destination, asset: asset) {
                update(asset.size, asset: asset, total: total, progress: progress)
                return
            }
            let base = "https://huggingface.co/csukuangfj/kokoro-int8-multi-lang-v1_1/resolve/\(revision)/"
            guard let url = URL(string: base + asset.path) else { throw KokoroError.message("无效的下载地址") }
            let delegate = KokoroDownloadProgress { received in
                Task { await self.update(received, asset: asset, total: total, progress: progress) }
            }
            let (temporary, response) = try await session.download(from: url, delegate: delegate)
            defer { try? fm.removeItem(at: temporary) }
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  try verified(temporary, asset: asset) else {
                throw KokoroError.message("资源校验失败：\(asset.path)")
            }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: temporary, to: destination)
            update(asset.size, asset: asset, total: total, progress: progress)
    }

    private func verified(_ url: URL, asset: KokoroAsset) throws -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.int64Value == asset.size else { return false }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var sha256 = SHA256()
        var sha1 = Insecure.SHA1()
        sha1.update(data: Data("blob \(asset.size)\0".utf8))
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            if asset.sha256 != nil { sha256.update(data: chunk) } else { sha1.update(data: chunk) }
        }
        let digest = asset.sha256 != nil ? sha256.finalize().map { String(format: "%02x", $0) }.joined()
            : sha1.finalize().map { String(format: "%02x", $0) }.joined()
        return digest == (asset.sha256 ?? asset.gitSHA1)
    }
}
