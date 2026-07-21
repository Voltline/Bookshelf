package com.example.blntextspeech.data;

import android.content.ContentResolver;
import android.content.Context;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.net.Uri;
import android.provider.OpenableColumns;

import com.example.blntextspeech.epub.EpubDocument;
import com.example.blntextspeech.epub.EpubParser;
import com.example.blntextspeech.model.Book;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Comparator;
import java.util.List;
import java.util.UUID;

public final class BookRepository {
    private static final String PREFS = "bookshelf";
    private static final String KEY_INDEX = "book_index_v1";
    private static volatile BookRepository instance;

    private final Context context;
    private final SharedPreferences preferences;
    private final EpubParser parser = new EpubParser();

    private BookRepository(Context context) {
        this.context = context.getApplicationContext();
        this.preferences = this.context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    public static BookRepository get(Context context) {
        if (instance == null) {
            synchronized (BookRepository.class) {
                if (instance == null) instance = new BookRepository(context);
            }
        }
        return instance;
    }

    public synchronized List<Book> getBooks() {
        List<Book> books = decode(preferences.getString(KEY_INDEX, ""));
        books.removeIf(book -> !getBookFile(book).isFile());
        books.sort(Comparator.comparingLong(Book::getImportedAt).reversed());
        return books;
    }

    public synchronized Book getBook(String id) {
        for (Book book : getBooks()) if (book.getId().equals(id)) return book;
        return null;
    }

    public Book importBook(Uri uri) throws IOException {
        String id = UUID.randomUUID().toString();
        File directory = new File(context.getFilesDir(), "books");
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IOException("无法创建书籍目录");
        File destination = new File(directory, id + ".epub");
        String displayName = queryDisplayName(context.getContentResolver(), uri);

        try (InputStream input = context.getContentResolver().openInputStream(uri);
             FileOutputStream output = new FileOutputStream(destination)) {
            if (input == null) throw new IOException("无法读取所选文件");
            byte[] buffer = new byte[16 * 1024];
            int count;
            while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
        } catch (IOException e) {
            //noinspection ResultOfMethodCallIgnored
            destination.delete();
            throw e;
        }

        try {
            EpubDocument document = parser.parse(destination);
            String title = document.getTitle().trim().isEmpty()
                    ? titleFromDisplayName(displayName) : document.getTitle();
            String author = document.getAuthor();
            if (author.length() == 4 && author.charAt(0) == '未' && author.charAt(1) == '知'
                    && author.charAt(2) == '作' && author.charAt(3) == '者') {
                author = authorFromDisplayName(displayName, author);
            }
            Book book = new Book(id, title, author, destination.getName(), System.currentTimeMillis(), 0);
            synchronized (this) {
                List<Book> books = getBooks();
                books.add(book);
                save(books);
            }
            return book;
        } catch (IOException e) {
            //noinspection ResultOfMethodCallIgnored
            destination.delete();
            throw e;
        }
    }

    public EpubDocument read(Book book) throws IOException {
        return parser.parse(getBookFile(book));
    }

    public synchronized void saveProgress(String id, int page) {
        List<Book> books = getBooks();
        for (int i = 0; i < books.size(); i++) {
            if (books.get(i).getId().equals(id)) {
                books.set(i, books.get(i).withLastPage(page));
                save(books);
                return;
            }
        }
    }

    private File getBookFile(Book book) {
        return new File(new File(context.getFilesDir(), "books"), book.getFileName());
    }

    private void save(List<Book> books) {
        preferences.edit().putString(KEY_INDEX, encode(books)).apply();
    }

    private static String encode(List<Book> books) {
        StringBuilder text = new StringBuilder();
        Base64.Encoder encoder = Base64.getUrlEncoder().withoutPadding();
        for (Book book : books) {
            if (text.length() > 0) text.append('\n');
            text.append(field(encoder, book.getId())).append('|')
                    .append(field(encoder, book.getTitle())).append('|')
                    .append(field(encoder, book.getAuthor())).append('|')
                    .append(field(encoder, book.getFileName())).append('|')
                    .append(book.getImportedAt()).append('|').append(book.getLastPage());
        }
        return text.toString();
    }

    private static List<Book> decode(String text) {
        List<Book> books = new ArrayList<>();
        if (text == null || text.trim().isEmpty()) return books;
        Base64.Decoder decoder = Base64.getUrlDecoder();
        for (String line : text.split("\\n")) {
            try {
                String[] parts = line.split("\\|", -1);
                if (parts.length != 6) continue;
                books.add(new Book(unfield(decoder, parts[0]), unfield(decoder, parts[1]),
                        unfield(decoder, parts[2]), unfield(decoder, parts[3]),
                        Long.parseLong(parts[4]), Integer.parseInt(parts[5])));
            } catch (RuntimeException ignored) {
                // Ignore a damaged index row instead of making the entire shelf unusable.
            }
        }
        return books;
    }

    private static String field(Base64.Encoder encoder, String value) {
        return encoder.encodeToString(value.getBytes(StandardCharsets.UTF_8));
    }

    private static String unfield(Base64.Decoder decoder, String value) {
        return new String(decoder.decode(value), StandardCharsets.UTF_8);
    }

    private static String queryDisplayName(ContentResolver resolver, Uri uri) {
        try (Cursor cursor = resolver.query(uri, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (cursor != null && cursor.moveToFirst()) {
                int index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                if (index >= 0) return cursor.getString(index);
            }
        } catch (RuntimeException ignored) {
        }
        String segment = uri.getLastPathSegment();
        return segment == null ? "未命名书籍.epub" : segment;
    }

    private static String stripExtension(String name) {
        int dot = name.lastIndexOf('.');
        return dot > 0 ? name.substring(0, dot) : name;
    }

    private static String titleFromDisplayName(String name) {
        String base = stripExtension(name).trim();
        int western = base.indexOf('(');
        int chinese = base.indexOf('（');
        int groupStart = western < 0 ? chinese : chinese < 0 ? western : Math.min(western, chinese);
        return groupStart > 0 ? base.substring(0, groupStart).trim() : base;
    }

    private static String authorFromDisplayName(String name, String fallback) {
        String base = stripExtension(name);
        int western = base.indexOf('(');
        int chinese = base.indexOf('（');
        int start = western < 0 ? chinese : chinese < 0 ? western : Math.min(western, chinese);
        if (start < 0) return fallback;
        char closing = base.charAt(start) == '(' ? ')' : '）';
        int end = base.indexOf(closing, start + 1);
        if (end <= start + 1) return fallback;
        String candidate = base.substring(start + 1, end).trim();
        return candidate.isEmpty() ? fallback : candidate;
    }
}
