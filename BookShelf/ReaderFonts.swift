import Foundation
import ReadiumNavigator
import ReadiumShared

/// Fonts served by Readium to each EPUB web view. Merely registering the fonts
/// with UIKit is not enough for publication resources loaded by WKWebView.
enum ReaderFonts {
    private static let notoSerif = FontFamily(rawValue: "Bookshelf Noto Serif SC")
    private static let wenKai = FontFamily(rawValue: "Bookshelf WenKai Lite")

    static let available = ReadingFont.allCases

    static func name(for font: ReadingFont) -> String {
        font.name
    }

    static func family(for font: ReadingFont) -> FontFamily? {
        switch font {
        case .publisher: nil
        case .sansSerif: FontFamily(rawValue: "PingFang SC")
        case .serif: notoSerif
        case .kai: wenKai
        case .monospace: .monospace
        }
    }

    static func declarations(bundle: Bundle = .main) -> [AnyHTMLFontFamilyDeclaration] {
        [
            declaration(
                family: notoSerif,
                resource: "NotoSerifCJKsc-Regular",
                extension: "otf",
                alternates: [FontFamily(rawValue: "Hiragino Mincho ProN"), .serif],
                bundle: bundle
            ),
            declaration(
                family: wenKai,
                resource: "LXGWWenKaiLite-Regular",
                extension: "ttf",
                alternates: [FontFamily(rawValue: "PingFang SC"), .sansSerif],
                bundle: bundle
            ),
        ].compactMap { $0 }
    }

    private static func declaration(
        family: FontFamily,
        resource: String,
        extension fileExtension: String,
        alternates: [FontFamily],
        bundle: Bundle
    ) -> AnyHTMLFontFamilyDeclaration? {
        guard let url = bundle.url(forResource: resource, withExtension: fileExtension),
              let file = FileURL(url: url) else {
            assertionFailure("Missing bundled reading font: \(resource).\(fileExtension)")
            return nil
        }
        return CSSFontFamilyDeclaration(
            fontFamily: family,
            alternates: alternates,
            fontFaces: [CSSFontFace(file: file)]
        ).eraseToAnyHTMLFontFamilyDeclaration()
    }
}
