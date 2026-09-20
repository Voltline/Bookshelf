import ReadiumNavigator
import UIKit

/// Do not assume that macOS or downloadable CJK fonts are installed on iOS.
enum ReaderFonts {
    private static func installed(_ names: [String]) -> String? {
        names.first { !UIFont.fontNames(forFamilyName: $0).isEmpty }
    }

    static var available: [ReadingFont] {
        ReadingFont.allCases.filter {
            switch $0 {
            case .serif: installed(["Songti SC", "Songti TC", "Hiragino Mincho ProN"]) != nil
            case .kai: installed(["Kaiti SC", "Kaiti TC"]) != nil
            default: true
            }
        }
    }

    static func name(for font: ReadingFont) -> String {
        switch font {
        case .serif: installed(["Songti SC", "Songti TC"]) != nil ? "系统宋体" : "系统明朝体"
        case .kai: "系统楷体"
        default: font.name
        }
    }

    static func family(for font: ReadingFont) -> FontFamily? {
        switch font {
        case .publisher: nil
        case .sansSerif: FontFamily(rawValue: "PingFang SC")
        case .serif: FontFamily(rawValue: installed(["Songti SC", "Songti TC", "Hiragino Mincho ProN"]) ?? "serif")
        case .kai: installed(["Kaiti SC", "Kaiti TC"]).map(FontFamily.init(rawValue:)) ?? family(for: .serif)
        case .monospace: .monospace
        }
    }
}
