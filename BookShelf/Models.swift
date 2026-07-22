import Foundation

struct Book: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var author: String
    let fileName: String
    var coverFileName: String?
    let importedAt: Date
    var locator: ReaderLocator
}

struct ReaderLocator: Codable, Hashable {
    var page: Int = 0
    var totalPages: Int = 0
    var locatorJSON: String?

    var fraction: Double {
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
