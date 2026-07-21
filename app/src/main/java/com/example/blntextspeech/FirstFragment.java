package com.example.blntextspeech;

import android.graphics.Typeface;
import android.net.Uri;
import android.os.Bundle;
import android.view.LayoutInflater;
import android.view.View;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.content.ContextCompat;
import androidx.fragment.app.Fragment;
import androidx.navigation.fragment.NavHostFragment;

import com.example.blntextspeech.data.BookRepository;
import com.example.blntextspeech.databinding.FragmentFirstBinding;
import com.example.blntextspeech.model.Book;
import com.google.android.material.card.MaterialCardView;

import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class FirstFragment extends Fragment {
    private FragmentFirstBinding binding;
    private BookRepository repository;
    private ExecutorService worker;
    private ActivityResultLauncher<String[]> openBookLauncher;

    @Override
    public void onCreate(@Nullable Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        repository = BookRepository.get(requireContext());
        worker = Executors.newSingleThreadExecutor();
        openBookLauncher = registerForActivityResult(new ActivityResultContracts.OpenDocument(), this::importBook);
    }

    @Override
    public View onCreateView(@NonNull LayoutInflater inflater, ViewGroup container, Bundle savedInstanceState) {
        binding = FragmentFirstBinding.inflate(inflater, container, false);
        return binding.getRoot();
    }

    @Override
    public void onViewCreated(@NonNull View view, Bundle savedInstanceState) {
        super.onViewCreated(view, savedInstanceState);
        binding.importButton.setOnClickListener(v ->
                openBookLauncher.launch(new String[]{"application/epub+zip", "application/zip", "*/*"}));
        renderShelf();
    }

    @Override
    public void onResume() {
        super.onResume();
        if (binding != null) renderShelf();
    }

    private void importBook(Uri uri) {
        if (uri == null || binding == null) return;
        setImporting(true);
        worker.execute(() -> {
            try {
                Book book = repository.importBook(uri);
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    if (binding == null) return;
                    setImporting(false);
                    renderShelf();
                    Toast.makeText(requireContext(), getString(R.string.import_success, book.getTitle()), Toast.LENGTH_SHORT).show();
                });
            } catch (Exception error) {
                if (!isAdded()) return;
                requireActivity().runOnUiThread(() -> {
                    if (binding == null) return;
                    setImporting(false);
                    String message = error.getMessage() == null ? getString(R.string.import_failed) : error.getMessage();
                    Toast.makeText(requireContext(), message, Toast.LENGTH_LONG).show();
                });
            }
        });
    }

    private void setImporting(boolean importing) {
        binding.importButton.setEnabled(!importing);
        binding.importProgress.setVisibility(importing ? View.VISIBLE : View.GONE);
        binding.importHint.setText(importing ? R.string.importing : R.string.import_hint);
    }

    private void renderShelf() {
        List<Book> books = repository.getBooks();
        binding.bookList.removeAllViews();
        binding.emptyShelf.setVisibility(books.isEmpty() ? View.VISIBLE : View.GONE);
        for (Book book : books) binding.bookList.addView(createBookCard(book));
        binding.bookCount.setText(getResources().getQuantityString(R.plurals.book_count, books.size(), books.size()));
    }

    private View createBookCard(Book book) {
        int padding = dp(16);
        MaterialCardView card = new MaterialCardView(requireContext());
        LinearLayout.LayoutParams cardParams = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        cardParams.setMargins(0, 0, 0, dp(12));
        card.setLayoutParams(cardParams);
        card.setClickable(true);
        card.setFocusable(true);
        card.setStrokeWidth(dp(1));
        card.setStrokeColor(ContextCompat.getColor(requireContext(), R.color.shelf_outline));
        card.setRadius(dp(14));

        LinearLayout content = new LinearLayout(requireContext());
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(padding, padding, padding, padding);

        TextView title = new TextView(requireContext());
        title.setText(book.getTitle());
        title.setTextSize(18);
        title.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        title.setTextColor(ContextCompat.getColor(requireContext(), R.color.reader_text));
        title.setMaxLines(2);

        TextView author = new TextView(requireContext());
        author.setText(getString(R.string.book_author, book.getAuthor()));
        author.setTextSize(14);
        author.setTextColor(ContextCompat.getColor(requireContext(), R.color.secondary_text));
        author.setPadding(0, dp(6), 0, 0);

        TextView progress = new TextView(requireContext());
        progress.setText(book.getLastPage() > 0
                ? getString(R.string.continue_page, book.getLastPage() + 1)
                : getString(R.string.tap_to_read));
        progress.setTextSize(13);
        progress.setTextColor(ContextCompat.getColor(requireContext(), R.color.brand));
        progress.setPadding(0, dp(10), 0, 0);

        content.addView(title);
        content.addView(author);
        content.addView(progress);
        card.addView(content);
        card.setOnClickListener(v -> {
            Bundle arguments = new Bundle();
            arguments.putString(SecondFragment.ARG_BOOK_ID, book.getId());
            NavHostFragment.findNavController(this)
                    .navigate(R.id.action_FirstFragment_to_SecondFragment, arguments);
        });
        return card;
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    @Override
    public void onDestroyView() {
        super.onDestroyView();
        binding = null;
    }

    @Override
    public void onDestroy() {
        super.onDestroy();
        worker.shutdownNow();
    }
}
