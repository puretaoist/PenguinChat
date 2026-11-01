package com.puretaoist31.penguinchat

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import kotlin.math.abs

/**
 * Android 音频平台通道：裸 PCM 播放 + 裸 PCM 录音，供语音消息使用。
 *
 * ## 为什么要有这个文件
 *
 * 语音消息就是一段 PCM（之后可能压成 SILK，那是另一层的事）。播放与录音
 * 都依赖 Android 的 AudioTrack / AudioRecord，Dart 侧没有等价能力——
 * 只能用平台通道落到这里。本文件只负责把字节播出去 / 录进来，
 * 不做任何编解码（SILK 由 lib/infra/audio/ 那层负责）。
 *
 * ## 通道协议（与 lib/infra/platform/audio_bridge.dart 一一对应）
 *
 * MethodChannel penguinchat/audio：
 *   playPcmFile {path, sampleRate=16000} -> {durationMs:Int}
 *   pause / resume / stop                -> Int（当前毫秒）
 *   seek {positionMs}                    -> Int（落点毫秒）
 *   position                             -> Int（当前毫秒）
 *   setSpeed {speed:Double}              -> Bool（API<23 返回 false）
 *   recordStart {sampleRate=16000}       -> null
 *   recordStop                           -> {path, durationMs, size} 或 null
 *   recordCancel                         -> null
 *
 * EventChannel penguinchat/audio/events：约每 50ms 发
 * {event:progress, positionMs:Int}，播完发 {event:completed, positionMs:Int}。
 *
 * EventChannel penguinchat/audio/record：约每 50ms 发
 * {durationMs:Int, amplitude:Double(0..1)}，amplitude 是本窗口 PCM 峰值归一化。
 *
 * ## 线程模型（这里最容易被写坏）
 *
 * 播放/录音各跑在自己的线程里（penguinchat-audio-writer /
 * penguinchat-audio-recorder），所有事件回调都 post 回主线程再发出去，
 * 因为 EventChannel.EventSink 只允许在主线程使用。
 *
 * 停止时必须 release 掉 AudioTrack / AudioRecord：MODE_STREAM 的
 * AudioTrack 如果不释放，第二次 play 会报 AudioTrack not initialized。
 * Activity 销毁时 dispose 会统一收尾。
 */
class AudioBridge(private val context: Context) {

    companion object {
        /** 与 Dart 侧 AudioBridge.methodChannelName 严格一致。 */
        const val CHANNEL = "penguinchat/audio"

        /** 播放事件通道。 */
        const val EVENTS_CHANNEL = "penguinchat/audio/events"

        /** 录音事件通道。 */
        const val RECORD_CHANNEL = "penguinchat/audio/record"

        private const val DEFAULT_SAMPLE_RATE = 16000

        /** 录音权限申请的 requestCode（与 Activity 转发时比对）。 */
        const val RECORD_PERM_CODE = 0x9C01

        /** 事件推送间隔，约 50ms。 */
        private const val EVENT_INTERVAL_MS = 50L

        /** 单声道 PCM16：一帧 = 2 字节。 */
        private const val BYTES_PER_FRAME = 2
    }

    private val mainHandler = Handler(Looper.getMainLooper())

    private var methodChannel: MethodChannel? = null
    private var eventsChannel: EventChannel? = null
    private var recordChannel: EventChannel? = null

    private var playbackSink: EventChannel.EventSink? = null
    private var recordSink: EventChannel.EventSink? = null

    // ── 播放状态（受 lock 保护） ───────────────────────────────────────────
    private val lock = Any()
    private var audioTrack: AudioTrack? = null
    private var writerThread: Thread? = null
    private var playSampleRate = DEFAULT_SAMPLE_RATE

    /** 本段音频总帧数。 */
    private var totalFrames = 0L

    /** 当前会话起始的绝对帧偏移（seek 后不为 0）。 */
    private var framesBase = 0L

