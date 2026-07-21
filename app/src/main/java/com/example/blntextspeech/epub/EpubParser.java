package com.example.blntextspeech.epub;

import org.w3c.dom.Document;
import org.w3c.dom.Element;
import org.w3c.dom.Node;
import org.w3c.dom.NodeList;
import org.xml.sax.SAXException;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

import javax.xml.parsers.DocumentBuilder;
import javax.xml.parsers.DocumentBuilderFactory;
import javax.xml.parsers.ParserConfigurationException;

public final class EpubParser {
    private static final int MAX_ENTRY_BYTES = 12 * 1024 * 1024;
    private static final int MAX_SECTIONS = 10_000;
    private static final Pattern HEAD = Pattern.compile("(?is)<head\\b[^>]*>.*?</head\\s*>");
    private static final Pattern SCRIPT_STYLE = Pattern.compile("(?is)<(script|style)[^>]*>.*?</\\1\\s*>");
    private static final Pattern BLOCK_END = Pattern.compile("(?is)</(p|div|h[1-6]|li|blockquote|section|article|tr)>|<br\\s*/?>");
    private static final Pattern TAG = Pattern.compile("(?is)<[^>]+>");
    private static final Pattern HEADING = Pattern.compile("(?is)<h[1-6][^>]*>(.*?)</h[1-6]\\s*>");
    private static final Pattern ENTITY = Pattern.compile("&(#x?[0-9a-fA-F]+|amp|lt|gt|quot|apos|nbsp);", Pattern.CASE_INSENSITIVE);

    public EpubDocument parse(File file) throws IOException {
        try (ZipFile zip = new ZipFile(file)) {
            String opfPath = findPackagePath(zip);
            Document packageDocument = parseXml(readEntry(zip, opfPath));

            String title = firstText(packageDocument, "title");
            String author = firstText(packageDocument, "creator");
            if (author.isEmpty()) author = "未知作者";

            Map<String, String> manifest = new HashMap<>();
            NodeList items = packageDocument.getElementsByTagNameNS("*", "item");
            if (items.getLength() == 0) items = packageDocument.getElementsByTagName("item");
            for (int i = 0; i < items.getLength(); i++) {
                Element item = (Element) items.item(i);
                String id = item.getAttribute("id");
                String href = item.getAttribute("href");
                if (!id.isEmpty() && !href.isEmpty()) manifest.put(id, resolveEntry(opfPath, href));
            }

            List<String> sections = new ArrayList<>();
            List<String> sectionTitles = new ArrayList<>();
            NodeList refs = packageDocument.getElementsByTagNameNS("*", "itemref");
            if (refs.getLength() == 0) refs = packageDocument.getElementsByTagName("itemref");
            for (int i = 0; i < refs.getLength() && sections.size() < MAX_SECTIONS; i++) {
                Element ref = (Element) refs.item(i);
                String entryPath = manifest.get(ref.getAttribute("idref"));
                if (entryPath == null) continue;
                ZipEntry entry = zip.getEntry(entryPath);
                if (entry == null) continue;
                String html = new String(readEntry(zip, entryPath), StandardCharsets.UTF_8);
                String text = htmlToText(html);
                if (!text.isEmpty()) {
                    String sectionTitle = extractSectionTitle(html, text, sections.size() + 1);
                    sections.add(normalizeSectionText(html, text, sectionTitle));
                    sectionTitles.add(sectionTitle);
                }
            }
            if (sections.isEmpty()) throw new IOException("EPUB 中没有可阅读的正文内容");
            return new EpubDocument(title, author, sections, sectionTitles);
        } catch (ParserConfigurationException | SAXException e) {
            throw new IOException("EPUB 目录或书籍描述文件无效", e);
        }
    }

    private static String findPackagePath(ZipFile zip)
            throws IOException, ParserConfigurationException, SAXException {
        Document container = parseXml(readEntry(zip, "META-INF/container.xml"));
        NodeList roots = container.getElementsByTagNameNS("*", "rootfile");
        if (roots.getLength() == 0) roots = container.getElementsByTagName("rootfile");
        if (roots.getLength() == 0) throw new IOException("EPUB 缺少 package 文档位置");
        String path = ((Element) roots.item(0)).getAttribute("full-path");
        if (path.isEmpty()) throw new IOException("EPUB package 路径为空");
        return path.replace('\\', '/');
    }

    private static Document parseXml(byte[] bytes)
            throws ParserConfigurationException, IOException, SAXException {
        DocumentBuilderFactory factory = DocumentBuilderFactory.newInstance();
        factory.setNamespaceAware(true);
        // Some Android XML providers throw even when disabling optional XInclude.
        try {
            factory.setXIncludeAware(false);
        } catch (UnsupportedOperationException ignored) {
        }
        try {
            factory.setExpandEntityReferences(false);
        } catch (UnsupportedOperationException ignored) {
        }
        setFeature(factory, "http://apache.org/xml/features/disallow-doctype-decl", true);
        setFeature(factory, "http://xml.org/sax/features/external-general-entities", false);
        setFeature(factory, "http://xml.org/sax/features/external-parameter-entities", false);
        DocumentBuilder builder = factory.newDocumentBuilder();
        return builder.parse(new ByteArrayInputStream(bytes));
    }

