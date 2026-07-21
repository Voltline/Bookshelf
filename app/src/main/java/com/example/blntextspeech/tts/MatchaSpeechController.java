package com.example.blntextspeech.tts;

import android.content.Context;
import android.content.res.AssetManager;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import com.k2fsa.sherpa.onnx.GeneratedAudio;
import com.k2fsa.sherpa.onnx.OfflineTts;
import com.k2fsa.sherpa.onnx.OfflineTtsConfig;
import com.k2fsa.sherpa.onnx.OfflineTtsMatchaModelConfig;
import com.k2fsa.sherpa.onnx.OfflineTtsModelConfig;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.atomic.AtomicInteger;

/** Runs the bundled Matcha Baker model and streams generated audio through AudioTrack. */
public final class MatchaSpeechController {
    private static final String TAG = "MatchaSpeech";
    private static final String ASSET_MODEL_DIR = "matcha-icefall-zh-baker";
    private static final String ASSET_VOCODER = "vocos-22khz-univ.onnx";
    private static final String MODEL_VERSION = "sherpa-onnx-1.13.4-matcha-baker-v1";
    private static final int AUDIO_QUEUE_CAPACITY = 64;

    public interface Listener {
        void onReady();
        void onStart(String utteranceId);
        void onDone(String utteranceId);
        void onError(String utteranceId, String message);
    }

    private final Context context;
    private final Listener listener;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final ExecutorService synthesisExecutor = Executors.newSingleThreadExecutor();
    private final ExecutorService playbackExecutor = Executors.newSingleThreadExecutor();
    private final BlockingQueue<AudioPacket> audioQueue =
            new LinkedBlockingQueue<>(AUDIO_QUEUE_CAPACITY);
    private final AtomicInteger generation = new AtomicInteger();
    private final Object audioLock = new Object();

    private volatile boolean ready;
    private volatile boolean closed;
    private OfflineTts tts;
    private AudioTrack audioTrack;

    public MatchaSpeechController(Context context, Listener listener) {
        this.context = context.getApplicationContext();
        this.listener = listener;
    }

    public void initialize() {
        synthesisExecutor.execute(() -> {
            try {
                File root = installBundledModel();
                if (closed) return;
                tts = createTts(root);
                createAudioTrack(tts.getSampleRate());
                playbackExecutor.execute(this::playbackLoop);
                ready = true;
                mainHandler.post(() -> {
                    if (!closed) listener.onReady();
                });
            } catch (Throwable error) {
                Log.e(TAG, "Unable to initialize bundled Matcha Baker", error);
                postError(null, readableMessage(error));
            }
        });
    }

    public boolean isReady() {
        return ready && !closed;
    }

    /** Adds one utterance. flush=true cancels all prior synthesis and buffered audio first. */
    public boolean speak(String text, boolean flush, String utteranceId) {
        if (!isReady() || text == null || text.trim().isEmpty()) return false;
        if (flush) stop();
        final int requestGeneration = generation.get();
        synthesisExecutor.execute(() -> synthesize(
                text.trim(), utteranceId, requestGeneration));
        return true;
    }

    public void stop() {
        generation.incrementAndGet();
        audioQueue.clear();
        synchronized (audioLock) {
            if (audioTrack != null) {
                try {
                    audioTrack.pause();
                    audioTrack.flush();
                    audioTrack.play();
                } catch (IllegalStateException ignored) {
                    // The track may be shutting down concurrently.
                }
            }
        }
    }

    public void shutdown() {
        if (closed) return;
        closed = true;
        ready = false;
        stop();
        audioQueue.offer(AudioPacket.shutdown());
        playbackExecutor.shutdownNow();
        synthesisExecutor.execute(() -> {
            if (tts != null) {
                tts.release();
                tts = null;
            }
        });
        synthesisExecutor.shutdown();
        synchronized (audioLock) {
            if (audioTrack != null) {
                try {
                    audioTrack.release();
                } catch (Exception ignored) {
                    // Already released.
                }
                audioTrack = null;
            }
        }
    }

