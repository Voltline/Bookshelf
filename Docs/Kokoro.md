# Kokoro offline TTS

## Use

Open bookshelf Settings → 朗读引擎 → Kokoro 离线朗读. Download the model (~209 MB),
choose a voice, and preview before opening a book. The default engine remains
Apple's system engine. Synthesis does not make network requests. Model download
uses Hugging Face HTTPS URLs; network availability is required only for installation.
Cancellation retains complete verified files, not a resumable partial large file.

The Readium TTSEngine adapter preserves publication traversal, sentence locators,
highlighting, and page following. It reports actual playback chunks, not invented
word timestamps. Pause/resume restarts the current Readium sentence. Pitch is not
supported for this engine and is hidden. CPU inference is used, with two threads.
Lock-screen longevity, interruptions, thermal behavior, and memory should also be
tested on a real iPhone before release.

## Pinned components

- sherpa-onnx 1.13.8 and onnxruntime-libs 1.28.2 (Swift Package Manager).
- Model: https://huggingface.co/csukuangfj/kokoro-int8-multi-lang-v1_1
- Model revision: `155831f1b4ba23b1f5c058be6a61df90cefb2a37`.
- `KokoroManifest.json` contains resource sizes and SHA-256 (LFS) / Git blob SHA-1
  hashes from that repository. All files are verified before installation is marked
  complete. Unused UK lexicon, source script, root README and .gitattributes are
  omitted. The model license is retained in the download.
- Voice IDs: https://k2-fsa.github.io/sherpa/onnx/tts/all/Chinese-English/kokoro-multi-lang-v1_1.html
  IDs 0–2 are English, 3–57 Chinese female, 58–102 Chinese male. UI numbering within
  each Chinese group is ordinal, not an invented personal name.

## Licensing / distribution

This integration is an on-device evaluation. Kokoro weights and sherpa-onnx are
Apache-2.0; ONNX Runtime is MIT. The TTS distribution also uses eSpeak NG (GPL-3.0),
and other transitive dependencies retain their own licenses. This is **not** a
statement that a closed-source App Store distribution is license-cleared. Before
distributing a binary, audit the pinned XCFramework contents and satisfy applicable
notices/source/distribution obligations, or replace/rebuild the affected components.
Upstream source and notices are available in the resolved Swift package checkouts.

## Smoke test

In a disposable iPhone simulator, install the Debug build, copy
`Tests/FontRegression/font-test.epub` into the app's Documents directory, and launch:

```sh
xcrun simctl launch booted com.Voltline.BookShelf --kokoro-regression
```

The simulator-only entry downloads/verifies the model, synthesizes a Chinese female
sample, plays a Chinese male sample through the production playback path, checks
the highlight callback, cancels a longer utterance, and runs the two-chapter EPUB
through Readium to check automatic chapter following. Inspect the app's Documents
`kokoro-results.txt` for PASS/FAIL and `kokoro-sample.wav` for the generated audio.
Rerunning with the installed model exercises offline loading without downloading.
Only the temporary fixture is imported and then removed; existing library books
are not modified by this test.

### Verification (2026-09-21)

- Debug iOS Simulator and Release generic iOS builds passed (`CODE_SIGNING_ALLOWED=NO`).
- iPhone 18 Pro / iOS 27.0 simulator: complete model download + all asset hashes passed.
- Cached-model rerun passed without entering the download path.
- Chinese female sample: 90,844 samples at 24 kHz (~3.8 seconds of audio);
  cold load + synthesis took ~4.3 seconds on this Mac's simulator, not an iPhone benchmark.
- Chinese male playback, playback-range callback, synthesis cancellation passed.
- Readium automatically followed the two-chapter EPUB into chapter 2 during speech.
- Real-device long-duration background/lock-screen and thermal tests remain outstanding.
