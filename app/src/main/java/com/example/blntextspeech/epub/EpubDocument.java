package com.example.blntextspeech.epub;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public final class EpubDocument {
    private final String title;
    private final String author;
    private final List<String> sections;
    private final List<String> sectionTitles;

    public EpubDocument(String title, String author, List<String> sections) {
        this(title, author, sections, defaultTitles(sections));
    }

    public EpubDocument(String title, String author, List<String> sections, List<String> sectionTitles) {
        this.title = title;
        this.author = author;
        this.sections = Collections.unmodifiableList(new ArrayList<>(sections));
        this.sectionTitles = Collections.unmodifiableList(new ArrayList<>(sectionTitles));
    }

    public String getTitle() { return title; }
    public String getAuthor() { return author; }
    public List<String> getSections() { return sections; }
    public List<String> getSectionTitles() { return sectionTitles; }

    public String getReadingText() {
        StringBuilder result = new StringBuilder();
        for (String section : sections) {
            if (section == null || section.trim().isEmpty()) continue;
            if (result.length() > 0) result.append("\n\n");
            result.append(section.trim());
        }
        return result.toString();
    }

    private static List<String> defaultTitles(List<String> sections) {
        List<String> result = new ArrayList<>();
        for (int i = 0; i < sections.size(); i++) result.add("章节 " + (i + 1));
        return result;
    }
}