    private void synthesize(String text, String utteranceId, int requestGeneration) {
        if (!isCurrent(requestGeneration)) return;
        try {
            boolean[] started = {false};
            GeneratedAudio audio = tts.generateWithCallback(text, 0, 1.0f, samples -> {
                if (!isCurrent(requestGeneration)) return 0;
                try {
                    if (!started[0]) {
                        audioQueue.put(AudioPacket.start(requestGeneration, utteranceId));
                        started[0] = true;
                    }
                    audioQueue.put(AudioPacket.samples(requestGeneration, samples));
                    return isCurrent(requestGeneration) ? 1 : 0;
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                    return 0;
                }
            });
            if (!isCurrent(requestGeneration)) return;
            if (audio == null || audio.getSamples().length == 0) {
                audioQueue.put(AudioPacket.error(requestGeneration, utteranceId,
                        "Matcha Baker 没有生成音频"));
            } else {
                audioQueue.put(AudioPacket.end(requestGeneration, utteranceId));
            }
        } catch (Throwable error) {
            Log.e(TAG, "Synthesis failed", error);
            if (isCurrent(requestGeneration)) {
                try {
                    audioQueue.put(AudioPacket.error(requestGeneration, utteranceId,
                            readableMessage(error)));
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                }
            }
        }
    }

    private void playbackLoop() {
        while (!closed) {
            try {
                AudioPacket packet = audioQueue.take();
                if (packet.shutdown) return;
                if (!isCurrent(packet.generation)) continue;
                if (packet.samples != null) {
                    AudioTrack track = audioTrack;
                    if (track != null && isCurrent(packet.generation)) {
                        writeFully(track, packet.samples, packet.generation);
                    }
                } else if (packet.start) {
                    mainHandler.post(() -> {
                        if (!closed) listener.onStart(packet.utteranceId);
                    });
                } else if (packet.error != null) {
                    postError(packet.utteranceId, packet.error);
                } else if (packet.utteranceId != null) {
                    mainHandler.post(() -> {
                        if (!closed) listener.onDone(packet.utteranceId);
                    });
                }
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                return;
            } catch (Throwable error) {
                Log.e(TAG, "Playback failed", error);
                if (!closed) postError(null, readableMessage(error));
            }
        }
    }

    private void writeFully(AudioTrack track, float[] samples, int requestGeneration) {
        int offset = 0;
        while (offset < samples.length && isCurrent(requestGeneration)) {
            int written = track.write(samples, offset, samples.length - offset,
                    AudioTrack.WRITE_BLOCKING);
            if (written < 0) {
                throw new IllegalStateException("AudioTrack 写入失败: " + written);
            }
            if (written == 0) return;
            offset += written;
        }
    }

    private boolean isCurrent(int requestGeneration) {
        return !closed && generation.get() == requestGeneration;
    }

    private File installBundledModel() throws IOException {
        File root = new File(context.getNoBackupFilesDir(), "matcha-baker");
        File marker = new File(root, MODEL_VERSION + ".ready");
        if (marker.isFile() && isModelComplete(root)) return root;
        if (!root.exists() && !root.mkdirs()) {
            throw new IOException("无法创建 Matcha 模型目录");
        }
        copyAssetTree(context.getAssets(), ASSET_MODEL_DIR, root);
        copyAssetTree(context.getAssets(), ASSET_VOCODER, root);
        if (!marker.createNewFile() && !marker.isFile()) {
            throw new IOException("无法写入 Matcha 模型完成标记");
        }
        return root;
    }

    private static boolean isModelComplete(File root) {
        File modelDir = new File(root, ASSET_MODEL_DIR);
        return new File(modelDir, "model-steps-3.onnx").length() > 0 &&
                new File(root, ASSET_VOCODER).length() > 0 &&
                new File(modelDir, "tokens.txt").length() > 0 &&
                new File(modelDir, "lexicon.txt").length() > 0;
    }

    private static void copyAssetTree(AssetManager assets, String assetPath, File root)
            throws IOException {
        String[] children = assets.list(assetPath);
        if (children != null && children.length > 0) {
            File directory = new File(root, assetPath);
            if (!directory.exists() && !directory.mkdirs()) {
                throw new IOException("无法创建模型子目录: " + directory);
            }
            for (String child : children) {
                copyAssetTree(assets, assetPath + "/" + child, root);
            }
            return;
        }
        File destination = new File(root, assetPath);
        File parent = destination.getParentFile();
        if (parent != null && !parent.exists() && !parent.mkdirs()) {
            throw new IOException("无法创建模型文件目录: " + parent);
        }
        File temporary = new File(destination.getPath() + ".tmp");
        try (InputStream input = assets.open(assetPath);
             FileOutputStream output = new FileOutputStream(temporary)) {
            byte[] buffer = new byte[1024 * 1024];
            int count;
            while ((count = input.read(buffer)) != -1) output.write(buffer, 0, count);
            output.getFD().sync();
        }
        if (destination.exists() && !destination.delete()) {
            throw new IOException("无法替换旧模型文件: " + destination);
        }
        if (!temporary.renameTo(destination)) {
            throw new IOException("无法完成模型文件复制: " + destination);
        }
    }

