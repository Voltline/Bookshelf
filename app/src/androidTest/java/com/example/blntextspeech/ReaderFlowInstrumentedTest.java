package com.example.blntextspeech;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotEquals;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.os.SystemClock;
import android.text.PrecomputedText;
import android.text.Spanned;
import android.text.style.ForegroundColorSpan;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;

import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import androidx.fragment.app.Fragment;

import com.example.blntextspeech.data.BookRepository;
import com.example.blntextspeech.model.Book;

import org.junit.Test;
import org.junit.runner.RunWith;

import java.util.concurrent.atomic.AtomicReference;

@RunWith(AndroidJUnit4.class)
public class ReaderFlowInstrumentedTest {
    @Test
    public void importsOpensPaginatesAndInitializesSpeech() throws Exception {
        Context target = InstrumentationRegistry.getInstrumentation().getTargetContext();
        Book book = BookRepository.get(target).importBook(TestEpubProvider.BOOK_URI);
        assertEquals("听读自动化测试书", book.getTitle());
        assertEquals("设备测试", book.getAuthor());

        Intent intent = new Intent(target, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        Activity activity = InstrumentationRegistry.getInstrumentation().startActivitySync(intent);
        assertNotNull(activity);

        waitUntil(() -> findText(activity.getWindow().getDecorView(), book.getTitle()) != null, 5_000);
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            View title = findText(activity.getWindow().getDecorView(), book.getTitle());
            View clickable = title;
            while (clickable != null && !clickable.isClickable()) {
                clickable = clickable.getParent() instanceof View ? (View) clickable.getParent() : null;
            }
            assertNotNull(clickable);
            clickable.performClick();
        });

        waitUntil(() -> {
            TextView indicator = activity.findViewById(R.id.page_indicator);
            return indicator != null && indicator.getVisibility() == View.VISIBLE && indicator.getText().length() > 0;
        }, 10_000);

        TextView indicator = activity.findViewById(R.id.page_indicator);
        selectReadingMode(activity, SecondFragment.ReadingMode.PAGE);
        String firstPage = indicator.getText().toString();
        assertTrue(firstPage.contains("/"));
        View next = activity.findViewById(R.id.next_button);
        assertTrue(next.isEnabled());
        InstrumentationRegistry.getInstrumentation().runOnMainSync(next::performClick);
        assertNotEquals(firstPage, indicator.getText().toString());
        TextView pageText = activity.findViewById(R.id.page_text);
        TextView pageUnderlay = activity.findViewById(R.id.page_underlay);
        waitUntil(() -> pageUnderlay.getVisibility() == View.VISIBLE &&
                pageUnderlay.length() > 0, 1_000);
        waitUntil(() -> Math.abs(pageText.getTranslationX()) > 1f || pageText.getAlpha() < 0.99f,
                1_000);
        waitUntil(() -> Math.abs(pageText.getTranslationX()) < 1f && pageText.getAlpha() > 0.99f,
                2_000);
        assertEquals(View.GONE, pageUnderlay.getVisibility());

