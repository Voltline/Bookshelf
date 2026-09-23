import Foundation
import ReadiumShared

struct BookSearchMatch: Identifiable {
    let id = UUID()
    let locator: Locator

    var chapter: String {
        let title = locator.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "正文" : title
    }
}

@MainActor
enum FullTextSearch {
    static func search(
        publication: Publication,
        query: String,
        limit: Int,
        onBatch: ([BookSearchMatch]) -> Void
    ) async throws -> Bool {
        guard publication.isSearchable else { throw SearchFailure.notSearchable }
        let iterator = try await publication.search(query: query).get()
        var delivered = 0
        while true {
            try Task.checkCancellation()
            guard let page = try await iterator.next().get() else { return false }
            try Task.checkCancellation()
            let remaining = max(0, limit - delivered)
            let batch = page.locators.prefix(remaining).map { BookSearchMatch(locator: $0) }
            if !batch.isEmpty { onBatch(batch) }
            delivered += batch.count
            if page.locators.count > remaining { return true }
            if delivered >= limit {
                try Task.checkCancellation()
                return try await iterator.next().get() != nil
            }
        }
    }

    private enum SearchFailure: LocalizedError {
        case notSearchable
        var errorDescription: String? { "这本书的正文暂时无法搜索。" }
    }
}
