import CoreFoundation
import Foundation
import ReadiumZIPFoundation

enum TXTImportError: LocalizedError {
    case unsupportedEncoding
    case emptyFile
    case invalidText

    var errorDescription: String? {
        switch self {
        case .unsupportedEncoding: "无法识别 TXT 编码；支持 UTF-8、UTF-16、GB18030、Big5 和 Shift-JIS"
        case .emptyFile: "TXT 文件没有可阅读的正文"
        case .invalidText: "所选文件不是有效的纯文本"
        }
    }
}

/// Converts plain text into a small EPUB 3 publication so the existing Readium
/// navigator provides identical pagination, progress, font controls and TTS.
nonisolated enum TXTImporter {
    private struct Section {
        let title: String
        let startsChapter: Bool
        let paragraphs: [String]
    }

    static func convert(_ sourceURL: URL, to destinationURL: URL, title: String) async throws {
        let data = try Data(contentsOf: sourceURL)
        let text = try decode(data)
        let sections = try makeSections(from: text)
        let workDirectory = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".txt-import-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        func write(_ content: String, at path: String) throws {
            let url = workDirectory.appendingPathComponent(path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }

        try write("application/epub+zip", at: "mimetype")
        try write("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """, at: "META-INF/container.xml")
        try write(stylesheet, at: "OEBPS/styles.css")

        let chapterFiles = sections.indices.map { String(format: "chapter-%04d.xhtml", $0 + 1) }
        for (index, section) in sections.enumerated() {
            let heading = section.startsChapter && section.title != "正文"
                ? "<h1 class=\"chapter-title\">\(escapeXML(section.title))</h1>"
                : ""
            let paragraphs = section.paragraphs.map { "<p>\(escapeXML($0))</p>" }.joined(separator: "\n")
            try write("""
                <?xml version="1.0" encoding="UTF-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh-CN" lang="zh-CN">
                  <head><meta charset="UTF-8"/><title>\(escapeXML(section.title))</title><link rel="stylesheet" type="text/css" href="styles.css"/></head>
                  <body>\(heading)\n\(paragraphs)</body>
                </html>
                """, at: "OEBPS/\(chapterFiles[index])")
        }

        let navigationItems = sections.enumerated().compactMap { index, section -> String? in
            guard section.startsChapter else { return nil }
            return "<li><a href=\"\(chapterFiles[index])\">\(escapeXML(section.title))</a></li>"
        }.joined(separator: "\n")
        try write("""
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="zh-CN" lang="zh-CN">
              <head><meta charset="UTF-8"/><title>目录</title></head>
              <body><nav epub:type="toc" id="toc"><h1>目录</h1><ol>\(navigationItems)</ol></nav></body>
            </html>
            """, at: "OEBPS/nav.xhtml")

        let manifestItems = chapterFiles.enumerated().map { index, file in
            "<item id=\"chapter-\(index + 1)\" href=\"\(file)\" media-type=\"application/xhtml+xml\"/>"
        }.joined(separator: "\n")
        let spineItems = chapterFiles.indices.map { "<itemref idref=\"chapter-\($0 + 1)\"/>" }.joined(separator: "\n")
        let modified = ISO8601DateFormatter().string(from: Date())
        try write("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id" xml:lang="zh-CN">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="book-id">urn:uuid:\(UUID().uuidString)</dc:identifier>
                <dc:title>\(escapeXML(title))</dc:title>
                <dc:language>zh-CN</dc:language>
                <meta property="dcterms:modified">\(modified)</meta>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="style" href="styles.css" media-type="text/css"/>
                \(manifestItems)
              </manifest>
              <spine>\(spineItems)</spine>
            </package>
            """, at: "OEBPS/content.opf")

        let archive = try await Archive(url: destinationURL, accessMode: .create)
        try await archive.addEntry(with: "mimetype", relativeTo: workDirectory, compressionMethod: .none)
        let entries = ["META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml", "OEBPS/styles.css"]
            + chapterFiles.map { "OEBPS/\($0)" }
        for entry in entries {
            try await archive.addEntry(with: entry, relativeTo: workDirectory, compressionMethod: .deflate)
        }
    }

    private static func decode(_ data: Data) throws -> String {
        guard !data.isEmpty else { throw TXTImportError.emptyFile }
        let utf8 = Data(data.dropFirst(data.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0))
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0632))
        let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0A03))
        let candidates: [(Data, String.Encoding)]
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            candidates = [(data, .utf16)]
        } else {
            let sample = data.prefix(256)
            let evenNULs = sample.enumerated().filter { $0.offset.isMultiple(of: 2) && $0.element == 0 }.count
            let oddNULs = sample.enumerated().filter { !$0.offset.isMultiple(of: 2) && $0.element == 0 }.count
            if evenNULs > sample.count / 8 {
                candidates = [(data, .utf16BigEndian), (utf8, .utf8)]
            } else if oddNULs > sample.count / 8 {
                candidates = [(data, .utf16LittleEndian), (utf8, .utf8)]
            } else {
                candidates = [(utf8, .utf8), (data, gb18030), (data, big5), (data, .shiftJIS)]
            }
        }
        guard let decoded = candidates.lazy.compactMap({ String(data: $0.0, encoding: $0.1) }).first else {
            throw TXTImportError.unsupportedEncoding
        }
        let text = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TXTImportError.emptyFile }
        let controlCount = text.unicodeScalars.filter { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t" }.count
        guard controlCount < max(5, text.unicodeScalars.count / 100) else { throw TXTImportError.invalidText }
        let xmlSafeScalars = text.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\r" || scalar == "\t"
                || (scalar.value >= 0x20 && scalar.value & 0xFFFE != 0xFFFE)
        }
        return String(String.UnicodeScalarView(xmlSafeScalars))
    }

    private static func makeSections(from text: String) throws -> [Section] {
        var sections: [Section] = []
        var title = "正文"
        var startsChapter = true
        var paragraphs: [String] = []
        var length = 0

        func flush() {
            guard !paragraphs.isEmpty else { return }
            sections.append(Section(title: title, startsChapter: startsChapter, paragraphs: paragraphs))
            paragraphs.removeAll(keepingCapacity: true)
            length = 0
            startsChapter = false
        }

        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if isChapterHeading(line) {
                flush()
                title = line
                startsChapter = true
                continue
            }
            var start = line.startIndex
            while start < line.endIndex {
                let end = line.index(start, offsetBy: 20_000, limitedBy: line.endIndex) ?? line.endIndex
                let paragraph = String(line[start..<end])
                if length + paragraph.utf16.count > 30_000 && !paragraphs.isEmpty { flush() }
                paragraphs.append(paragraph)
                length += paragraph.utf16.count
                start = end
            }
        }
        flush()
        guard !sections.isEmpty else { throw TXTImportError.emptyFile }
        return sections
    }

    private static func isChapterHeading(_ line: String) -> Bool {
        guard line.count <= 80 else { return false }
        return line.range(of: #"^(?:第[零〇一二三四五六七八九十百千万两0-9０-９]+[章节回卷篇集部](?:[\s:：、.．-]+.{0,50})?|序章|序言|楔子|引子|尾声|后记|番外(?:[\s:：、.．-]+.{0,50})?|Chapter\s+\d+(?:[\s:：.-]+.{0,50})?)$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static let stylesheet = """
        html { writing-mode: horizontal-tb; }
        body { margin: 0; padding: 0; }
        p { margin: 0 0 0.72em; text-indent: 2em; text-align: justify; overflow-wrap: break-word; }
        .chapter-title { margin: 1.2em 0 1.5em; text-align: center; text-indent: 0; line-height: 1.4; font-weight: 600; }
        """
}
