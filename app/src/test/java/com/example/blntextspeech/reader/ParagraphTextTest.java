package com.example.blntextspeech.reader;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

public class ParagraphTextTest {
    @Test
    public void findsBeginningOfTappedParagraph() {
        String text = "标题\n\n第一段文字。\n\n  第二段文字。";

        assertEquals(0, ParagraphText.paragraphStart(text, 1));
        assertEquals(4, ParagraphText.paragraphStart(text, 8));
        assertEquals(14, ParagraphText.paragraphStart(text, text.length() - 2));
    }

    @Test
    public void clampsOffsetsAndHandlesEmptyText() {
        assertEquals(0, ParagraphText.paragraphStart("", 10));
        assertEquals(0, ParagraphText.paragraphStart("一段文字", -5));
        assertEquals(0, ParagraphText.paragraphStart("一段文字", 100));
    }

    @Test
    public void findsParagraphEnd() {
        String text = "第一段\n\n第二段文字\n\n第三段";
        assertEquals(3, ParagraphText.paragraphEnd(text, 1));
        assertEquals(10, ParagraphText.paragraphEnd(text, 7));
        assertEquals(text.length(), ParagraphText.paragraphEnd(text, text.length() - 1));
        assertEquals(0, ParagraphText.paragraphEnd("", 3));
    }
}
