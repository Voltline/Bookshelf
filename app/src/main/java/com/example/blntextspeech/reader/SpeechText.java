package com.example.blntextspeech.reader;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

public final class SpeechText {
    private SpeechText() {}

    public static List<String> chunk(String text, int maximumLength) {
        if (text == null || text.trim().isEmpty()) return Collections.emptyList();
        int limit = Math.max(100, maximumLength);
        List<String> chunks = new ArrayList<>();
        int start = 0;
        while (start < text.length()) {
            int end = Math.min(text.length(), start + limit);
            if (end < text.length()) {
                int preferred = findBreak(text, start, end);
                if (preferred > start) end = preferred;
            }
            String part = text.substring(start, end).trim();
            if (!part.isEmpty()) chunks.add(part);
            start = end;
            while (start < text.length() && Character.isWhitespace(text.charAt(start))) start++;
        }
        return chunks;
    }

    public static int continuationEnd(String nextPageText) {
        if (nextPageText == null) return -1;
        int separator = nextPageText.indexOf("\n\n");
        return separator > 0 ? separator : -1;
    }

    public static Continuation mergeContinuation(String currentSpeech,
                                                  String nextPageText,
                                                  boolean continuesToNext) {
        if (!continuesToNext) return new Continuation(currentSpeech, -1);
        int end = continuationEnd(nextPageText);
        if (end < 0) return new Continuation(currentSpeech, -1);
        int nextStart = end;
        while (nextStart < nextPageText.length() &&
                Character.isWhitespace(nextPageText.charAt(nextStart))) {
            nextStart++;
        }
        return new Continuation(currentSpeech + nextPageText.substring(0, end), nextStart);
    }

    private static int findBreak(String text, int start, int end) {
        int minimum = start + (end - start) / 2;
        String punctuation = "。！？；.!?;\n";
        for (int i = end - 1; i >= minimum; i--) {
            if (punctuation.indexOf(text.charAt(i)) >= 0) return i + 1;
        }
        for (int i = end - 1; i >= minimum; i--) {
            if (Character.isWhitespace(text.charAt(i))) return i + 1;
        }
        return end;
    }

    public static final class Continuation {
        private final String speechText;
        private final int nextPageStartOffset;

        Continuation(String speechText, int nextPageStartOffset) {
            this.speechText = speechText;
            this.nextPageStartOffset = nextPageStartOffset;
        }

        public String getSpeechText() {
            return speechText;
        }

        public int getNextPageStartOffset() {
            return nextPageStartOffset;
        }
    }
}
