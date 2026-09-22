# Bundled reading fonts

These fonts are embedded for offline EPUB rendering and served to Readium's web
views with `CSSFontFamilyDeclaration`. They do not depend on fonts installed on
the iPhone.

- `NotoSerifCJKsc-Regular.otf`: Noto Serif CJK SC, from
  https://github.com/notofonts/noto-cjk/tree/main/Serif/OTF/SimplifiedChinese
  (SIL Open Font License 1.1; see `NotoSerif-LICENSE.txt`).
- `LXGWWenKaiLite-Regular.ttf`: LXGW WenKai Lite, from
  https://github.com/lxgw/LxgwWenKai-Lite/tree/main/fonts/TTF
  (SIL Open Font License 1.1; see `LXGWWenKaiLite-LICENSE.txt`).

The original font files are kept unmodified. Both regular faces cover Chinese
text; WebKit synthesizes bold and italic styling when requested by an EPUB.