    /** 建立 framesBase 时 AudioTrack 头位置的读数（消除 flush 语义差异）。 */
    private var headZero = 0L

    /** 文件是否已经全部写入 AudioTrack 缓冲区。 */
    private var writeDone = false

    private var paused = false
    private var stopped = true
    private var pendingSeekFrame = -1L
    private var lastHead = 0L
    private var lastHeadChangeMs = 0L

    // ── 录音状态（受 recordLock 保护） ─────────────────────────────────────
    private val recordLock = Any()
    private var audioRecord: AudioRecord? = null
    private var recordThread: Thread? = null
    private var recordFile: File? = null
    private var recordSampleRate = DEFAULT_SAMPLE_RATE
    private var recordFrames = 0L
    private var recordStopped = true
    private var recordWindowPeak = 0

    // ══════════════════════════════════════════════════════════════════════
    //  通道装配
    // ══════════════════════════════════════════════════════════════════════

    /** 把三个通道挂到引擎上。由 MainActivity.configureFlutterEngine 调用。 */
    fun attach(engine: FlutterEngine) {
        methodChannel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .also { it.setMethodCallHandler(methodCallHandler) }
        eventsChannel = EventChannel(engine.dartExecutor.binaryMessenger, EVENTS_CHANNEL)
            .also { it.setStreamHandler(playbackStreamHandler) }
        recordChannel = EventChannel(engine.dartExecutor.binaryMessenger, RECORD_CHANNEL)
            .also { it.setStreamHandler(recordStreamHandler) }
    }

    /** Activity 销毁时收尾：停掉播放/录音并释放底层资源。 */
    fun dispose() {
        stopPlaybackInternal(release = true)
        finalizeRecording(discard = true)
        methodChannel?.setMethodCallHandler(null)
        eventsChannel?.setStreamHandler(null)
        recordChannel?.setStreamHandler(null)
        methodChannel = null
        eventsChannel = null
        recordChannel = null
        playbackSink = null
        recordSink = null
        mainHandler.removeCallbacksAndMessages(null)
    }

    // ══════════════════════════════════════════════════════════════════════
    //  MethodChannel
    // ══════════════════════════════════════════════════════════════════════

    private val methodCallHandler = MethodChannel.MethodCallHandler { call, result ->
        try {
            when (call.method) {
                "playPcmFile" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("bad_args", "path 不能为空", null)
                    } else {
                        val sampleRate = call.argument<Number>("sampleRate")?.toInt()
                            ?: DEFAULT_SAMPLE_RATE
                        val durationMs = startPlayback(path, sampleRate)
                        result.success(mapOf("durationMs" to durationMs))
                    }
                }

                "pause" -> result.success(pausePlayback())
                "resume" -> result.success(resumePlayback())
                "stop" -> result.success(stopPlayback())
                "seek" -> {
                    val positionMs = call.argument<Number>("positionMs")?.toInt() ?: 0
                    result.success(seekTo(positionMs))
                }

                "position" -> result.success(currentPositionMs())
                "setSpeed" -> {
                    val speed = call.argument<Number>("speed")?.toDouble() ?: 1.0
                    result.success(setSpeed(speed))
                }

                "recordStart" -> {
                    val sampleRate = call.argument<Number>("sampleRate")?.toInt()
                        ?: DEFAULT_SAMPLE_RATE
                    startRecording(sampleRate)
                    result.success(null)
                }

                // 录音前必须先拿运行期权限。单独做成一个方法，让 UI 在
                // 「用户按下麦克风」那一刻申请，而不是启动时弹框。
                "ensureRecordPermission" -> ensureRecordPermission(result)

                "recordStop" -> result.success(stopRecording())
                "recordCancel" -> {
                    finalizeRecording(discard = true)
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        } catch (e: SecurityException) {
            result.error("permission_denied", e.message ?: "缺少录音权限", null)
        } catch (e: Exception) {
            result.error("audio_error", e.message, e.javaClass.simpleName)
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  EventChannel
    // ══════════════════════════════════════════════════════════════════════

    private val playbackStreamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            playbackSink = events
        }

        override fun onCancel(arguments: Any?) {
            playbackSink = null
        }
    }

