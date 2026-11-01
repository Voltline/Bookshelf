import Foundation
import os
import ImageIO
import UIKit

nonisolated struct CoverImageRequest: Hashable, Sendable {
    let url: URL
    var maxPixelSize = 600
    var referer: String?
}

/// Bounded decoded-image cache shared by shelf, search results and details.
/// Concurrent requests for the same thumbnail share one load. UI cancellation
/// does not cancel another visible view's shared request; the last departing
/// consumer cancels the underlying work.
actor CoverImagePipeline {
    static let shared = CoverImagePipeline()
    private let cache = NSCache<NSString, UIImage>()
    private struct Load {
        let id = UUID()
        let task: Task<UIImage?, Never>
        var consumers: Set<UUID>
    }
    private var inFlight: [CoverImageRequest: Load] = [:]
    #if DEBUG
    private(set) var loadCount = 0
    #endif

    init() {
        cache.totalCostLimit = 24 * 1024 * 1024
        cache.countLimit = 96
    }

    func image(for request: CoverImageRequest) async -> UIImage? {
        guard !Task.isCancelled else { return nil }
        let key = "\(request.maxPixelSize):\(request.referer ?? ""):\(request.url.absoluteString)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let consumer = UUID()
        if inFlight[request] != nil { inFlight[request]?.consumers.insert(consumer) }
        else {
            #if DEBUG
            loadCount += 1
            #endif
            inFlight[request] = Load(task: Task(priority: .utility) { await Self.load(request) }, consumers: [consumer])
        }
        guard let load = inFlight[request] else { return nil }
        return await withTaskCancellationHandler {
            let image = await load.task.value
            if inFlight[request]?.id == load.id {
                inFlight[request]?.consumers.remove(consumer)
                if inFlight[request]?.consumers.isEmpty == true { inFlight[request] = nil }
                if let image, let cgImage = image.cgImage {
                    cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
                }
            }
            return Task.isCancelled ? nil : image
        } onCancel: {
            Task { await self.cancel(request, consumer: consumer, loadID: load.id) }
        }
    }

    private func cancel(_ request: CoverImageRequest, consumer: UUID, loadID: UUID) {
        guard inFlight[request]?.id == loadID else { return }
        inFlight[request]?.consumers.remove(consumer)
        if inFlight[request]?.consumers.isEmpty == true {
            inFlight[request]?.task.cancel()
            inFlight[request] = nil
        }
    }

    @concurrent
    private static func load(_ request: CoverImageRequest) async -> UIImage? {
        let trace = PerformanceTrace.signposter.beginInterval("CoverLoad", id: PerformanceTrace.signposter.makeSignpostID())
        defer { PerformanceTrace.signposter.endInterval("CoverLoad", trace) }
        let source: CGImageSource?
        if request.url.isFileURL {
            source = CGImageSourceCreateWithURL(request.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        } else {
            var urlRequest = URLRequest(url: request.url)
            urlRequest.timeoutInterval = 15
            if let referer = request.referer { urlRequest.setValue(referer, forHTTPHeaderField: "Referer") }
            guard let (data, response) = try? await URLSession.shared.data(for: urlRequest),
                  let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.mimeType?.hasPrefix("image/") == true, data.count < 5_000_000 else { return nil }
            source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        }
        guard !Task.isCancelled, let source,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, min(1200, request.maxPixelSize)),
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: thumbnail)
    }
}
