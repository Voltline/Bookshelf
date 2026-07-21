package com.example.blntextspeech;

import android.content.Context;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.speech.tts.TextToSpeech;
import android.speech.tts.UtteranceProgressListener;
import android.graphics.Typeface;
import android.text.PrecomputedText;
import android.text.SpannableString;
import android.text.Spanned;
import android.text.TextPaint;
import android.text.Layout;
import android.text.style.ForegroundColorSpan;
import android.text.style.RelativeSizeSpan;
import android.text.style.StyleSpan;
import android.util.LruCache;
import android.view.GestureDetector;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.LayoutInflater;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.animation.AccelerateInterpolator;
import android.view.animation.DecelerateInterpolator;
import android.widget.TextView;
import android.widget.Toast;

import androidx.annotation.NonNull;
import androidx.appcompat.app.AlertDialog;
import androidx.core.content.ContextCompat;
import androidx.fragment.app.Fragment;
import androidx.recyclerview.widget.LinearLayoutManager;
import androidx.recyclerview.widget.RecyclerView;

import com.example.blntextspeech.data.BookRepository;
import com.example.blntextspeech.databinding.FragmentSecondBinding;
import com.example.blntextspeech.epub.EpubDocument;
import com.example.blntextspeech.model.Book;
import com.example.blntextspeech.reader.ParagraphText;
import com.example.blntextspeech.reader.SpeechText;
import com.example.blntextspeech.reader.TextPaginator;
import com.example.blntextspeech.tts.MatchaSpeechController;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class SecondFragment extends Fragment {
    public static final String ARG_BOOK_ID = "bookId";
    private static final int SPEECH_LOOKAHEAD_PAGES = 2;
    private static final int MATCHA_CHUNK_LENGTH = 100;
    private static final String READER_DISPLAY_PREFERENCES = "reader_display";
    private static final int VERTICAL_PAGE_CACHE_SIZE = 5;
    private static final long PROGRESS_SAVE_DELAY_MS = 600;
    private static final Object PAYLOAD_HIGHLIGHT = new Object();
    private static final Object PAYLOAD_PRECOMPUTED_TEXT = new Object();

    private FragmentSecondBinding binding;
    private BookRepository repository;
    private Book book;
    private final List<String> pages = new ArrayList<>();
    private final List<Boolean> pageContinuesToNext = new ArrayList<>();
    private final List<String> chapterTitles = new ArrayList<>();
    private final List<Integer> chapterStartPages = new ArrayList<>();
    private ExecutorService worker;
    private ExecutorService textLayoutWorker;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final Handler progressHandler = new Handler(Looper.getMainLooper());
    private final LruCache<Integer, PrecomputedText> precomputedPages =
            new LruCache<>(VERTICAL_PAGE_CACHE_SIZE + 4);
    private final Set<Long> precomputedPagesInFlight = new HashSet<>();
    private PrecomputedText.Params precomputedTextParams;
    private volatile int textLayoutGeneration;
    private VerticalPageAdapter verticalAdapter;
    private LinearLayoutManager verticalLayoutManager;
    private boolean verticalPositioning;
    private int pendingProgressPage = -1;
    private Runnable progressSaveRunnable;
    private TextToSpeech textToSpeech;
    private MatchaSpeechController matchaSpeech;
    private boolean systemTtsReady;
    private boolean matchaReady;
    private boolean matchaInitializing;
    private VoiceEngine voiceEngine = VoiceEngine.SYSTEM;
    private int ttsInitializationGeneration;
    private boolean reading;
    private int currentPage;
    private int speechGeneration;
    private int speechStartOffset;
    private int speechPage = -1;
    private int highlightedPage = -1;
    private int highlightedStart = -1;
    private int highlightedEnd = -1;
    private int queuedThroughPage = -1;
    private final Map<String, QueuedUtterance> queuedUtterances = new HashMap<>();
    private final Map<Integer, Integer> queuedPageStartOffsets = new HashMap<>();
    private boolean chromeVisible;
    private ReadingMode readingMode = ReadingMode.PAGE;
    private boolean pageAnimating;
    private boolean pauseReadingOnExit = true;

    @Override
    public void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        repository = BookRepository.get(requireContext());
        worker = Executors.newSingleThreadExecutor();
        textLayoutWorker = Executors.newFixedThreadPool(2);
        progressSaveRunnable = this::persistPendingProgress;
        String savedMode = requireContext().getSharedPreferences(
                        READER_DISPLAY_PREFERENCES, Context.MODE_PRIVATE)
                .getString("mode", ReadingMode.PAGE.name());
        try {
            readingMode = ReadingMode.valueOf(savedMode);
        } catch (IllegalArgumentException ignored) {
            readingMode = ReadingMode.PAGE;
        }
        pauseReadingOnExit = requireContext().getSharedPreferences(
                        READER_DISPLAY_PREFERENCES, Context.MODE_PRIVATE)
                .getBoolean("pause_on_exit", true);
        String savedEngine = requireContext().getSharedPreferences("reader_voice", Context.MODE_PRIVATE)
                .getString("engine", VoiceEngine.SYSTEM.name());
        try {
            voiceEngine = VoiceEngine.valueOf(savedEngine);
        } catch (IllegalArgumentException ignored) {
            voiceEngine = VoiceEngine.SYSTEM;
            requireContext().getSharedPreferences("reader_voice", Context.MODE_PRIVATE)
                    .edit().putString("engine", VoiceEngine.SYSTEM.name()).apply();
        }
        initializeSystemTextToSpeech();
        if (voiceEngine == VoiceEngine.MATCHA_BAKER) initializeMatcha();
        if (savedInstanceState != null) currentPage = savedInstanceState.getInt("currentPage", 0);
    }

    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, ViewGroup container, Bundle savedInstanceState) {
        binding = FragmentSecondBinding.inflate(inflater, container, false);
        return binding.getRoot();
    }

    @Override
    public void onViewCreated(@NonNull View view, Bundle savedInstanceState) {
        super.onViewCreated(view, savedInstanceState);
        MainActivity activity = (MainActivity) requireActivity();
        activity.setReaderMode(true);
        activity.setReaderKeyHandler(this::handleReaderKey);
        binding.previousButton.setOnClickListener(v -> changePage(-1, true));
        binding.nextButton.setOnClickListener(v -> changePage(1, true));
        binding.readButton.setOnClickListener(v -> toggleReading());
        binding.voiceButton.setOnClickListener(v -> showVoiceEngineDialog());
        binding.readingModeButton.setOnClickListener(v -> showReadingModeDialog());
        binding.backButton.setOnClickListener(v ->
                requireActivity().getOnBackPressedDispatcher().onBackPressed());
        binding.chapterButton.setOnClickListener(v -> showChapterDirectory());
        binding.pauseOnExitSwitch.setChecked(pauseReadingOnExit);
        binding.pauseOnExitSwitch.setOnCheckedChangeListener((button, checked) -> {
            pauseReadingOnExit = checked;
            requireContext().getSharedPreferences(
                            READER_DISPLAY_PREFERENCES, Context.MODE_PRIVATE)
                    .edit().putBoolean("pause_on_exit", checked).apply();
        });
        setupVerticalRecycler();

        GestureDetector detector = new GestureDetector(requireContext(), new GestureDetector.SimpleOnGestureListener() {
            @Override public boolean onDown(@NonNull MotionEvent e) { return true; }

            @Override
            public boolean onSingleTapConfirmed(@NonNull MotionEvent e) {
                if (readingMode != ReadingMode.PAGE) return false;
                int textOffset = reading ? findTextOffsetAt(e) : -1;
                if (textOffset >= 0) {
                    startReadingAt(currentPage, textOffset);
                    setChromeVisible(false);
                } else {
                    setChromeVisible(!chromeVisible);
                }
                return true;
            }

            @Override
            public boolean onFling(MotionEvent first, MotionEvent second, float velocityX, float velocityY) {
                if (readingMode != ReadingMode.PAGE) return false;
                if (first == null || second == null) return false;
                float distance = second.getX() - first.getX();
                if (Math.abs(distance) < dp(60) || Math.abs(velocityX) < 250) return false;
                changePage(distance < 0 ? 1 : -1, true);
                return true;
            }
        });
        binding.pageText.setOnTouchListener((v, event) -> detector.onTouchEvent(event));

        GestureDetector verticalDetector = new GestureDetector(requireContext(),
                new GestureDetector.SimpleOnGestureListener() {
                    @Override public boolean onDown(@NonNull MotionEvent e) { return true; }

                    @Override public boolean onSingleTapConfirmed(@NonNull MotionEvent e) {
                        if (readingMode != ReadingMode.SCROLL) return false;
                        VerticalTextLocation location = findVerticalTextLocation(e);
                        if (reading && location != null) {
                            if (currentPage != location.page) {
                                currentPage = location.page;
                                updatePageMetadata();
                            }
                            startReadingAt(location.page, location.textOffset);
                            setChromeVisible(false);
                        } else {
                            setChromeVisible(!chromeVisible);
                        }
                        return true;
                    }
                });
        binding.verticalRecycler.setOnTouchListener((v, event) -> {
            verticalDetector.onTouchEvent(event);
            return false;
        });
        updateReadingModeButton();
        loadBook();
    }

    private void setupVerticalRecycler() {
        precomputedTextParams = binding.pageText.getTextMetricsParams();
        verticalLayoutManager = new LinearLayoutManager(requireContext(),
                RecyclerView.VERTICAL, false);
        verticalLayoutManager.setInitialPrefetchItemCount(VERTICAL_PAGE_CACHE_SIZE);
        verticalAdapter = new VerticalPageAdapter();
        binding.verticalRecycler.setLayoutManager(verticalLayoutManager);
        binding.verticalRecycler.setAdapter(verticalAdapter);
        binding.verticalRecycler.setHasFixedSize(false);
        binding.verticalRecycler.setItemViewCacheSize(VERTICAL_PAGE_CACHE_SIZE);
        binding.verticalRecycler.getRecycledViewPool().setMaxRecycledViews(
                VerticalPageAdapter.VIEW_TYPE_PAGE, VERTICAL_PAGE_CACHE_SIZE);
        binding.verticalRecycler.setItemAnimator(null);
        binding.verticalRecycler.addOnScrollListener(new RecyclerView.OnScrollListener() {
            @Override
            public void onScrolled(@NonNull RecyclerView recyclerView, int dx, int dy) {
                updateCurrentPageFromVerticalList();
            }

            @Override
            public void onScrollStateChanged(@NonNull RecyclerView recyclerView, int newState) {
                if (newState == RecyclerView.SCROLL_STATE_IDLE) {
                    updateCurrentPageFromVerticalList();
                }
            }
        });
    }

    private void loadBook() {
        String id = getArguments() == null ? null : getArguments().getString(ARG_BOOK_ID);
        book = id == null ? null : repository.getBook(id);
        if (book == null) {
            showFatalError(getString(R.string.book_not_found));
            return;
        }
        requireActivity().setTitle(book.getTitle());
        binding.readerTitle.setText(book.getTitle());
        binding.loading.setVisibility(View.VISIBLE);
        updateVoiceButton();
        setChromeVisible(false);
        worker.execute(() -> {
            try {
                EpubDocument document = repository.read(book);
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> preparePagination(document));
            } catch (Exception error) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> showFatalError(
                        error.getMessage() == null ? getString(R.string.read_failed) : error.getMessage()));
            }
        });
    }

    private void preparePagination(EpubDocument document) {
        if (binding == null) return;
        binding.pageText.post(() -> {
            if (binding == null) return;
            int width = binding.pageText.getWidth() - binding.pageText.getPaddingLeft() - binding.pageText.getPaddingRight();
            int height = binding.pageText.getHeight() - binding.pageText.getPaddingTop() - binding.pageText.getPaddingBottom();
            if (width <= 0 || height <= 0) {
                binding.pageText.postDelayed(() -> preparePagination(document), 100);
                return;
            }
            TextPaint paint = new TextPaint(binding.pageText.getPaint());
            float lineSpacingExtra = dp(6);
            worker.execute(() -> {
                try {
                    List<String> result = new ArrayList<>();
                    List<Boolean> continuations = new ArrayList<>();
                    List<String> titles = new ArrayList<>();
                    List<Integer> starts = new ArrayList<>();
                    List<String> sections = document.getSections();
                    List<String> sourceTitles = document.getSectionTitles();
                    for (int i = 0; i < sections.size(); i++) {
                        List<TextPaginator.Page> sectionPages = TextPaginator.paginateDetailed(
                                sections.get(i), paint, width, height, lineSpacingExtra, 1.15f);
                        if (sectionPages.isEmpty()) continue;
                        starts.add(result.size());
                        titles.add(i < sourceTitles.size() ? sourceTitles.get(i) :
                                getString(R.string.chapter_number, titles.size() + 1));
                        for (TextPaginator.Page sectionPage : sectionPages) {
                            result.add(sectionPage.getText());
                            continuations.add(sectionPage.continuesToNext());
                        }
                    }
                    if (!isAdded()) return;
                    ReaderPagination pagination = new ReaderPagination(
                            result, continuations, titles, starts);
                    requireActivity().runOnUiThread(() -> applyPagination(pagination));
                } catch (Exception error) {
                    if (!isAdded()) return;
                    requireActivity().runOnUiThread(() -> showFatalError(
                            error.getMessage() == null ? getString(R.string.read_failed) : error.getMessage()));
                }
            });
        });
    }

    private void applyPagination(ReaderPagination result) {
        if (binding == null) return;
        textLayoutGeneration++;
        synchronized (precomputedPages) {
            precomputedPages.evictAll();
            precomputedPagesInFlight.clear();
        }
        pages.clear();
        pages.addAll(result.pages);
        pageContinuesToNext.clear();
        pageContinuesToNext.addAll(result.pageContinuesToNext);
        chapterTitles.clear();
        chapterTitles.addAll(result.chapterTitles);
        chapterStartPages.clear();
        chapterStartPages.addAll(result.chapterStartPages);
        if (pages.isEmpty()) {
            showFatalError(getString(R.string.empty_book));
            return;
        }
        if (currentPage == 0) currentPage = Math.min(book.getLastPage(), pages.size() - 1);
        currentPage = Math.max(0, Math.min(currentPage, pages.size() - 1));
        binding.loading.setVisibility(View.GONE);
        if (verticalAdapter != null) verticalAdapter.notifyDataSetChanged();
        renderPage();
    }

    private void setChromeVisible(boolean visible) {
        boolean leavingImmersive = !chromeVisible && visible;
        chromeVisible = visible;
        if (binding == null) return;
        binding.topControls.setVisibility(visible ? View.VISIBLE : View.GONE);
        binding.controls.setVisibility(visible ? View.VISIBLE : View.GONE);
        if (leavingImmersive && pauseReadingOnExit && reading) stopReading();
    }

    private void showReadingModeDialog() {
        String[] modes = {
                getString(R.string.reading_mode_page),
                getString(R.string.reading_mode_scroll)
        };
        int selected = readingMode == ReadingMode.PAGE ? 0 : 1;
        new AlertDialog.Builder(requireContext())
                .setTitle(R.string.reading_mode)
                .setSingleChoiceItems(modes, selected, (dialog, which) -> {
                    dialog.dismiss();
                    selectReadingMode(which == 0 ? ReadingMode.PAGE : ReadingMode.SCROLL);
                })
                .show();
    }

    void selectReadingMode(ReadingMode mode) {
        if (readingMode == mode) return;
        readingMode = mode;
        requireContext().getSharedPreferences(READER_DISPLAY_PREFERENCES, Context.MODE_PRIVATE)
                .edit().putString("mode", mode.name()).apply();
        pageAnimating = false;
        if (binding != null) {
            resetPageAnimationViews();
        }
        updateReadingModeButton();
        renderPage();
        setChromeVisible(false);
    }

    private void updateReadingModeButton() {
        if (binding == null) return;
        binding.readingModeButton.setText(readingMode == ReadingMode.PAGE
                ? R.string.reading_mode_page_short : R.string.reading_mode_scroll_short);
    }

    private void showVoiceEngineDialog() {
        String[] engines = {
                getString(R.string.voice_system),
                getString(R.string.voice_matcha_baker)
        };
        int selected = voiceEngine == VoiceEngine.MATCHA_BAKER ? 1 : 0;
        new AlertDialog.Builder(requireContext())
                .setTitle(R.string.voice_engine)
                .setSingleChoiceItems(engines, selected, (dialog, which) -> {
                    dialog.dismiss();
                    if (which == 0) selectVoiceEngine(VoiceEngine.SYSTEM);
                    else selectVoiceEngine(VoiceEngine.MATCHA_BAKER);
                })
                .show();
    }

    private void selectVoiceEngine(VoiceEngine engine) {
        if (voiceEngine == engine && isSpeechReady()) return;
        if (reading) stopReading();
        voiceEngine = engine;
        saveVoiceEngine();
        updateVoiceButton();
        if (engine == VoiceEngine.MATCHA_BAKER) initializeMatcha();
        updateSpeechAvailability();
    }

    private void saveVoiceEngine() {
        requireContext().getSharedPreferences("reader_voice", Context.MODE_PRIVATE)
                .edit().putString("engine", voiceEngine.name()).apply();
    }

    private void initializeSystemTextToSpeech() {
        systemTtsReady = false;
        int generation = ++ttsInitializationGeneration;
        if (textToSpeech != null) {
            textToSpeech.shutdown();
            textToSpeech = null;
        }
        Context appContext = requireContext().getApplicationContext();
        TextToSpeech.OnInitListener listener = status ->
                onTextToSpeechInitialized(generation, status);
        textToSpeech = new TextToSpeech(appContext, listener);
    }

    private void initializeMatcha() {
        if (matchaReady || matchaInitializing) return;
        matchaInitializing = true;
        updateSpeechAvailability();
        if (isAdded()) Toast.makeText(requireContext(),
                R.string.matcha_preparing, Toast.LENGTH_LONG).show();
        matchaSpeech = new MatchaSpeechController(requireContext(),
                new MatchaSpeechController.Listener() {
                    @Override public void onReady() {
                        matchaInitializing = false;
                        matchaReady = true;
                        updateSpeechAvailability();
                        if (isAdded()) Toast.makeText(requireContext(),
                                R.string.matcha_ready, Toast.LENGTH_SHORT).show();
                    }

                    @Override public void onStart(String utteranceId) {
                        onUtteranceStarted(utteranceId);
                    }

                    @Override public void onDone(String utteranceId) {
                        onUtteranceFinished(utteranceId);
                    }

                    @Override public void onError(String utteranceId, String message) {
                        if (utteranceId == null) handleMatchaInitializationFailure(message);
                        else onUtteranceError(utteranceId, message);
                    }
                });
        matchaSpeech.initialize();
    }

    private void updateVoiceButton() {
        if (binding != null) binding.voiceButton.setText(
                voiceEngine == VoiceEngine.MATCHA_BAKER
                        ? R.string.voice_matcha_short : R.string.voice_system);
    }

    private boolean isSpeechReady() {
        return voiceEngine == VoiceEngine.MATCHA_BAKER ? matchaReady : systemTtsReady;
    }

    private void updateSpeechAvailability() {
        if (binding != null) binding.readButton.setEnabled(isSpeechReady() && !pages.isEmpty());
    }

    private void showChapterDirectory() {
        if (chapterTitles.isEmpty()) return;
        String[] items = chapterTitles.toArray(new String[0]);
        int selected = findCurrentChapter();
        AlertDialog dialog = new AlertDialog.Builder(requireContext())
                .setTitle(R.string.chapter_directory)
                .setSingleChoiceItems(items, selected, null)
                .create();
        dialog.setOnShowListener(ignored -> dialog.getListView().setOnItemClickListener(
                (parent, view, position, id) -> {
                    jumpToChapter(position);
                    dialog.dismiss();
                }));
        dialog.show();
    }

    private int findCurrentChapter() {
        int low = 0;
        int high = chapterStartPages.size() - 1;
        while (low <= high) {
            int middle = (low + high) >>> 1;
            if (chapterStartPages.get(middle) <= currentPage) low = middle + 1;
            else high = middle - 1;
        }
        return Math.max(0, high);
    }

    private void jumpToChapter(int chapter) {
        if (chapter < 0 || chapter >= chapterStartPages.size()) return;
        currentPage = chapterStartPages.get(chapter);
        renderPage();
        setChromeVisible(false);
    }

    private void renderPage() {
        if (binding == null || pages.isEmpty()) return;
        if (pageAnimating) {
            resetPageAnimationViews();
            pageAnimating = false;
        }
        boolean scrolling = readingMode == ReadingMode.SCROLL;
        binding.pageText.setVisibility(scrolling ? View.GONE : View.VISIBLE);
        binding.pageUnderlay.setVisibility(View.GONE);
        binding.verticalRecycler.setVisibility(scrolling ? View.VISIBLE : View.GONE);
        if (scrolling) {
            positionVerticalListAtCurrentPage();
            prefetchVerticalPagesAround(currentPage);
        } else {
            binding.pageText.setText(styleChapterTitle(currentPage, pages.get(currentPage)));
        }
        updatePageMetadata();
    }

    private void updatePageMetadata() {
        if (binding == null || pages.isEmpty()) return;
        binding.pageIndicator.setText(getString(R.string.page_indicator, currentPage + 1, pages.size()));
        binding.previousButton.setEnabled(currentPage > 0);
        binding.nextButton.setEnabled(currentPage < pages.size() - 1);
        updateSpeechAvailability();
        scheduleProgressSave(currentPage);
    }

    private void scheduleProgressSave(int page) {
        if (book == null || progressSaveRunnable == null) return;
        pendingProgressPage = page;
        progressHandler.removeCallbacks(progressSaveRunnable);
        progressHandler.postDelayed(progressSaveRunnable, PROGRESS_SAVE_DELAY_MS);
    }

    private void persistPendingProgress() {
        if (book == null || pendingProgressPage < 0 || worker == null || worker.isShutdown()) return;
        int page = pendingProgressPage;
        String bookId = book.getId();
        pendingProgressPage = -1;
        worker.execute(() -> repository.saveProgress(bookId, page));
    }

    private void flushPendingProgress() {
        if (progressSaveRunnable == null) return;
        progressHandler.removeCallbacks(progressSaveRunnable);
        persistPendingProgress();
    }

    private CharSequence styleChapterTitle(int page, String pageText) {
        return stylePageText(page, pageText, true);
    }

    private SpannableString stylePageText(int page, String pageText, boolean includeHighlight) {
        SpannableString styled = new SpannableString(pageText);
        if (!chapterStartPages.isEmpty()) {
            int chapter = findChapterForPage(page);
            String title = chapterTitles.get(chapter);
            if (chapterStartPages.get(chapter) == page && !title.isEmpty() &&
                    pageText.startsWith(title)) {
                styled.setSpan(new StyleSpan(Typeface.BOLD), 0, title.length(),
                        Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
                styled.setSpan(new RelativeSizeSpan(1.3f), 0, title.length(),
                        Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            }
        }
        if (includeHighlight && reading && page == highlightedPage && highlightedStart >= 0) {
            int start = Math.min(highlightedStart, pageText.length());
            int end = Math.min(Math.max(start, highlightedEnd), pageText.length());
            if (end > start) {
                styled.setSpan(new ForegroundColorSpan(ContextCompat.getColor(
                                requireContext(), R.color.reading_highlight)),
                        start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE);
            }
        }
        return styled;
    }

    private void refreshReadingHighlight(int oldPage, int newPage) {
        if (binding == null || pages.isEmpty()) return;
        if (pageAnimating) return;
        if (readingMode == ReadingMode.PAGE) {
            if (currentPage == oldPage || currentPage == newPage) {
                binding.pageText.setText(styleChapterTitle(currentPage, pages.get(currentPage)));
            }
            return;
        }
        notifyVerticalPageChanged(oldPage, PAYLOAD_HIGHLIGHT);
        if (newPage != oldPage) notifyVerticalPageChanged(newPage, PAYLOAD_HIGHLIGHT);
    }

    private int findChapterForPage(int page) {
        int low = 0;
        int high = chapterStartPages.size() - 1;
        while (low <= high) {
            int middle = (low + high) >>> 1;
            if (chapterStartPages.get(middle) <= page) low = middle + 1;
            else high = middle - 1;
        }
        return Math.max(0, high);
    }

    private void changePage(int delta, boolean userInitiated) {
        if (pages.isEmpty() || pageAnimating) return;
        int target = Math.max(0, Math.min(currentPage + delta, pages.size() - 1));
        if (target == currentPage) return;
        if (readingMode == ReadingMode.PAGE && binding != null &&
                binding.pageText.getWidth() > 0) {
            animatePageChange(target, userInitiated);
        } else {
            currentPage = target;
            renderPage();
        }
    }

    private void animatePageChange(int target, boolean userInitiated) {
        if (binding == null) return;
        TextView topPage = binding.pageText;
        TextView bottomPage = binding.pageUnderlay;
        int previousPage = currentPage;
        int direction = target > currentPage ? 1 : -1;
        float width = topPage.getWidth();
        pageAnimating = true;
        currentPage = target;
        updatePageMetadata();
        resetPageAnimationViews();
        bottomPage.setVisibility(View.VISIBLE);
        if (direction > 0) {
            // The next page is already under the current sheet while the sheet slides away.
            bottomPage.setText(styleChapterTitle(target, pages.get(target)));
            bottomPage.setTranslationX(width * 0.07f);
            bottomPage.setScaleX(0.985f);
            bottomPage.setScaleY(0.985f);
            bottomPage.setAlpha(0.82f);
            topPage.setText(styleChapterTitle(previousPage, pages.get(previousPage)));
            topPage.setElevation(dp(7));
            bottomPage.animate()
                    .translationX(0f)
                    .scaleX(1f)
                    .scaleY(1f)
                    .alpha(1f)
                    .setInterpolator(new DecelerateInterpolator())
                    .setDuration(280)
                    .start();
            topPage.animate()
                    .translationX(-width)
                    .setInterpolator(new AccelerateInterpolator(0.85f))
                    .setDuration(280)
                    .withEndAction(() -> finishStackedPageAnimation(target))
                    .start();
        } else {
            // Returning: the previous sheet comes in from the left over the current page.
            bottomPage.setText(styleChapterTitle(previousPage, pages.get(previousPage)));
            topPage.setText(styleChapterTitle(target, pages.get(target)));
            topPage.setTranslationX(-width);
            topPage.setElevation(dp(7));
            topPage.animate()
                    .translationX(0f)
                    .setInterpolator(new DecelerateInterpolator(1.15f))
                    .setDuration(300)
                    .withEndAction(() -> finishStackedPageAnimation(target))
                    .start();
            bottomPage.animate()
                    .translationX(width * 0.07f)
                    .scaleX(0.985f)
                    .scaleY(0.985f)
                    .alpha(0.84f)
                    .setInterpolator(new AccelerateInterpolator(0.75f))
                    .setDuration(300)
                    .start();
        }
    }

    private void finishStackedPageAnimation(int target) {
        if (binding == null || !pageAnimating || currentPage != target) return;
        binding.pageText.setText(styleChapterTitle(target, pages.get(target)));
        resetPageAnimationViews();
        pageAnimating = false;
    }

    private void resetPageAnimationViews() {
        if (binding == null) return;
        TextView topPage = binding.pageText;
        TextView bottomPage = binding.pageUnderlay;
        topPage.animate().cancel();
        bottomPage.animate().cancel();
        topPage.setTranslationX(0f);
        topPage.setScaleX(1f);
        topPage.setScaleY(1f);
        topPage.setRotationY(0f);
        topPage.setAlpha(1f);
        topPage.setElevation(0f);
        bottomPage.setTranslationX(0f);
        bottomPage.setScaleX(1f);
        bottomPage.setScaleY(1f);
        bottomPage.setAlpha(1f);
        bottomPage.setElevation(0f);
        bottomPage.setVisibility(View.GONE);
    }

    private void positionVerticalListAtCurrentPage() {
        if (binding == null || verticalLayoutManager == null || pages.isEmpty()) return;
        verticalPositioning = true;
        verticalLayoutManager.scrollToPositionWithOffset(currentPage, 0);
        binding.verticalRecycler.post(() -> {
            if (binding == null) return;
            verticalPositioning = false;
            updateCurrentPageFromVerticalList();
        });
    }

    private void updateCurrentPageFromVerticalList() {
        if (verticalPositioning || readingMode != ReadingMode.SCROLL || binding == null ||
                verticalLayoutManager == null || pages.isEmpty()) return;
        int target = verticalLayoutManager.findFirstVisibleItemPosition();
        if (target == RecyclerView.NO_POSITION) return;
        View first = verticalLayoutManager.findViewByPosition(target);
        if (first != null && first.getBottom() <= binding.verticalRecycler.getPaddingTop() + dp(20)) {
            target = Math.min(target + 1, pages.size() - 1);
        }
        prefetchVerticalPagesAround(target);
        if (target == currentPage) return;
        currentPage = target;
        updatePageMetadata();
    }

    private void prefetchVerticalPagesAround(int centerPage) {
        int radius = VERTICAL_PAGE_CACHE_SIZE / 2;
        int first = Math.max(0, centerPage - radius);
        int last = Math.min(pages.size() - 1, centerPage + radius);
        for (int page = first; page <= last; page++) requestPrecomputedPage(page);
    }

    private void requestPrecomputedPage(int page) {
        if (page < 0 || page >= pages.size() || precomputedTextParams == null ||
                textLayoutWorker == null || textLayoutWorker.isShutdown()) return;
        int generation = textLayoutGeneration;
        long requestKey = (((long) generation) << 32) | (page & 0xffffffffL);
        synchronized (precomputedPages) {
            if (precomputedPages.get(page) != null ||
                    !precomputedPagesInFlight.add(requestKey)) return;
        }
        CharSequence styledText = stylePageText(page, pages.get(page), false);
        PrecomputedText.Params params = precomputedTextParams;
        textLayoutWorker.execute(() -> {
            PrecomputedText computed = null;
            try {
                computed = PrecomputedText.create(styledText, params);
            } catch (RuntimeException ignored) {
                // The normal TextView path remains available if a device rejects a span.
            }
            boolean accepted = false;
            synchronized (precomputedPages) {
                precomputedPagesInFlight.remove(requestKey);
                if (computed != null && generation == textLayoutGeneration) {
                    precomputedPages.put(page, computed);
                    accepted = true;
                }
            }
            if (accepted) {
                mainHandler.post(() -> notifyVerticalPageChanged(
                        page, PAYLOAD_PRECOMPUTED_TEXT));
            }
        });
    }

    private void notifyVerticalPageChanged(int page, Object payload) {
        if (binding == null || verticalAdapter == null || page < 0 || page >= pages.size()) return;
        if (binding.verticalRecycler.isComputingLayout()) {
            binding.verticalRecycler.post(() -> notifyVerticalPageChanged(page, payload));
        } else {
            verticalAdapter.notifyItemChanged(page, payload);
        }
    }

    private final class VerticalPageAdapter extends RecyclerView.Adapter<VerticalPageHolder> {
        static final int VIEW_TYPE_PAGE = 0;

        VerticalPageAdapter() {
            setHasStableIds(true);
        }

        @NonNull
        @Override
        public VerticalPageHolder onCreateViewHolder(@NonNull ViewGroup parent, int viewType) {
            TextView template = binding.pageText;
            TextView pageView = new TextView(parent.getContext());
            pageView.setLayoutParams(new RecyclerView.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
            pageView.setGravity(Gravity.TOP | Gravity.START);
            pageView.setIncludeFontPadding(false);
            pageView.setPadding(template.getPaddingLeft(), dp(4),
                    template.getPaddingRight(), dp(4));
            pageView.setLineSpacing(dp(6), 1f);
            pageView.setTextMetricsParams(precomputedTextParams);
            pageView.setTextColor(template.getCurrentTextColor());
            pageView.setBackgroundColor(ContextCompat.getColor(
                    parent.getContext(), R.color.reader_paper));
            return new VerticalPageHolder(pageView);
        }

        @Override
        public void onBindViewHolder(@NonNull VerticalPageHolder holder, int position) {
            bindPage(holder, position);
        }

        @Override
        public void onBindViewHolder(@NonNull VerticalPageHolder holder, int position,
                                     @NonNull List<Object> payloads) {
            bindPage(holder, position);
        }

        private void bindPage(VerticalPageHolder holder, int position) {
            holder.textView.setTag(position);
            if (reading && position == highlightedPage) {
                holder.textView.setText(styleChapterTitle(position, pages.get(position)));
                return;
            }
            PrecomputedText computed;
            synchronized (precomputedPages) {
                computed = precomputedPages.get(position);
            }
            if (computed != null) {
                try {
                    holder.textView.setText(computed);
                    return;
                } catch (IllegalArgumentException ignored) {
                    // Fall through if an OEM TextView changes its metrics parameters.
                }
            }
            holder.textView.setText(stylePageText(position, pages.get(position), false));
            requestPrecomputedPage(position);
        }

        @Override
        public int getItemCount() {
            return pages.size();
        }

        @Override
        public long getItemId(int position) {
            return position;
        }
    }

    private static final class VerticalPageHolder extends RecyclerView.ViewHolder {
        final TextView textView;

        VerticalPageHolder(@NonNull TextView itemView) {
            super(itemView);
            textView = itemView;
        }
    }

    private void toggleReading() {
        if (!isSpeechReady() || pages.isEmpty()) return;
        if (reading) stopReading();
        else {
            reading = true;
            updateReadButton();
            restartSpeechQueue(currentPage, 0);
            setChromeVisible(false);
        }
    }

    private void restartSpeechQueue(int page, int startOffset) {
        if (!reading || !isSpeechReady() || pages.isEmpty()) return;
        speechPage = Math.max(0, Math.min(page, pages.size() - 1));
        stopActiveSpeech();
        speechGeneration++;
        speechStartOffset = Math.max(0,
                Math.min(startOffset, pages.get(speechPage).length()));
        queuedUtterances.clear();
        queuedPageStartOffsets.clear();
        queuedThroughPage = speechPage - 1;
        queueSpeechThrough(Math.min(pages.size() - 1,
                speechPage + SPEECH_LOOKAHEAD_PAGES), true);
    }

    private void queueSpeechThrough(int targetPage, boolean flushFirst) {
        boolean firstUtterance = flushFirst;
        while (reading && queuedThroughPage < targetPage) {
            int page = queuedThroughPage + 1;
            String fullPageText = pages.get(page);
            Integer queuedStartOffset = queuedPageStartOffsets.remove(page);
            int startOffset = queuedStartOffset == null ? 0 : queuedStartOffset;
            if (page == speechPage && speechStartOffset > 0) {
                startOffset = speechStartOffset;
            }
            startOffset = Math.max(0, Math.min(startOffset, fullPageText.length()));
            String pageText = fullPageText.substring(startOffset);
            int currentPageSpeechLength = pageText.length();
            if (page < pages.size() - 1 && pageContinuesToNext.get(page)) {
                String nextPageText = pages.get(page + 1);
                SpeechText.Continuation continuation = SpeechText.mergeContinuation(
                        pageText, nextPageText, true);
                pageText = continuation.getSpeechText();
                if (continuation.getNextPageStartOffset() >= 0) {
                    queuedPageStartOffsets.put(
                            page + 1, continuation.getNextPageStartOffset());
                }
            }
            int maxChunkLength = voiceEngine == VoiceEngine.MATCHA_BAKER
                    ? MATCHA_CHUNK_LENGTH : TextToSpeech.getMaxSpeechInputLength() - 64;
            List<String> chunks = SpeechText.chunk(pageText, maxChunkLength);
            if (chunks.isEmpty()) {
                queuedThroughPage = page;
                continue;
            }
            int chunkSearchStart = 0;
            for (int chunk = 0; chunk < chunks.size(); chunk++) {
                String chunkText = chunks.get(chunk);
                int chunkPosition = pageText.indexOf(chunkText, chunkSearchStart);
                if (chunkPosition < 0) chunkPosition = chunkSearchStart;
                chunkSearchStart = Math.min(pageText.length(),
                        chunkPosition + chunkText.length());
                int highlightPage = page;
                int highlightOffset = startOffset + chunkPosition;
                if (chunkPosition >= currentPageSpeechLength && page < pages.size() - 1) {
                    highlightPage = page + 1;
                    highlightOffset = chunkPosition - currentPageSpeechLength;
                }
                String highlightText = pages.get(highlightPage);
                highlightOffset = Math.max(0, Math.min(highlightOffset,
                        Math.max(0, highlightText.length() - 1)));
                int paragraphStart = ParagraphText.paragraphStart(
                        highlightText, highlightOffset);
                int paragraphEnd = ParagraphText.paragraphEnd(
                        highlightText, highlightOffset);
                String utteranceId = "generation-" + speechGeneration +
                        "-page-" + page + "-chunk-" + chunk;
                queuedUtterances.put(utteranceId, new QueuedUtterance(
                        speechGeneration, page, chunk == chunks.size() - 1,
                        highlightPage, paragraphStart, paragraphEnd));
                boolean flush = firstUtterance;
                firstUtterance = false;
                boolean accepted;
                if (voiceEngine == VoiceEngine.MATCHA_BAKER) {
                    accepted = matchaSpeech != null && matchaSpeech.speak(
                            chunkText, flush, utteranceId);
                } else {
                    int queueMode = flush ? TextToSpeech.QUEUE_FLUSH : TextToSpeech.QUEUE_ADD;
                    accepted = textToSpeech != null && textToSpeech.speak(
                            chunkText, queueMode, null, utteranceId) != TextToSpeech.ERROR;
                }
                if (!accepted) {
                    queuedUtterances.remove(utteranceId);
                    stopReadingWithMessage(R.string.tts_speak_failed);
                    return;
                }
            }
            queuedThroughPage = page;
            if (page == speechPage) speechStartOffset = 0;
        }
    }

    private void startReadingAt(int page, int textOffset) {
        if (!reading || !isSpeechReady() || pages.isEmpty()) return;
        int safePage = Math.max(0, Math.min(page, pages.size() - 1));
        int paragraphStart = ParagraphText.paragraphStart(
                pages.get(safePage), textOffset);
        restartSpeechQueue(safePage, paragraphStart);
    }

    private int findTextOffsetAt(MotionEvent event) {
        if (binding == null || pages.isEmpty()) return -1;
        return findTextOffsetAt(binding.pageText, event.getX(), event.getY());
    }

    private VerticalTextLocation findVerticalTextLocation(MotionEvent event) {
        if (binding == null || pages.isEmpty()) return null;
        View child = binding.verticalRecycler.findChildViewUnder(event.getX(), event.getY());
        if (!(child instanceof TextView)) return null;
        int page = binding.verticalRecycler.getChildAdapterPosition(child);
        if (page == RecyclerView.NO_POSITION) return null;
        int offset = findTextOffsetAt((TextView) child,
                event.getX() - child.getLeft(), event.getY() - child.getTop());
        return offset >= 0 ? new VerticalTextLocation(page, offset) : null;
    }

    private int findTextOffsetAt(TextView textView, float eventX, float eventY) {
        Layout layout = textView.getLayout();
        if (layout == null) return -1;
        float x = eventX - textView.getTotalPaddingLeft() + textView.getScrollX();
        float y = eventY - textView.getTotalPaddingTop() + textView.getScrollY();
        if (eventX < textView.getTotalPaddingLeft() ||
                eventX > textView.getWidth() - textView.getTotalPaddingRight() ||
                y < 0 || y > layout.getHeight()) return -1;
        int line = layout.getLineForVertical((int) y);
        float tolerance = dp(6);
        if (x < layout.getLineLeft(line) - tolerance ||
                x > layout.getLineRight(line) + tolerance) return -1;
        return Math.min(layout.getOffsetForHorizontal(line, x),
                textView.length() - 1);
    }

    private boolean handleReaderKey(KeyEvent event) {
        if (chromeVisible || pages.isEmpty()) return false;
        int keyCode = event.getKeyCode();
        if (keyCode != KeyEvent.KEYCODE_VOLUME_UP &&
                keyCode != KeyEvent.KEYCODE_VOLUME_DOWN) return false;
        if (event.getAction() == KeyEvent.ACTION_DOWN && event.getRepeatCount() == 0) {
            changePage(keyCode == KeyEvent.KEYCODE_VOLUME_UP ? -1 : 1, true);
        }
        return true;
    }

    private void onUtteranceFinished(String utteranceId) {
        QueuedUtterance utterance = queuedUtterances.remove(utteranceId);
        if (!reading || utterance == null || utterance.generation != speechGeneration ||
                !utterance.lastChunkOfPage || utterance.page != speechPage) return;
        if (utterance.page < pages.size() - 1) {
            boolean followReading = currentPage == utterance.page;
            speechPage = utterance.page + 1;
            if (followReading) {
                currentPage = speechPage;
                renderPage();
            }
            queueSpeechThrough(Math.min(pages.size() - 1,
                    speechPage + SPEECH_LOOKAHEAD_PAGES), false);
        } else {
            stopReading();
            Toast.makeText(requireContext(), R.string.book_finished, Toast.LENGTH_SHORT).show();
        }
    }

    private void onUtteranceStarted(String utteranceId) {
        QueuedUtterance utterance = queuedUtterances.get(utteranceId);
        if (!reading || utterance == null || utterance.generation != speechGeneration) return;
        int oldHighlightedPage = highlightedPage;
        highlightedPage = utterance.highlightPage;
        highlightedStart = utterance.highlightStart;
        highlightedEnd = utterance.highlightEnd;
        refreshReadingHighlight(oldHighlightedPage, highlightedPage);
    }

    private void onUtteranceError(String utteranceId) {
        onUtteranceError(utteranceId, null);
    }

    private void onUtteranceError(String utteranceId, String detail) {
        QueuedUtterance utterance = queuedUtterances.get(utteranceId);
        if (utterance != null && utterance.generation == speechGeneration) {
            if (detail == null || detail.trim().isEmpty()) {
                stopReadingWithMessage(R.string.tts_speak_failed);
            } else {
                stopReadingWithMessage(getString(R.string.matcha_speak_failed, detail));
            }
        }
    }

    private void stopActiveSpeech() {
        if (textToSpeech != null) textToSpeech.stop();
        if (matchaSpeech != null) matchaSpeech.stop();
    }

    private void stopReading() {
        int oldHighlightedPage = highlightedPage;
        reading = false;
        speechPage = -1;
        highlightedPage = -1;
        highlightedStart = -1;
        highlightedEnd = -1;
        speechGeneration++;
        queuedThroughPage = -1;
        queuedUtterances.clear();
        queuedPageStartOffsets.clear();
        stopActiveSpeech();
        updateReadButton();
        refreshReadingHighlight(oldHighlightedPage, -1);
    }

    private void stopReadingWithMessage(int message) {
        stopReading();
        if (isAdded()) Toast.makeText(requireContext(), message, Toast.LENGTH_LONG).show();
    }

    private void stopReadingWithMessage(String message) {
        stopReading();
        if (isAdded()) Toast.makeText(requireContext(), message, Toast.LENGTH_LONG).show();
    }

    private void updateReadButton() {
        if (binding != null) binding.readButton.setText(reading ? R.string.pause_reading : R.string.start_reading);
    }

    private void onTextToSpeechInitialized(int generation, int status) {
        if (generation != ttsInitializationGeneration) return;
        if (status != TextToSpeech.SUCCESS) {
            systemTtsReady = false;
            postToView(() -> {
                updateSpeechAvailability();
                if (voiceEngine == VoiceEngine.SYSTEM) {
                    stopReadingWithMessage(R.string.tts_init_failed);
                }
            });
            return;
        }
        TextToSpeech initializedTts = textToSpeech;
        if (initializedTts == null) return;
        int result = initializedTts.setLanguage(Locale.SIMPLIFIED_CHINESE);
        if (result == TextToSpeech.LANG_MISSING_DATA || result == TextToSpeech.LANG_NOT_SUPPORTED) {
            result = initializedTts.setLanguage(Locale.getDefault());
        }
        systemTtsReady = result != TextToSpeech.LANG_MISSING_DATA &&
                result != TextToSpeech.LANG_NOT_SUPPORTED;
        initializedTts.setOnUtteranceProgressListener(new UtteranceProgressListener() {
            @Override public void onStart(String utteranceId) {
                postToView(() -> onUtteranceStarted(utteranceId));
            }
            @Override public void onDone(String utteranceId) {
                postToView(() -> onUtteranceFinished(utteranceId));
            }
            @Override public void onError(String utteranceId) {
                postToView(() -> onUtteranceError(utteranceId));
            }
        });
        postToView(() -> {
            updateSpeechAvailability();
            if (!systemTtsReady && voiceEngine == VoiceEngine.SYSTEM) {
                stopReadingWithMessage(R.string.tts_language_missing);
            }
        });
    }

    private void handleMatchaInitializationFailure(String detail) {
        matchaInitializing = false;
        matchaReady = false;
        MatchaSpeechController failedController = matchaSpeech;
        matchaSpeech = null;
        if (failedController != null) failedController.shutdown();
        postToView(() -> {
            updateSpeechAvailability();
            if (voiceEngine == VoiceEngine.MATCHA_BAKER) {
                voiceEngine = VoiceEngine.SYSTEM;
                saveVoiceEngine();
                updateVoiceButton();
                Toast.makeText(requireContext(),
                        getString(R.string.matcha_init_failed, detail),
                        Toast.LENGTH_LONG).show();
            }
        });
    }

    private void postToView(Runnable action) {
        if (getActivity() != null) getActivity().runOnUiThread(() -> {
            if (isAdded()) action.run();
        });
    }

    private void showFatalError(String message) {
        if (binding == null) return;
        binding.loading.setVisibility(View.GONE);
        binding.topControls.setVisibility(View.GONE);
        binding.controls.setVisibility(View.GONE);
        binding.pageText.setText(message);
        Toast.makeText(requireContext(), message, Toast.LENGTH_LONG).show();
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    @Override
    public void onSaveInstanceState(@NonNull Bundle outState) {
        super.onSaveInstanceState(outState);
        outState.putInt("currentPage", currentPage);
    }

    @Override
    public void onDestroyView() {
        flushPendingProgress();
        stopReading();
        MainActivity activity = (MainActivity) requireActivity();
        activity.setReaderKeyHandler(null);
        activity.setReaderMode(false);
        textLayoutGeneration++;
        mainHandler.removeCallbacksAndMessages(null);
        progressHandler.removeCallbacksAndMessages(null);
        binding.verticalRecycler.setAdapter(null);
        verticalAdapter = null;
        verticalLayoutManager = null;
        binding = null;
        super.onDestroyView();
    }

    @Override
    public void onDestroy() {
        ttsInitializationGeneration++;
        if (textToSpeech != null) textToSpeech.shutdown();
        if (matchaSpeech != null) matchaSpeech.shutdown();
        if (textLayoutWorker != null) textLayoutWorker.shutdownNow();
        worker.shutdown();
        super.onDestroy();
    }

    private enum VoiceEngine { SYSTEM, MATCHA_BAKER }

    enum ReadingMode { PAGE, SCROLL }

    private static final class ReaderPagination {
        final List<String> pages;
        final List<Boolean> pageContinuesToNext;
        final List<String> chapterTitles;
        final List<Integer> chapterStartPages;

        ReaderPagination(List<String> pages, List<Boolean> pageContinuesToNext,
                         List<String> chapterTitles, List<Integer> chapterStartPages) {
            this.pages = pages;
            this.pageContinuesToNext = pageContinuesToNext;
            this.chapterTitles = chapterTitles;
            this.chapterStartPages = chapterStartPages;
        }
    }

    private static final class QueuedUtterance {
        final int generation;
        final int page;
        final boolean lastChunkOfPage;
        final int highlightPage;
        final int highlightStart;
        final int highlightEnd;

        QueuedUtterance(int generation, int page, boolean lastChunkOfPage,
                        int highlightPage, int highlightStart, int highlightEnd) {
            this.generation = generation;
            this.page = page;
            this.lastChunkOfPage = lastChunkOfPage;
            this.highlightPage = highlightPage;
            this.highlightStart = highlightStart;
            this.highlightEnd = highlightEnd;
        }
    }

    private static final class VerticalTextLocation {
        final int page;
        final int textOffset;

        VerticalTextLocation(int page, int textOffset) {
            this.page = page;
            this.textOffset = textOffset;
        }
    }
}
