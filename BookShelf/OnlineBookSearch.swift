import Foundation

enum OnlineBookSource: String, CaseIterable, Identifiable {
    case all = "全部"
    case douban = "豆瓣读书"
    case zongheng = "纵横小说"

    var id: String { rawValue }

    var searchSources: [OnlineBookSource] {
        self == .all ? [.douban, .zongheng] : [self]
    }

    func searchPage(for query: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        switch self {
        case .douban:
            components.host = "book.douban.com"
            components.path = "/subject_search"
            components.queryItems = [URLQueryItem(name: "search_text", value: query), URLQueryItem(name: "cat", value: "1001")]
        case .zongheng:
            components.host = "search.zongheng.com"
            components.path = "/s"
            components.queryItems = [URLQueryItem(name: "keyword", value: query)]
        case .all: return nil
        }
        return components.url
    }
}

struct OnlineBookResult: Identifiable {
    let id: String
    let title: String
    let detail: String
    let summary: String
    let source: OnlineBookSource
    let url: URL
    let coverURL: URL?
    let rating: String?
    let ratingCount: Int?
    let facts: [OnlineBookFact]
    let tags: [String]
}

struct OnlineSearchOutcome {
    let results: [OnlineBookResult]
    let failures: [String]
}

enum OnlineBookSearch {
    static func search(_ query: String, sources: [OnlineBookSource]) async -> OnlineSearchOutcome {
        async let douban = attempt(.douban, query: query, enabled: sources.contains(.douban))
        async let zongheng = attempt(.zongheng, query: query, enabled: sources.contains(.zongheng))
        let attempts = await [douban, zongheng]
        return OnlineSearchOutcome(
            results: attempts.flatMap(\.results),
            failures: attempts.compactMap(\.failure)
        )
    }

    private struct Attempt {
        var results: [OnlineBookResult] = []
        var failure: String?
    }

    private static func attempt(_ source: OnlineBookSource, query: String, enabled: Bool) async -> Attempt {
        guard enabled else { return Attempt() }
        do {
            let results: [OnlineBookResult]
            switch source {
            case .douban: results = try await searchDouban(query)
            case .zongheng: results = try await searchZongheng(query)
            case .all: return Attempt()
            }
            return Attempt(results: results)
        } catch is CancellationError {
            return Attempt()
        } catch {
            return Attempt(failure: "\(source.rawValue)暂时无法搜索，请稍后重试。")
        }
    }

    private static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("BookShelf/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw SearchError.badResponse
        }
        return data
    }

    private static func searchDouban(_ query: String) async throws -> [OnlineBookResult] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "book.douban.com"
        components.path = "/subject_search"
        components.queryItems = [URLQueryItem(name: "search_text", value: query), URLQueryItem(name: "cat", value: "1001")]
        guard let url = components.url else { throw SearchError.badResponse }
        let data = try await fetch(url)
        guard let html = String(data: data, encoding: .utf8),
              let json = embeddedJSONObject(in: html, after: "window.__DATA__ = ") else {
            throw SearchError.badResponse
        }
        let payload = try JSONDecoder().decode(DoubanPayload.self, from: json)
        return payload.items.prefix(20).compactMap { item in
            guard let id = item.id, let title = item.title, !title.isEmpty,
                  let page = item.url.flatMap(URL.init(string:)),
                  page.scheme == "https", page.host == "book.douban.com",
                  page.path.hasPrefix("/subject/") else { return nil }
            return OnlineBookResult(
                id: "douban-\(id)", title: title,
                detail: item.abstract ?? "", summary: "", source: .douban, url: page,
                coverURL: doubanCoverURL(item.coverURL),
                rating: item.rating?.value.map { String(format: "%.1f", $0) },
                ratingCount: item.rating?.count,
                facts: [], tags: []
            )
        }
    }

    private static func searchZongheng(_ query: String) async throws -> [OnlineBookResult] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "search.zongheng.com"
        components.path = "/search/book"
        components.queryItems = [
            URLQueryItem(name: "keyword", value: query),
            URLQueryItem(name: "pageNo", value: "1"),
            URLQueryItem(name: "pageNum", value: "20")
        ]
        guard let url = components.url else { throw SearchError.badResponse }
        let data = try await fetch(url)
        let payload = try JSONDecoder().decode(ZonghengPayload.self, from: data)
        guard payload.code == 0 else { throw SearchError.badResponse }
        return (payload.data?.datas?.list ?? []).compactMap { item in
            guard let bookId = item.bookId, bookId > 0,
                  let name = item.name, !name.isEmpty,
                  let page = URL(string: "https://book.zongheng.com/book/\(bookId).html") else { return nil }
            return OnlineBookResult(
                id: "zongheng-\(bookId)", title: clean(name),
                detail: item.authorName ?? "",
                summary: clean(item.description ?? ""), source: .zongheng, url: page,
                coverURL: zonghengCoverURL(item.coverURL), rating: nil, ratingCount: nil,
                facts: [
                    OnlineBookFact("分类", item.catePName),
                    OnlineBookFact("状态", item.serialStatus == 1 ? "已完结" : item.serialStatus == 0 ? "连载中" : nil),
                    OnlineBookFact("字数", item.totalWord.map { "\($0) 字" }),
                    OnlineBookFact("更新时间", item.updateTime)
                ].filter { !$0.value.isEmpty },
                tags: item.keyword?.split(separator: ",").map { String($0) } ?? []
            )
        }
    }

    private static func doubanCoverURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.scheme == "https",
              let host = url.host?.lowercased(), host.hasSuffix(".doubanio.com") else { return nil }
        return url
    }

    private static func zonghengCoverURL(_ value: String?) -> URL? {
        guard let value, value.hasPrefix("/cover/"), !value.contains("..") else { return nil }
        return URL(string: "https://static.zongheng.com/upload\(value)")
    }

    // The site highlights matching words with font tags; show plain text, never HTML.
    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func embeddedJSONObject(in html: String, after marker: String) -> Data? {
        guard let markerRange = html.range(of: marker),
              let start = html[markerRange.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var insideString = false
        var escaped = false
        for index in html[start...].indices {
            let character = html[index]
            if insideString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { insideString = false }
            } else if character == "\"" {
                insideString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return Data(html[start...index].utf8) }
            }
        }
        return nil
    }

    private enum SearchError: Error { case badResponse }

    private struct DoubanPayload: Decodable {
        let items: [Item]
        struct Item: Decodable {
            let id: Int?
            let title: String?
            let abstract: String?
            let url: String?
            let coverURL: String?
            let rating: Rating?

            enum CodingKeys: String, CodingKey {
                case id, title, abstract, url, rating
                case coverURL = "cover_url"
            }

            struct Rating: Decodable {
                let value: Double?
                let count: Int?
            }
        }
    }

    private struct ZonghengPayload: Decodable {
        let code: Int
        let data: DataBlock?
        struct DataBlock: Decodable {
            let datas: Results?
            struct Results: Decodable { let list: [Item]? }
        }
        struct Item: Decodable {
            let bookId: Int?
            let name: String?
            let authorName: String?
            let description: String?
            let coverURL: String?
            let catePName: String?
            let serialStatus: Int?
            let totalWord: Int?
            let updateTime: String?
            let keyword: String?

            enum CodingKeys: String, CodingKey {
                case bookId, name, authorName, description, catePName, serialStatus, totalWord, updateTime, keyword
                case coverURL = "coverUrl"
            }
        }
    }
}
