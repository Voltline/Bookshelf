package com.example.blntextspeech;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.io.File;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

public class TestEpubProvider extends ContentProvider {
    public static final Uri BOOK_URI = Uri.parse("content://com.example.blntextspeech.test.epubprovider/book.epub");

    @Override
    public boolean onCreate() {
        return true;
    }

    @Nullable
    @Override
    public String getType(@NonNull Uri uri) {
        return "application/epub+zip";
    }

    @Nullable
    @Override
    public Cursor query(@NonNull Uri uri, String[] projection, String selection,
                        String[] selectionArgs, String sortOrder) {
        MatrixCursor cursor = new MatrixCursor(new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE});
        File file = bookFile();
        cursor.addRow(new Object[]{"instrumentation-test.epub", file.isFile() ? file.length() : 0});
        return cursor;
    }

    @Nullable
    @Override
    public ParcelFileDescriptor openFile(@NonNull Uri uri, @NonNull String mode) throws FileNotFoundException {
        File file = bookFile();
        try {
            createBook(file);
        } catch (IOException error) {
            FileNotFoundException wrapped = new FileNotFoundException("Unable to create test EPUB");
            wrapped.initCause(error);
            throw wrapped;
        }
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY);
    }

    private File bookFile() {
        return new File(getContext().getCacheDir(), "instrumentation-test.epub");
    }

    private static void createBook(File file) throws IOException {
        try (ZipOutputStream zip = new ZipOutputStream(new FileOutputStream(file))) {
            put(zip, "META-INF/container.xml", "<?xml version=\"1.0\"?><container xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\"><rootfiles><rootfile full-path=\"OPS/book.opf\"/></rootfiles></container>");
            put(zip, "OPS/book.opf", "<?xml version=\"1.0\"?><package xmlns=\"http://www.idpf.org/2007/opf\"><metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>听读自动化测试书</dc:title><dc:creator>设备测试</dc:creator></metadata><manifest><item id=\"one\" href=\"one.xhtml\"/><item id=\"two\" href=\"two.xhtml\"/></manifest><spine><itemref idref=\"one\"/><itemref idref=\"two\"/></spine></package>");
            StringBuilder chapterOne = new StringBuilder("<html><body><h1>第一章</h1>");
            for (int i = 1; i <= 45; i++) chapterOne.append("<p>这是第").append(i).append("个测试段落，用于验证正文能够按照手机屏幕尺寸分成多个页面，并且可以左右翻阅。</p>");
            chapterOne.append("</body></html>");
            put(zip, "OPS/one.xhtml", chapterOne.toString());
            put(zip, "OPS/two.xhtml", "<html><body><h1>第二章</h1><p>如果能够看到这里，说明 EPUB 书脊顺序和跨章节分页均正常。</p></body></html>");
        }
    }

    private static void put(ZipOutputStream zip, String name, String text) throws IOException {
        zip.putNextEntry(new ZipEntry(name));
        zip.write(text.getBytes(StandardCharsets.UTF_8));
        zip.closeEntry();
    }

    @Nullable @Override public Uri insert(@NonNull Uri uri, ContentValues values) { return null; }
    @Override public int delete(@NonNull Uri uri, String selection, String[] selectionArgs) { return 0; }
    @Override public int update(@NonNull Uri uri, ContentValues values, String selection, String[] selectionArgs) { return 0; }
}