    private static OfflineTts createTts(File root) {
        File modelDir = new File(root, ASSET_MODEL_DIR);
        OfflineTtsMatchaModelConfig matcha = OfflineTtsMatchaModelConfig.builder()
                .setAcousticModel(new File(modelDir, "model-steps-3.onnx").getPath())
                .setVocoder(new File(root, ASSET_VOCODER).getPath())
                .setTokens(new File(modelDir, "tokens.txt").getPath())
                .setLexicon(new File(modelDir, "lexicon.txt").getPath())
                .build();
        OfflineTtsModelConfig model = OfflineTtsModelConfig.builder()
                .setMatcha(matcha)
                .setNumThreads(Math.max(1, Math.min(4,
                        Runtime.getRuntime().availableProcessors() / 2)))
                .setDebug(false)
                .build();
        String ruleFsts = new File(modelDir, "phone.fst").getPath() + "," +
                new File(modelDir, "date.fst").getPath() + "," +
                new File(modelDir, "number.fst").getPath();
        OfflineTtsConfig config = OfflineTtsConfig.builder()
                .setModel(model)
                .setRuleFsts(ruleFsts)
                .setMaxNumSentences(1)
                .setSilenceScale(0.15f)
                .build();
        return new OfflineTts(config);
    }

    private void createAudioTrack(int sampleRate) {
        int minimum = AudioTrack.getMinBufferSize(sampleRate,
                AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_FLOAT);
        AudioAttributes attributes = new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build();
        AudioFormat format = new AudioFormat.Builder()
                .setSampleRate(sampleRate)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                .build();
        int bufferSize = Math.max(minimum, sampleRate * Float.BYTES / 2);
        bufferSize = (bufferSize + Float.BYTES - 1) & ~(Float.BYTES - 1);
        synchronized (audioLock) {
            audioTrack = new AudioTrack(attributes, format, bufferSize,
                    AudioTrack.MODE_STREAM, AudioManager.AUDIO_SESSION_ID_GENERATE);
            if (audioTrack.getState() != AudioTrack.STATE_INITIALIZED) {
                audioTrack.release();
                audioTrack = null;
                throw new IllegalStateException("无法初始化 Matcha 音频播放器");
            }
            audioTrack.play();
        }
    }

    private void postError(String utteranceId, String message) {
        mainHandler.post(() -> {
            if (!closed) listener.onError(utteranceId, message);
        });
    }

    private static String readableMessage(Throwable error) {
        String message = error.getMessage();
        return message == null || message.trim().isEmpty()
                ? error.getClass().getSimpleName() : message;
    }

    private static final class AudioPacket {
        final int generation;
        final float[] samples;
        final String utteranceId;
        final String error;
        final boolean start;
        final boolean shutdown;

        private AudioPacket(int generation, float[] samples, String utteranceId,
                            String error, boolean start, boolean shutdown) {
            this.generation = generation;
            this.samples = samples;
            this.utteranceId = utteranceId;
            this.error = error;
            this.start = start;
            this.shutdown = shutdown;
        }

        static AudioPacket samples(int generation, float[] samples) {
            return new AudioPacket(generation, samples, null, null, false, false);
        }

        static AudioPacket start(int generation, String utteranceId) {
            return new AudioPacket(generation, null, utteranceId, null, true, false);
        }

        static AudioPacket end(int generation, String utteranceId) {
            return new AudioPacket(generation, null, utteranceId, null, false, false);
        }

        static AudioPacket error(int generation, String utteranceId, String error) {
            return new AudioPacket(generation, null, utteranceId, error, false, false);
        }

        static AudioPacket shutdown() {
            return new AudioPacket(-1, null, null, null, false, true);
        }
    }
}
