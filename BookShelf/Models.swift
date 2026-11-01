import Foundation

nonisolated struct Book: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var author: String
    let fileName: String
    var coverFileName: String?
    let importedAt: Date
    var locator: ReaderLocator
    var isFavorite = false
    var isFinished = false
    var lastOpenedAt: Date?
    var sourceFormat: String?
    var collectionIDs: [UUID] = []
    var deletedAt: Date?
    var sourceFingerprint: String?

    var hasStartedReading: Bool { lastOpenedAt != nil || locator.locatorJSON != nil || locator.page > 0 }
    var progressLabel: String {
        if isFinished { return "已读完" }
        return hasStartedReading ? "已读 \(Int((locator.fraction * 100).rounded()))%" : "未开始"
    }
}

extension Book {
    private enum CodingKeys: String, CodingKey {
        case id, title, author, fileName, coverFileName, importedAt, locator
        case isFavorite, isFinished, lastOpenedAt, sourceFormat, collectionIDs, deletedAt, sourceFingerprint
    }

    nonisolated init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        author = try values.decode(String.self, forKey: .author)
        fileName = try values.decode(String.self, forKey: .fileName)
        coverFileName = try values.decodeIfPresent(String.self, forKey: .coverFileName)
        importedAt = try values.decode(Date.self, forKey: .importedAt)
        locator = try values.decode(ReaderLocator.self, forKey: .locator)
        isFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        isFinished = try values.decodeIfPresent(Bool.self, forKey: .isFinished) ?? false
        lastOpenedAt = try values.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        sourceFormat = try values.decodeIfPresent(String.self, forKey: .sourceFormat)
        collectionIDs = try values.decodeIfPresent([UUID].self, forKey: .collectionIDs) ?? []
        deletedAt = try values.decodeIfPresent(Date.self, forKey: .deletedAt)
        sourceFingerprint = try values.decodeIfPresent(String.self, forKey: .sourceFingerprint)
    }
}

nonisolated struct BookCollection: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date
}

nonisolated struct LibrarySnapshot: Codable, Sendable {
    var version = 1
    var books: [Book]
    var collections: [BookCollection]
}

nonisolated struct ReaderLocator: Codable, Hashable, Sendable {
    var page: Int = 0
    var totalPages: Int = 0
    var locatorJSON: String?
    var progression: Double?

    var fraction: Double {
        if let progression, progression.isFinite { return min(1, max(0, progression)) }
        guard totalPages > 1 else { return 0 }
        return min(1, max(0, Double(page) / Double(totalPages - 1)))
    }
}

struct EPUBMetadata {
    var title: String
    var author: String
    var cover: Data?
}

enum ReadingTheme: String, CaseIterable, Identifiable {
    case paper, sepia, night
    var id: String { rawValue }
    var name: String { switch self { case .paper: "白纸"; case .sepia: "米黄"; case .night: "夜间" } }
}

enum ReadingMode: String, CaseIterable, Identifiable {
    case page, scroll
    var id: String { rawValue }
    var name: String { self == .page ? "左右翻页" : "上下滚动" }
}

enum ReadingFont: String, CaseIterable, Identifiable {
    case publisher, sansSerif, serif, kai, monospace

    var id: String { rawValue }

    var name: String {
        switch self {
        case .publisher: "原书字体"
        case .sansSerif: "系统黑体"
        case .serif: "思源宋体"
        case .kai: "霞鹜文楷"
        case .monospace: "等宽字体（西文）"
        }
    }
}

enum SpeechSettingKeys {
    static let language = "speech.language"
    static let voiceIdentifier = "speech.voiceIdentifier"
    static let rate = "speech.rate"
    static let pitch = "speech.pitch"
    static let volume = "speech.volume"
    static let sentencePause = "speech.sentencePause"
    static let highlightEnabled = "speech.highlightEnabled"
    static let autoPageTurnEnabled = "speech.autoPageTurnEnabled"
}

struct SpeechSettings: Equatable {
    var languageCode = "zh-CN"
    var voiceIdentifier = ""
    var rate = 0.5
    var pitch = 1.0
    var volume = 1.0
    var sentencePause = 0.0
    var highlightEnabled = true
    var autoPageTurnEnabled = true
}
