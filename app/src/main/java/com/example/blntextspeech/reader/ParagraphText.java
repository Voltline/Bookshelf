package com.example.blntextspeech.reader;

public final class ParagraphText {
    private ParagraphText() {}

    public static int paragraphStart(String text, int offset) {
        if (text == null || text.isEmpty()) return 0;
        int safeOffset = Math.max(0, Math.min(offset, text.length() - 1));
        int separator = text.lastIndexOf("\n\n", safeOffset);
        int start = separator < 0 ? 0 : separator + 2;
        while (start < text.length() && Character.isWhitespace(text.charAt(start))) start++;
        return start;
    }

    public static int paragraphEnd(String text, int offset) {
        if (text == null || text.isEmpty()) return 0;
        int safeOffset = Math.max(0, Math.min(offset, text.length() - 1));
        int separator = text.indexOf("\n\n", safeOffset);
        int end = separator < 0 ? text.length() : separator;
        while (end > 0 && Character.isWhitespace(text.charAt(end - 1))) end--;
        return Math.max(paragraphStart(text, safeOffset), end);
    }
}