    private val recordStreamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            recordSink = events
        }

        override fun onCancel(arguments: Any?) {
            recordSink = null
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  播放
    // ══════════════════════════════════════════════════════════════════════

    private fun startPlayback(path: String, sampleRate: Int): Int {
        val file = File(path)
        if (!file.exists() || !file.isFile) {
            throw IllegalArgumentException("PCM 文件不存在: $path")
        }
        // 先彻底停掉上一段，确保旧 AudioTrack 被释放（否则第二次初始化报错）。
        stopPlaybackInternal(release = true)

        val totalBytes = file.length()
        val frames = totalBytes / BYTES_PER_FRAME
        val minBuf = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuf <= 0) {
            throw IllegalStateException("AudioTrack 缓冲区参数无效 (minBufferSize=$minBuf)")
        }
        val bufferSize = minBuf * 2

        @Suppress("DEPRECATION")
        val track = AudioTrack(
            AudioManager.STREAM_MUSIC,
            sampleRate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufferSize,
            AudioTrack.MODE_STREAM,
        )
        if (track.state != AudioTrack.STATE_INITIALIZED) {
            track.release()
            throw IllegalStateException("AudioTrack 初始化失败")
        }

        val now = SystemClock.elapsedRealtime()
        synchronized(lock) {
            audioTrack = track
            playSampleRate = sampleRate
            totalFrames = frames
            framesBase = 0L
            headZero = 0L
            writeDone = false
            paused = false
            stopped = false
            pendingSeekFrame = -1L
            lastHead = 0L
            lastHeadChangeMs = now
        }

        track.play()
        mainHandler.post(progressTicker)
        writerThread = Thread({ writeLoop(file, track) }, "penguinchat-audio-writer").also {
            it.isDaemon = true
            it.start()
        }
        return framesToMsWith(frames, sampleRate)
    }

    /**
     * 写线程：把文件按块灌进 AudioTrack。
     *
     * 用 AudioTrack.WRITE_NON_BLOCKING（API 23+）以便频繁检查 pause/seek/stop；
     * 旧系统退回阻塞写。写入进度不直接当播放位置——真正的播放位置由
     * getPlaybackHeadPosition 结合 headZero 计算，不受缓冲区预读影响。
     */
    private fun writeLoop(file: File, track: AudioTrack) {
        val chunkSize = 2048
        val buf = ByteArray(chunkSize)
        var bufOffset = 0
        var bufLen = 0
        try {
            FileInputStream(file).use { input ->
                synchronized(lock) { input.channel.position(framesBase * BYTES_PER_FRAME) }
                while (true) {
                    val seekFrame: Long
                    val pausedNow: Boolean
                    synchronized(lock) {
                        if (stopped) return
                        seekFrame = pendingSeekFrame
                        if (seekFrame >= 0) pendingSeekFrame = -1L
                        pausedNow = paused
                    }

                    if (seekFrame >= 0) {
                        applySeek(track, input, seekFrame, pausedNow)
                        bufOffset = 0
                        bufLen = 0
                        continue
                    }
                    if (pausedNow) {
                        Thread.sleep(10)
                        continue
                    }
                    if (bufOffset >= bufLen) {
                        bufLen = input.read(buf)
                        bufOffset = 0
                        if (bufLen <= 0) {
                            synchronized(lock) { writeDone = true }
                            return
                        }
                    }
                    val written = writeChunk(track, buf, bufOffset, bufLen - bufOffset)
                    if (written < 0) {
                        // 轨道出错：当作已写完，让 ticker 收尾，不让线程空转。
                        synchronized(lock) { writeDone = true }
                        return
                    }
                    if (written == 0) {
                        Thread.sleep(5)
                    } else {
                        bufOffset += written
                    }
                }
            }
        } catch (_: InterruptedException) {
            // stop() 打断，正常退出。
        } catch (_: Exception) {
            synchronized(lock) { writeDone = true }
        }
    }

    private fun applySeek(
        track: AudioTrack,
        input: FileInputStream,
        seekFrame: Long,
        pausedNow: Boolean,
    ) {
        try {
            track.pause()
        } catch (_: Exception) {
        }
        try {
            track.flush()
        } catch (_: Exception) {
        }
        synchronized(lock) {
            framesBase = seekFrame
            headZero = track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
        }
        input.channel.position(seekFrame * BYTES_PER_FRAME)
        if (!pausedNow) {
            try {
                track.play()
            } catch (_: Exception) {
            }
        }
    }

    private fun writeChunk(track: AudioTrack, buf: ByteArray, offset: Int, len: Int): Int =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            track.write(buf, offset, len, AudioTrack.WRITE_NON_BLOCKING)
        } else {
            track.write(buf, offset, len)
        }

    /** 每约 50ms 推一次进度；播完推 completed 并释放。 */
    private val progressTicker = object : Runnable {
        override fun run() {
            if (synchronized(lock) { stopped || audioTrack == null }) return

            val posFrames = synchronized(lock) { currentFramesLocked() }
            val posMs = framesToMsWith(posFrames, synchronized(lock) { playSampleRate })
            playbackSink?.success(mapOf("event" to "progress", "positionMs" to posMs))

            val complete = synchronized(lock) {
                when {
                    !writeDone || paused -> false
                    posFrames >= totalFrames -> true
                    else -> {
                        val now = SystemClock.elapsedRealtime()
                        if (posFrames != lastHead) {
                            lastHead = posFrames
                            lastHeadChangeMs = now
                            false
                        } else {
                            // 已写完全部数据且头位置 400ms 不动：判定播完。
                            now - lastHeadChangeMs > 400L
                        }
                    }
                }
            }

            if (complete) {
                playbackSink?.success(mapOf("event" to "completed", "positionMs" to posMs))
                stopPlaybackInternal(release = true)
                return
            }
            if (synchronized(lock) { !stopped }) {
                mainHandler.postDelayed(this, EVENT_INTERVAL_MS)
            }
        }
    }

    private fun currentFramesLocked(): Long {
        val track = audioTrack ?: return framesBase
        val head = track.playbackHeadPosition.toLong() and 0xFFFFFFFFL
        val rel = head - headZero
        if (rel < 0) return framesBase
        return framesBase + rel
    }

    private fun currentPositionMs(): Int =
        synchronized(lock) { framesToMsWith(currentFramesLocked(), playSampleRate) }

    private fun pausePlayback(): Int {
        synchronized(lock) {
            val track = audioTrack
            if (track != null && !paused && !stopped) {
                paused = true
                lastHead = currentFramesLocked()
                lastHeadChangeMs = SystemClock.elapsedRealtime()
                try {
                    track.pause()
                } catch (_: Exception) {
                }
            }
        }
        return currentPositionMs()
    }

    private fun resumePlayback(): Int {
        synchronized(lock) {
            val track = audioTrack
            if (track != null && paused && !stopped) {
                paused = false
                try {
                    track.play()
                } catch (_: Exception) {
                }
            }
        }
        return currentPositionMs()
    }

    private fun stopPlayback(): Int {
        val pos = currentPositionMs()
        stopPlaybackInternal(release = true)
        return pos
    }

    private fun seekTo(positionMs: Int): Int {
        synchronized(lock) {
            val track = audioTrack
            if (track == null || stopped) return 0
            val frame = (positionMs.toLong() * playSampleRate / 1000L)
                .coerceIn(0L, if (totalFrames > 0) totalFrames else 0L)
            pendingSeekFrame = frame
            return framesToMsWith(frame, playSampleRate)
        }
    }

    private fun setSpeed(speed: Double): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        val track = synchronized(lock) { audioTrack } ?: return false
        return try {
            val params = track.playbackParams
            params.setSpeed(speed.toFloat())
            track.playbackParams = params
            true
        } catch (_: Exception) {
            false
        }
    }

    /** 停播并（可选）释放 AudioTrack。这是第二次能正常播放的前提。 */
    private fun stopPlaybackInternal(release: Boolean) {
        val track: AudioTrack?
        val thread: Thread?
        synchronized(lock) {
            stopped = true
            pendingSeekFrame = -1L
            writeDone = false
            paused = false
            track = audioTrack
            thread = writerThread
            audioTrack = null
            writerThread = null
        }
        mainHandler.removeCallbacks(progressTicker)
        try {
            thread?.interrupt()
        } catch (_: Exception) {
        }
        try {
            thread?.join(300)
        } catch (_: InterruptedException) {
        }
        if (release && track != null) {
            try {
                track.pause()
            } catch (_: Exception) {
            }
            try {
                track.flush()
            } catch (_: Exception) {
            }
            try {
                track.stop()
            } catch (_: Exception) {
            }
            try {
                track.release()
            } catch (_: Exception) {
            }
        }
    }

    // ══════════════════════════════════════════════════════════════════════
    //  录音
    // ══════════════════════════════════════════════════════════════════════

    private fun hasRecordPermission(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            context.checkPermission(
                Manifest.permission.RECORD_AUDIO,
                Process.myPid(),
                Process.myUid(),
            ) == PackageManager.PERMISSION_GRANTED
        }

    private fun startRecording(sampleRate: Int) {
        if (!hasRecordPermission()) {
            throw SecurityException("未授予 RECORD_AUDIO 录音权限")
        }
        // 先清掉上一次（若有）。
        finalizeRecording(discard = true)

        val minBuf = AudioRecord.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuf <= 0) {
            throw IllegalStateException("AudioRecord 缓冲区参数无效 (minBufferSize=$minBuf)")
        }
        val bufferSize = maxOf(minBuf * 2, 4096)

        @Suppress("DEPRECATION")
        val rec = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufferSize,
        )
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            throw IllegalStateException("AudioRecord 初始化失败（麦克风可能被占用）")
        }

        val file = File(context.cacheDir, "penguinchat_rec_" + System.currentTimeMillis() + ".pcm")
        synchronized(recordLock) {
            audioRecord = rec
            recordFile = file
            recordSampleRate = sampleRate
            recordFrames = 0L
            recordStopped = false
            recordWindowPeak = 0
        }
        rec.startRecording()
        mainHandler.post(recordTicker)
        recordThread = Thread({ recordLoop(rec, file) }, "penguinchat-audio-recorder").also {
            it.isDaemon = true
            it.start()
        }
    }

    private fun recordLoop(rec: AudioRecord, file: File) {
        val bufSize = 2048
        val buf = ShortArray(bufSize)
        try {
            file.outputStream().buffered().use { out ->
                while (true) {
                    if (synchronized(recordLock) { recordStopped }) break
                    val n = rec.read(buf, 0, bufSize)
                    if (n <= 0) {
                        if (n == AudioRecord.ERROR_INVALID_OPERATION ||
                            n == AudioRecord.ERROR_BAD_VALUE
                        ) {
                            break
                        }
                        continue
                    }
                    val bytes = ByteArray(n * 2)
                    var peak = 0
                    for (i in 0 until n) {
                        val s = buf[i].toInt()
                        val a = if (s == Short.MIN_VALUE.toInt()) 32768 else abs(s)
                        if (a > peak) peak = a
                        bytes[i * 2] = (s and 0xFF).toByte()
                        bytes[i * 2 + 1] = ((s shr 8) and 0xFF).toByte()
                    }
                    out.write(bytes)
                    synchronized(recordLock) {
                        recordFrames += n.toLong()
                        if (peak > recordWindowPeak) recordWindowPeak = peak
                    }
                }
            }
        } catch (_: Exception) {
            // 停止/释放时的竞态，忽略；由 finalize 收尾。
        }
    }

    private val recordTicker = object : Runnable {
        override fun run() {
            val active = synchronized(recordLock) { !recordStopped && audioRecord != null }
            if (!active) return
            val frames: Long
            val peak: Int
            val rate: Int
            synchronized(recordLock) {
                frames = recordFrames
                peak = recordWindowPeak
                recordWindowPeak = 0
                rate = recordSampleRate
            }
            val amplitude = (peak.toDouble() / 32768.0).coerceIn(0.0, 1.0)
            recordSink?.success(
                mapOf(
                    "durationMs" to framesToMsWith(frames, rate),
                    "amplitude" to amplitude,
                ),
            )
            if (synchronized(recordLock) { !recordStopped }) {
                mainHandler.postDelayed(this, EVENT_INTERVAL_MS)
            }
        }
    }

    private fun stopRecording(): Map<String, Any?>? {
        val hasActive = synchronized(recordLock) { audioRecord != null }
        if (!hasActive) return null
        val (file, frames, rate) = finalizeRecording(discard = false)
        if (file == null) return null
        val size = if (file.exists()) file.length() else 0L
        return mapOf(
            "path" to file.absolutePath,
            "durationMs" to framesToMsWith(frames, rate),
            "size" to size,
        )
    }

    /**
     * 结束录音：停掉线程、释放 AudioRecord、必要时删文件。
     *
     * 顺序很重要：先 rec.stop() 让阻塞中的 read() 返回，再 join，
     * 最后 release()。反过来 join 会卡在 read 上。
     */
    private fun finalizeRecording(discard: Boolean): Triple<File?, Long, Int> {
        val rec: AudioRecord?
        val thread: Thread?
        val file: File?
        val rate: Int
        synchronized(recordLock) {
            recordStopped = true
            rec = audioRecord
            thread = recordThread
            file = recordFile
            rate = recordSampleRate
            audioRecord = null
            recordThread = null
            recordFile = null
        }
        mainHandler.removeCallbacks(recordTicker)
        try {
            rec?.stop()
        } catch (_: Exception) {
        }
        try {
            thread?.interrupt()
        } catch (_: Exception) {
        }
        try {
            thread?.join(500)
        } catch (_: InterruptedException) {
        }
        try {
            rec?.release()
        } catch (_: Exception) {
        }
        val frames = synchronized(recordLock) { recordFrames }
        if (discard) {
            try {
                file?.delete()
            } catch (_: Exception) {
            }
        }
        return Triple(file, frames, rate)
    }

    // ══════════════════════════════════════════════════════════════════════
    //  工具
    // ══════════════════════════════════════════════════════════════════════

    private fun framesToMsWith(frames: Long, rate: Int): Int {
        if (rate <= 0) return 0
        return ((frames * 1000L) / rate).toInt()
    }

    // ══════════════════════════════════════════════════════════════════════
    //  录音权限（运行期）
    // ══════════════════════════════════════════════════════════════════════

    /** 等待用户点「允许/拒绝」的那个 MethodChannel 回调。 */
    private var pendingPermissionResult: MethodChannel.Result? = null

    private fun ensureRecordPermission(result: MethodChannel.Result) {
        if (hasRecordPermission()) {
            result.success(true)
            return
        }
        val activity = context as? Activity
        if (activity == null) {
            result.success(false)
            return
        }
        // MethodChannel 的 result 只能完成一次：已经有一个在等就直接返回 false，
        // 否则前一个永远不完成（Dart 侧 Future 永不 resolve）。
        if (pendingPermissionResult != null) {
            result.success(false)
            return
        }
        pendingPermissionResult = result
        activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), RECORD_PERM_CODE)
    }

    /** 由 Activity.onRequestPermissionsResult 转发进来。 */
    fun onRequestPermissionsResult(
        requestCode: Int,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != RECORD_PERM_CODE) return false
        val result = pendingPermissionResult ?: return true
        pendingPermissionResult = null
        result.success(
            grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
        )
        return true
    }

}
