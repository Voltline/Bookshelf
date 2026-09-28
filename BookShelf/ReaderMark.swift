import Foundation
import ReadiumShared
import UIKit

struct ReaderMark: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        // Kept only to decode existing mark files without losing highlights.
        case bookmark
        case highlight
    }

    enum Color: String, Codable, CaseIterable, Identifiable {
        case yellow, green, blue, pink

        var id: String { rawValue }

        var name: String {
            switch self {
            case .yellow: "黄色"
            case .green: "绿色"
            case .blue: "蓝色"
            case .pink: "粉色"
            }
        }

        var tint: UIColor {
            switch self {
            case .yellow: .systemYellow
            case .green: .systemGreen
            case .blue: .systemBlue
            case .pink: .systemPink
            }
        }
    }

    let id: UUID
    let kind: Kind
    let locatorJSON: String
    let chapter: String
    let excerpt: String
    var note: String
    var color: Color
    let createdAt: Date

    var locator: Locator? { try? Locator(jsonString: locatorJSON) }
}
