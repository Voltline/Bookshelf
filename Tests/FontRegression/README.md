# System font regression

The simulator-only Debug launch argument `--font-regression` runs the actual
ReadiumReaderModel with the included two-chapter EPUB. It does not exist in
device or Release builds. Use a disposable simulator.

1. Build and install BookShelf on an iPhone simulator.
2. Get its data directory with `xcrun simctl get_app_container booted com.Voltline.BookShelf data`.
3. Copy `font-test.epub` from this directory to the app's `Documents` directory.
4. Launch with `xcrun simctl launch booted com.Voltline.BookShelf --font-regression`.
5. Read `Documents/font-results.txt`. The last line must start with `PASS`.

The test switches publisher → sans → serif → legacy kai → monospace → publisher.
It inspects computed styles and hashes pixels rendered from **Chinese-only text**
in each loaded chapter, so changing only Latin fallback fonts cannot pass.
The first chapter includes publisher `!important` font styling and both `lang`
and `xml:lang` on its text. The second has no custom font styling.
The imported test book is removed after the run; other library entries are untouched.

Verified on iOS 27.0 simulator: PingFang SC → Hiragino Mincho ProN changes
Chinese glyphs in both chapters; publisher restoration produces the original hash.
Monospace does not change Chinese glyphs, which is why the picker labels it 西文.
