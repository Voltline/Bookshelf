import Foundation
import SwiftSoup

struct OnlineBookFact: Identifiable {
    let label: String
    let value: String

    var id: String { label }

    init(_ label: String, _ value: String?) {
        self.label = label
        self.value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

struct OnlineBookDetails {
    let author: String?
    let rating: String?
    let ratingCount: Int?
    let summary: String?
    let facts: [OnlineBookFact]
    let tags: [String]

    static func preview(for result: OnlineBookResult) -> OnlineBookDetails {
        let author = result.source == .douban
            ? result.detail.components(separatedBy: " / ").first
            : result.detail
        return OnlineBookDetails(
            author: author?.isEmpty == false ? author : nil,
            rating: result.rating,
            ratingCount: result.ratingCount,
            summary: result.summary.isEmpty ? nil : result.summary,
            facts: result.facts,
            tags: result.tags
        )
    }
}

enum OnlineBookDetailService {
    static func fetch(for result: OnlineBookResult) async throws -> OnlineBookDetails {
        switch result.source {
        case .douban:
            guard result.url.scheme == "https", result.url.host == "book.douban.com" else { throw DetailError.invalidURL }
        case .zongheng:
            guard result.url.scheme == "https", result.url.host == "book.zongheng.com" else { throw DetailError.invalidURL }
        case .all:
            throw DetailError.invalidURL
        }
        var request = URLRequest(url: result.url)
        request.timeoutInterval = 15
        request.setValue("BookShelf/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { throw DetailError.invalidResponse }
        let document = try SwiftSoup.parse(html, result.url.absoluteString)
        return try result.source == .douban
            ? parseDouban(document, result: result)
            : parseZongheng(document, result: result)
    }

    private static func parseDouban(_ document: Document, result: OnlineBookResult) throws -> OnlineBookDetails {
        var values: [String: String] = [:]
        if let info = try document.select("#info").first() {
            let markup = try info.html().replacingOccurrences(
                of: "(?i)<br\\s*/?>", with: "\u{001E}", options: .regularExpression
            )
            for line in markup.components(separatedBy: "\u{001E}") {
                let plain = try SwiftSoup.parseBodyFragment(line).text()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let separator = plain.firstIndex(where: { $0 == ":" || $0 == "：" }) else { continue }
                let label = String(plain[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(plain[plain.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !label.isEmpty && !value.isEmpty { values[label] = value }
            }
        }
        let labels = ["出版社", "出品方", "出版年", "页数", "装帧", "定价", "ISBN", "丛书"]
        let facts = labels.compactMap { label -> OnlineBookFact? in
            guard let value = values[label] else { return nil }
            return OnlineBookFact(label, value)
        }
        let rating = try elementText(document, "#interest_sectl .rating_num") ?? result.rating
        let ratingCount = Int(try elementText(document, "#interest_sectl [property='v:votes']") ?? "") ?? result.ratingCount
        let summary = try elementText(document, "#link-report .intro") ?? result.summary
        return OnlineBookDetails(
            author: values["作者"] ?? OnlineBookDetails.preview(for: result).author,
            rating: rating, ratingCount: ratingCount,
            summary: summary.isEmpty ? nil : summary,
            facts: facts, tags: []
        )
    }

    private static func parseZongheng(_ document: Document, result: OnlineBookResult) throws -> OnlineBookDetails {
        let category = try meta(document, "og:novel:category")
        let status = try meta(document, "og:novel:status")
        let latest = try meta(document, "og:novel:latest_chapter_name")
        let updated = try meta(document, "og:novel:update_time")
        var facts = [OnlineBookFact("分类", category), OnlineBookFact("状态", status)]
        for block in try document.select(".book-info--nums > div") {
            let label = try block.select("i").first()?.text() ?? ""
            let value = try block.select("span").first()?.text() ?? ""
            if label == "万字数" { facts.append(OnlineBookFact("字数", "\(value) 万字")) }
            if label == "总点击" { facts.append(OnlineBookFact("总点击", value)) }
            if label == "总推荐" { facts.append(OnlineBookFact("总推荐", value)) }
        }
        facts.append(OnlineBookFact("最新章节", latest))
        facts.append(OnlineBookFact("更新时间", updated))
        facts = facts.filter { !$0.value.isEmpty }

        let tags = try document.select(".book-info--tags span")
            .compactMap { element -> String? in
                let value = try element.text().trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty || value == category || value == status || value == "已签约" ? nil : value
            }
        let preview = OnlineBookDetails.preview(for: result)
        return OnlineBookDetails(
            author: try meta(document, "og:novel:author") ?? preview.author,
            rating: nil, ratingCount: nil,
            summary: preview.summary,
            facts: facts.isEmpty ? preview.facts : facts,
            tags: tags.isEmpty ? preview.tags : tags
        )
    }

    private static func meta(_ document: Document, _ name: String) throws -> String? {
        let value = try document.select("meta[name='\(name)']").first()?.attr("content")
        return value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func elementText(_ document: Document, _ selector: String) throws -> String? {
        let value = try document.select(selector).first()?.text()
        return value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum DetailError: Error { case invalidURL, invalidResponse }
}