    private static void setFeature(DocumentBuilderFactory factory, String name, boolean value) {
        try {
            factory.setFeature(name, value);
        } catch (ParserConfigurationException ignored) {
            // Android vendors may expose different XML parser feature sets.
        }
    }

    private static byte[] readEntry(ZipFile zip, String path) throws IOException {
        ZipEntry entry = zip.getEntry(path);
        if (entry == null) throw new IOException("EPUB 缺少文件: " + path);
        if (entry.getSize() > MAX_ENTRY_BYTES) throw new IOException("EPUB 内单个文件过大: " + path);
        try (InputStream input = zip.getInputStream(entry);
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[8192];
            int total = 0;
            int count;
            while ((count = input.read(buffer)) != -1) {
                total += count;
                if (total > MAX_ENTRY_BYTES) throw new IOException("EPUB 内单个文件过大: " + path);
                output.write(buffer, 0, count);
            }
            return output.toByteArray();
        }
    }

    private static String resolveEntry(String opfPath, String href) throws IOException {
        try {
            int slash = opfPath.lastIndexOf('/');
            String base = slash >= 0 ? opfPath.substring(0, slash + 1) : "";
            URI resolved = URI.create(base).resolve(href).normalize();
            String path = resolved.getPath();
            while (path.startsWith("/")) path = path.substring(1);
            if (path.startsWith("../") || path.contains("/../")) throw new IOException("EPUB 包含非法路径");
            return path;
        } catch (IllegalArgumentException e) {
            throw new IOException("EPUB 包含无效资源路径: " + href, e);
        }
    }

    private static String firstText(Document document, String localName) {
        NodeList nodes = document.getElementsByTagNameNS("*", localName);
        if (nodes.getLength() == 0) nodes = document.getElementsByTagName(localName);
        if (nodes.getLength() == 0) return "";
        return nodes.item(0).getTextContent().trim();
    }

    static String htmlToText(String html) {
        String text = HEAD.matcher(html).replaceAll("");
        text = SCRIPT_STYLE.matcher(text).replaceAll("");
        text = BLOCK_END.matcher(text).replaceAll("\n");
        text = TAG.matcher(text).replaceAll("");
        text = decodeEntities(text);
        text = text.replace("\r", "");
        text = text.replaceAll("[\\t\\x0B\\f ]+", " ");
        text = text.replaceAll(" *\\n *", "\n");
        text = text.replaceAll("\\n{3,}", "\n\n");
        return text.trim();
    }

    private static String extractSectionTitle(String html, String text, int index) {
        Matcher heading = HEADING.matcher(html);
        if (heading.find()) {
            String value = normalizeTitle(htmlToText(heading.group(1)));
            if (!value.isEmpty()) return value;
        }
        int newline = text.indexOf('\n');
        String firstLine = (newline >= 0 ? text.substring(0, newline) : text).trim();
        if (!firstLine.isEmpty() && firstLine.length() <= 60) return firstLine;
        return "章节 " + index;
    }

    private static String normalizeSectionText(String html, String text, String sectionTitle) {
        Matcher heading = HEADING.matcher(html);
        if (!heading.find()) return text;
        String rawHeading = htmlToText(heading.group(1));
        if (rawHeading.isEmpty()) return text;
        int headingStart = text.indexOf(rawHeading);
        if (headingStart < 0 || headingStart > 120) return text;
        String remainder = (text.substring(0, headingStart) +
                text.substring(headingStart + rawHeading.length())).trim();
        return remainder.isEmpty() ? sectionTitle : sectionTitle + "\n\n" + remainder;
    }

    private static String normalizeTitle(String value) {
        return value.replaceAll("\\s+", " ").trim();
    }

    private static String decodeEntities(String value) {
        Matcher matcher = ENTITY.matcher(value);
        StringBuffer result = new StringBuffer();
        while (matcher.find()) {
            String entity = matcher.group(1).toLowerCase(Locale.ROOT);
            String replacement;
            switch (entity) {
                case "amp": replacement = "&"; break;
                case "lt": replacement = "<"; break;
                case "gt": replacement = ">"; break;
                case "quot": replacement = "\""; break;
                case "apos": replacement = "'"; break;
                case "nbsp": replacement = " "; break;
                default:
                    try {
                        int radix = entity.startsWith("#x") ? 16 : 10;
                        int offset = entity.startsWith("#x") ? 2 : 1;
                        replacement = new String(Character.toChars(Integer.parseInt(entity.substring(offset), radix)));
                    } catch (RuntimeException e) {
                        replacement = matcher.group(0);
                    }
            }
            matcher.appendReplacement(result, Matcher.quoteReplacement(replacement));
        }
        matcher.appendTail(result);
        return result.toString();
    }

}
