package com.example.blntextspeech.reader;

import android.text.TextPaint;

import java.util.ArrayList;
import java.util.List;

public final class TextPaginator {
    private TextPaginator() {}

    public static List<String> paginate(String source, TextPaint paint, int width, int height,
                                        float lineSpacingExtra, float lineSpacingMultiplier) {
        List<String> result = new ArrayList<>();
        for (Page page : paginateDetailed(source, paint, width, height,
                lineSpacingExtra, lineSpacingMultiplier)) {
            result.add(page.getText());
        }
        return result;
    }

    public static List<Page> paginateDetailed(String source, TextPaint paint, int width, int height,
                                               float lineSpacingExtra, float lineSpacingMultiplier) {
        List<Page> pages = new ArrayList<>();
        if (source == null || source.trim().isEmpty() || width <= 0 || height <= 0) return pages;
        float cjkWidth = Math.max(1f, paint.measureText(new char[]{'\u6c49'}, 0, 1));
        float latinWidth = Math.max(1f, paint.measureText(new char[]{'n'}, 0, 1));
        float spaceWidth = Math.max(1f, paint.measureText(new char[]{' '}, 0, 1));
        float lineHeight = Math.max(1f,
                (paint.getFontMetrics().descent - paint.getFontMetrics().ascent)
                        * lineSpacingMultiplier + lineSpacingExtra);
        int maximumLines = Math.max(1, (int) Math.floor(height / lineHeight) - 1);
        float usableWidth = width * 0.97f;
        int pageStart = 0;
        int index = 0;
        int line = 1;
        float usedWidth = 0f;
        while (index < source.length()) {
            char value = source.charAt(index);
            if (value == '\n') {
                index++;
                if (line >= maximumLines) {
                    addPage(pages, source, pageStart, index);
                    pageStart = index;
                    line = 1;
                } else {
                    line++;
                }
                usedWidth = 0f;
                continue;
            }

            float characterWidth;
            if (value == ' ' || value == '\t') characterWidth = spaceWidth;
            else if (value < 128) characterWidth = latinWidth;
            else if (Character.isHighSurrogate(value)) characterWidth = cjkWidth * 2f;
            else characterWidth = cjkWidth;

            if (usedWidth > 0f && usedWidth + characterWidth > usableWidth) {
                if (line >= maximumLines) {
                    addPage(pages, source, pageStart, index);
                    pageStart = index;
                    line = 1;
                } else {
                    line++;
                }
                usedWidth = 0f;
            }
            usedWidth += characterWidth;
            index++;
        }
        addPage(pages, source, pageStart, source.length());
        return pages;
    }

    private static void addPage(List<Page> pages, String source, int start, int end) {
        if (end <= start) return;
        String page = source.substring(start, end).trim();
        if (!page.isEmpty()) {
            pages.add(new Page(page, end < source.length() &&
                    !isParagraphBoundary(source, end)));
        }
    }

    private static boolean isParagraphBoundary(String source, int index) {
        int start = Math.max(0, index - 2);
        int end = Math.min(source.length(), index + 2);
        return source.substring(start, end).contains("\n\n");
    }

    public static final class Page {
        private final String text;
        private final boolean continuesToNext;

        Page(String text, boolean continuesToNext) {
            this.text = text;
            this.continuesToNext = continuesToNext;
        }

        public String getText() {
            return text;
        }

        public boolean continuesToNext() {
            return continuesToNext;
        }
    }
}
