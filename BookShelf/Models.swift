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

enum ReadingFont: String, CaseIterable, Identifiable {
    case publisher, sansSerif, serif, kai, monospace

    var id: String { rawValue }

    var name: String {
        switch self {
        case .publisher: "原书字体"
        case .sansSerif: "系统黑体"
        case .serif: "系统衬线字体"
        case .kai: "系统楷体"
        case .monospace: "等宽字体（西文）"
        }
    }
}

enum SpeechSettingKeys {
    static let engine = "speech.engine"
    static let kokoroVoice = "speech.kokoroVoice"
    static let kokoroSpeed = "speech.kokoroSpeed"
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
    var engine = SpeechEngine.system
    var kokoroVoice = 3
    var kokoroSpeed = 1.0
}

enum SpeechEngine: String, CaseIterable {
    case system, kokoro
    var name: String { self == .system ? "系统朗读" : "Kokoro 离线朗读" }
}
