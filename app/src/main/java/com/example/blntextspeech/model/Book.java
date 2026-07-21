package com.example.blntextspeech.model;

public final class Book {
    private final String id;
    private final String title;
    private final String author;
    private final String fileName;
    private final long importedAt;
    private final int lastPage;

    public Book(String id, String title, String author, String fileName, long importedAt, int lastPage) {
        this.id = id;
        this.title = title;
        this.author = author;
        this.fileName = fileName;
        this.importedAt = importedAt;
        this.lastPage = Math.max(0, lastPage);
    }

    public String getId() { return id; }
    public String getTitle() { return title; }
    public String getAuthor() { return author; }
    public String getFileName() { return fileName; }
    public long getImportedAt() { return importedAt; }
    public int getLastPage() { return lastPage; }

    public Book withLastPage(int page) {
        return new Book(id, title, author, fileName, importedAt, page);
    }
}
