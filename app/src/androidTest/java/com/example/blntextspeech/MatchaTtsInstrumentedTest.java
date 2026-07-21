package com.example.blntextspeech;

import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import android.content.Context;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;

import com.example.blntextspeech.tts.MatchaSpeechController;

import org.junit.Test;
import org.junit.runner.RunWith;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

@RunWith(AndroidJUnit4.class)
public class MatchaTtsInstrumentedTest {
    @Test
    public void bundledModelInitializesAndSynthesizesChinese() throws Exception {
        Context context = InstrumentationRegistry.getInstrumentation().getTargetContext();
        CountDownLatch ready = new CountDownLatch(1);
        CountDownLatch completed = new CountDownLatch(1);
        AtomicReference<String> error = new AtomicReference<>();
        String utteranceId = "bundled-matcha-smoke";

        MatchaSpeechController controller = new MatchaSpeechController(context,
                new MatchaSpeechController.Listener() {
                    @Override public void onReady() {
                        ready.countDown();
                    }

                    @Override public void onStart(String id) {}

                    @Override public void onDone(String id) {
                        if (utteranceId.equals(id)) completed.countDown();
                    }

                    @Override public void onError(String id, String message) {
                        error.set(message);
                        ready.countDown();
                        completed.countDown();
                    }
                });
        try {
            controller.initialize();
            assertTrue("Timed out extracting or initializing bundled Matcha Baker",
                    ready.await(120, TimeUnit.SECONDS));
            assertNull("Bundled Matcha initialization failed: " + error.get(), error.get());
            assertTrue(controller.isReady());
            assertTrue(controller.speak("你好，这里是白蓝鸟书架。", true, utteranceId));
            assertTrue("Timed out synthesizing bundled Matcha speech",
                    completed.await(120, TimeUnit.SECONDS));
            assertNull("Bundled Matcha synthesis failed: " + error.get(), error.get());
        } finally {
            controller.shutdown();
        }
    }
}
