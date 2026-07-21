package com.example.blntextspeech.epub;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

public class EpubParserTest {
    @Test
    public void parsesMetadataAndSpineInReadingOrder() throws Exception {
        File epub = Files.createTempFile("reader-test", ".epub").toFile();
        try (ZipOutputStream zip = new ZipOutputStream(new FileOutputStream(epub))) {
            put(zip, "META-INF/container.xml",
                    "<?xml version=\"1.0\"?><container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OEBPS/book.opf\"/></rootfiles></container>");
            put(zip, "OEBPS/book.opf",
                    "<?xml version=\"1.0\"?><package xmlns=\"http://www.idpf.org/2007/opf\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>测试书籍</dc:title><dc:creator>测试作者</dc:creator></metadata><manifest><item id=\"b\" href=\"chapter%202.xhtml\"/><item id=\"a\" href=\"chapter1.xhtml\"/></manifest><spine><itemref idref=\"a\"/><itemref idref=\"b\"/></spine></package>");
            put(zip, "OEBPS/chapter1.xhtml", "<html><head><title>第一章 开端</title></head><body><h1>第一章<br/>开端</h1><p>第一段&amp;内容。</p></body></html>");
            put(zip, "OEBPS/chapter 2.xhtml", "<html><body><h1>第二章</h1><p>第二段内容。</p></body></html>");
        }

        EpubDocument document = new EpubParser().parse(epub);
        assertEquals("测试书籍", document.getTitle());
        assertEquals("测试作者", document.getAuthor());
        assertEquals(2, document.getSections().size());
        assertEquals("第一章 开端", document.getSectionTitles().get(0));
        assertEquals("第二章", document.getSectionTitles().get(1));
        assertEquals("第一章 开端\n\n第一段&内容。", document.getSections().get(0));
        assertTrue(document.getReadingText().indexOf("第一章") < document.getReadingText().indexOf("第二章"));
        assertTrue(document.getReadingText().contains("第一段&内容"));
        //noinspection ResultOfMethodCallIgnored
        epub.delete();
    }

    @Test
    public void stripsMarkupAndKeepsParagraphBreaks() {
        String text = EpubParser.htmlToText("<head><title>不应出现</title></head><p>甲&nbsp;乙</p><script>bad()</script><p>丙&#x3002;</p>");
        assertEquals("甲 乙\n丙。", text);
    }

    private static void put(ZipOutputStream zip, String name, String value) throws Exception {
        zip.putNextEntry(new ZipEntry(name));
        zip.write(value.getBytes(StandardCharsets.UTF_8));
        zip.closeEntry();
    }
}
