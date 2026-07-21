package com.example.blntextspeech.reader;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.util.List;

public class SpeechTextTest {
    @Test
    public void chunksLongTextWithoutLosingCharacters() {
        String sentence = "第一句话。第二句话比较长，需要被分段。第三句话也要保留。";
        StringBuilder sourceBuilder = new StringBuilder();
        for (int i = 0; i < 8; i++) sourceBuilder.append(sentence);
        String source = sourceBuilder.toString();
        List<String> chunks = SpeechText.chunk(source, 100);
        assertTrue(chunks.size() > 1);
        for (String chunk : chunks) {
            assertFalse(chunk.isEmpty());
            assertTrue(chunk.length() <= 100);
        }
        assertEquals(source, String.join("", chunks));
    }

    @Test
    public void emptyTextProducesNoSpeech() {
        assertTrue(SpeechText.chunk("  \n", 4000).isEmpty());
    }

    @Test
    public void findsEndOfParagraphContinuedOnNextPage() {
        String nextPage = "上一页未结束的续文。\n\n下一段从这里开始。";
        int end = SpeechText.continuationEnd(nextPage);

        assertEquals("上一页未结束的续文。", nextPage.substring(0, end));
        assertEquals(-1, SpeechText.continuationEnd("整页都是同一个长段落"));
    }

    @Test
    public void mergesCrossPageParagraphWithoutRepeatingItOnNextPage() {
        String nextPage = "跨页段落的后半部分。\n\n下一段直接开始。";
        SpeechText.Continuation result = SpeechText.mergeContinuation(
                "跨页段落的前半部分，", nextPage, true);

        assertEquals("跨页段落的前半部分，跨页段落的后半部分。", result.getSpeechText());
        assertEquals("下一段直接开始。",
                nextPage.substring(result.getNextPageStartOffset()));
    }
}