        selectReadingMode(activity, SecondFragment.ReadingMode.SCROLL);
        RecyclerView verticalPages = activity.findViewById(R.id.vertical_recycler);
        waitUntil(() -> verticalPages.getVisibility() == View.VISIBLE &&
                verticalPages.getAdapter() != null && verticalPages.getChildCount() >= 1, 2_000);
        assertTrue(verticalPages.getLayoutManager() instanceof LinearLayoutManager);
        assertTrue(verticalPages.getAdapter().hasStableIds());
        assertTrue(verticalPages.getAdapter().getItemCount() >= 2);
        assertEquals(ViewGroup.LayoutParams.WRAP_CONTENT,
                verticalPages.getChildAt(0).getLayoutParams().height);
        waitUntil(() -> hasPrecomputedVisiblePage(verticalPages), 3_000);
        assertEquals(View.GONE, pageText.getVisibility());
        String pageBeforeScroll = indicator.getText().toString();
        SystemClock.sleep(300);
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() ->
                verticalPages.scrollBy(0, verticalPages.getHeight()));
        waitUntil(() -> !pageBeforeScroll.contentEquals(indicator.getText()), 2_000);
        selectReadingMode(activity, SecondFragment.ReadingMode.PAGE);

        View read = activity.findViewById(R.id.read_button);
        waitUntil(read::isEnabled, 8_000);
        assertTrue(read.isEnabled());
        com.google.android.material.materialswitch.MaterialSwitch pauseOnExit =
                activity.findViewById(R.id.pause_on_exit_switch);
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() ->
                pauseOnExit.setChecked(false));
        InstrumentationRegistry.getInstrumentation().runOnMainSync(read::performClick);
        TextView readText = (TextView) read;
        assertEquals(target.getString(R.string.pause_reading), readText.getText().toString());
        waitUntil(() -> pageText.getText() instanceof Spanned &&
                ((Spanned) pageText.getText()).getSpans(0, pageText.length(),
                        ForegroundColorSpan.class).length > 0, 8_000);
        SecondFragment reader = findReader(
                ((MainActivity) activity).getSupportFragmentManager().getFragments());
        assertNotNull(reader);
        int generationBeforeManualPage = readPrivateInt(reader, "speechGeneration");
        String pageBeforeManualChange = indicator.getText().toString();
        assertTrue(next.isEnabled());
        InstrumentationRegistry.getInstrumentation().runOnMainSync(next::performClick);
        waitUntil(() -> !pageBeforeManualChange.contentEquals(indicator.getText()), 2_000);
        assertEquals(generationBeforeManualPage, readPrivateInt(reader, "speechGeneration"));
        assertEquals(target.getString(R.string.pause_reading), readText.getText().toString());
        InstrumentationRegistry.getInstrumentation().runOnMainSync(read::performClick);
        assertEquals(target.getString(R.string.start_reading), readText.getText().toString());

        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            pauseOnExit.setChecked(true);
            read.performClick();
        });
        assertEquals(target.getString(R.string.pause_reading), readText.getText().toString());
        long eventTime = SystemClock.uptimeMillis();
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() -> {
            pageText.dispatchTouchEvent(MotionEvent.obtain(eventTime, eventTime,
                    MotionEvent.ACTION_DOWN, 2f, pageText.getHeight() / 2f, 0));
            pageText.dispatchTouchEvent(MotionEvent.obtain(eventTime, eventTime + 50,
                    MotionEvent.ACTION_UP, 2f, pageText.getHeight() / 2f, 0));
        });
        waitUntil(() -> target.getString(R.string.start_reading)
                .contentEquals(readText.getText()), 2_000);
        assertFalse(activity.isFinishing());

        InstrumentationRegistry.getInstrumentation().runOnMainSync(activity::finish);
    }

    private static boolean hasPrecomputedVisiblePage(RecyclerView recyclerView) {
        for (int i = 0; i < recyclerView.getChildCount(); i++) {
            View child = recyclerView.getChildAt(i);
            if (child instanceof TextView &&
                    ((TextView) child).getText() instanceof PrecomputedText) return true;
        }
        return false;
    }

    private static TextView findText(View root, String text) {
        if (root instanceof TextView && text.contentEquals(((TextView) root).getText())) return (TextView) root;
        if (root instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) root;
            for (int i = 0; i < group.getChildCount(); i++) {
                TextView found = findText(group.getChildAt(i), text);
                if (found != null) return found;
            }
        }
        return null;
    }

    private static void selectReadingMode(Activity activity, SecondFragment.ReadingMode mode)
            throws Exception {
        SecondFragment reader = findReader(
                ((MainActivity) activity).getSupportFragmentManager().getFragments());
        assertNotNull(reader);
        InstrumentationRegistry.getInstrumentation().runOnMainSync(() ->
                reader.selectReadingMode(mode));
        TextView button = activity.findViewById(R.id.reading_mode_button);
        String expected = activity.getString(mode == SecondFragment.ReadingMode.PAGE
                ? R.string.reading_mode_page_short : R.string.reading_mode_scroll_short);
        waitUntil(() -> expected.contentEquals(button.getText()), 2_000);
    }

    private static SecondFragment findReader(java.util.List<Fragment> fragments) {
        for (Fragment fragment : fragments) {
            if (fragment instanceof SecondFragment) return (SecondFragment) fragment;
            SecondFragment nested = findReader(fragment.getChildFragmentManager().getFragments());
            if (nested != null) return nested;
        }
        return null;
    }

    private static int readPrivateInt(Object target, String fieldName) throws Exception {
        java.lang.reflect.Field field = target.getClass().getDeclaredField(fieldName);
        field.setAccessible(true);
        return field.getInt(target);
    }

    private static void waitUntil(Check check, long timeoutMillis) throws Exception {
        long deadline = SystemClock.uptimeMillis() + timeoutMillis;
        AtomicReference<Throwable> error = new AtomicReference<>();
        while (SystemClock.uptimeMillis() < deadline) {
            try {
                if (check.evaluate()) return;
            } catch (Throwable throwable) {
                error.set(throwable);
            }
            SystemClock.sleep(100);
        }
        if (error.get() != null) throw new AssertionError(error.get());
        throw new AssertionError("Timed out waiting for UI state");
    }

    private interface Check { boolean evaluate() throws Exception; }
}
