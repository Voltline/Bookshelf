import Foundation
import ReadiumShared
import ReadiumStreamer
import UIKit

enum EPUBError: LocalizedError {
    case invalidFileURL
    case openFailed(String)
    case restricted
    case emptyBook

    var errorDescription: String? {
        switch self {
        case .invalidFileURL:
            "无法访问所选文件"
        case .openFailed(let detail):
            "无法打开 EPUB：\(detail)"
        case .restricted:
            "这本 EPUB 受 DRM 保护，当前无法打开"
        case .emptyBook:
            "这本 EPUB 没有可阅读的正文"
        }
    }
}

/// EPUB import and content extraction backed entirely by Readium Swift Toolkit.
/// BookShelf owns only the conversion from Readium's publication model to the
/// lightweight page model used by the existing SwiftUI reader.
@MainActor
final class EPUBParser {
    private let httpClient: HTTPClient
    private let assetRetriever: AssetRetriever
    private let publicationOpener: PublicationOpener

    init() {
        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        self.httpClient = httpClient
        self.assetRetriever = assetRetriever
        publicationOpener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )
    }

    func openPublication(url: URL) async throws -> Publication {
        guard let fileURL = FileURL(url: url) else { throw EPUBError.invalidFileURL }

        let publication: Publication
        do {
            let asset = try await assetRetriever.retrieve(url: fileURL).get()
            publication = try await publicationOpener.open(
                asset: asset,
                allowUserInteraction: false,
                onCreatePublication: { manifest, _, _ in
                    Self.repairMalformedReadingOrder(in: &manifest)
                }
            ).get()
        } catch {
            throw EPUBError.openFailed(error.localizedDescription)
        }

        guard !publication.isRestricted else { throw EPUBError.restricted }
        guard publication.conforms(to: .epub) else {
            throw EPUBError.openFailed("文件内容不是 EPUB 出版物")
        }

        return publication
    }

    /// Some EPUB generators accidentally reset the XML namespace on spine
    /// items. Readium correctly ignores those invalid itemrefs, while more
    /// permissive readers recover them. The navigation document is parsed
    /// independently, so use its links to restore only resources Readium
    /// already discovered in the manifest.
    nonisolated private static func repairMalformedReadingOrder(in manifest: inout Manifest) {
        let toc = flatten(manifest.tableOfContents)
        guard toc.count > 1 else { return }

        let allResources = manifest.readingOrder + manifest.resources
        let resourcesByHREF = Dictionary(
            allResources.map { (canonicalHREF($0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seenTOCHREFs: Set<String> = []
        var tocResources: [Link] = []
        for tocLink in toc {
            let href = canonicalHREF(tocLink)
            guard seenTOCHREFs.insert(href).inserted, let resource = resourcesByHREF[href] else { continue }
            tocResources.append(resource)
        }
        guard tocResources.count > 1 else { return }

        let readingOrderHREFs = Set(manifest.readingOrder.map(canonicalHREF))
        let tocHREFs = Set(tocResources.map(canonicalHREF))
        let recognizedTOCCount = tocHREFs.intersection(readingOrderHREFs).count

        if recognizedTOCCount * 2 < tocResources.count {
            let supplementalDocuments = manifest.resources.filter { resource in
                resource.mediaType?.isHTML == true
                    && !resource.rels.contains(.contents)
                    && !tocHREFs.contains(canonicalHREF(resource))
            }
            let repaired = supplementalDocuments + tocResources
            let repairedHREFs = Set(repaired.map(canonicalHREF))
            manifest.readingOrder = repaired
            manifest.resources.removeAll { resource in
                repairedHREFs.contains(canonicalHREF(resource))
            }
            return
        }

        let indicesByHREF = Dictionary(
            manifest.readingOrder.enumerated().map { (canonicalHREF($0.element), $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let indices = toc.compactMap { indicesByHREF[canonicalHREF($0)] }
        guard indices.count > 1 else { return }

        let isStrictlyReversed = zip(indices, indices.dropFirst()).allSatisfy { $0 > $1 }
        if isStrictlyReversed {
            manifest.readingOrder.reverse()
        }
    }

    nonisolated private static func canonicalHREF(_ link: Link) -> String {
        link.url().removingFragment().normalized.string
    }

    nonisolated private static func flatten(_ links: [Link]) -> [Link] {
        links.flatMap { [$0] + flatten($0.children) }
    }

    func parse(url: URL) async throws -> EPUBMetadata {
        let publication = try await openPublication(url: url)

        let title = publication.metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let authors = publication.metadata.authors.map(\.name).filter { !$0.isEmpty }.joined(separator: "、")
        let cover = try? await publication.cover().get()?.pngData()
        guard !publication.readingOrder.isEmpty else { throw EPUBError.emptyBook }

        return EPUBMetadata(
            title: title?.isEmpty == false ? title! : "未命名书籍",
            author: authors.isEmpty ? "未知作者" : authors,
            cover: cover ?? nil
        )
    }
}
