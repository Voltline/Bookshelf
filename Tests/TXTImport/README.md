# TXT import regression

The simulator-only Debug launch argument `--txt-regression` creates three text
fixtures in the app's Documents directory, then imports them using the same
library flow as the Files picker. It checks UTF-8, UTF-16 and GB18030 decoding,
chapter detection, long-text splitting, Readium's table of contents and the
first rendered page. Imported test books and source fixtures are removed after
the run.

1. Build and install a Debug version of BookShelf on an iPhone simulator.
2. Launch it with `xcrun simctl launch booted com.Voltline.BookShelf --txt-regression`.
3. Locate the data container with `xcrun simctl get_app_container booted com.Voltline.BookShelf data`.
4. Read `Documents/txt-results.txt`. The last line must start with `PASS`.

The text includes `&` and XML markup characters in its final chapter, so a
successful Readium parse also checks that the generated XHTML escapes content.
