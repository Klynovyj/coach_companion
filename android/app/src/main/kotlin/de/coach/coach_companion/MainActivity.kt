package de.coach.coach_companion

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Rect
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.Surface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.nio.ByteBuffer

class MainActivity : FlutterActivity() {
    private var encoder: GraphicVideoEncoder? = null
    private var thread: HandlerThread? = null
    private var worker: Handler? = null
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "coach_companion/video",
        ).setMethodCallHandler { call, result ->
            // Alles Kodieren auf einem eigenen Thread – nie auf dem UI-Thread.
            val h = worker ?: HandlerThread("graphic-video").also {
                it.start()
                thread = it
            }.let { Handler(it.looper) }.also { worker = it }
            h.post {
                try {
                    val out: Any? = when (call.method) {
                        "start" -> {
                            encoder?.cancel()
                            val e = GraphicVideoEncoder(
                                call.argument<String>("path")!!,
                                call.argument<Int>("width")!!,
                                call.argument<Int>("height")!!,
                                call.argument<Int>("fps") ?: 30,
                                call.argument<Int>("bitrate") ?: 8_000_000,
                                call.argument<String>("bgVideo"),
                            )
                            encoder = e
                            true
                        }
                        "frame" -> {
                            val e = encoder ?: throw IllegalStateException("not started")
                            e.frame(
                                call.argument<ByteArray>("rgba")!!,
                                call.argument<Int>("index")!!,
                            )
                            null
                        }
                        "finish" -> {
                            val e = encoder ?: throw IllegalStateException("not started")
                            encoder = null
                            e.finish()
                        }
                        "cancel" -> {
                            encoder?.cancel()
                            encoder = null
                            null
                        }
                        else -> {
                            main.post { result.notImplemented() }
                            return@post
                        }
                    }
                    main.post { result.success(out) }
                } catch (t: Throwable) {
                    encoder?.cancel()
                    encoder = null
                    main.post { result.error("video", t.message ?: t.toString(), null) }
                }
            }
        }
    }

    override fun onDestroy() {
        encoder?.cancel()
        encoder = null
        thread?.quitSafely()
        super.onDestroy()
    }
}

/// H.264-MP4 aus einzelnen RGBA-Frames (premultiplied, wie Flutters
/// `ImageByteFormat.rawRgba`). Optional liegt ein Video (z. B. KI-Video) als
/// bewegter Hintergrund darunter.
class GraphicVideoEncoder(
    private val path: String,
    w: Int,
    h: Int,
    private val fps: Int,
    bitrate: Int,
    bgVideo: String?,
) {
    private val width = w - (w % 2)
    private val height = h - (h % 2)
    private val srcW = w
    private val srcH = h
    private val codec: MediaCodec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    private val surface: Surface
    private val muxer = MediaMuxer(path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
    private var track = -1
    private var muxing = false
    private val info = MediaCodec.BufferInfo()
    private val bitmap = Bitmap.createBitmap(srcW, srcH, Bitmap.Config.ARGB_8888)
    private var retriever: MediaMetadataRetriever? = null
    private var bgDurationUs = 0L

    init {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
        format.setInteger(
            MediaFormat.KEY_COLOR_FORMAT,
            MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface,
        )
        format.setInteger(MediaFormat.KEY_BIT_RATE, bitrate)
        format.setInteger(MediaFormat.KEY_FRAME_RATE, fps)
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        surface = codec.createInputSurface()
        codec.start()
        if (bgVideo != null && File(bgVideo).exists()) {
            val r = MediaMetadataRetriever()
            r.setDataSource(bgVideo)
            bgDurationUs =
                (r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull()
                    ?: 0L) * 1000L
            retriever = r
        }
    }

    fun frame(rgba: ByteArray, index: Int) {
        bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(rgba))
        val canvas: Canvas =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                surface.lockHardwareCanvas()
            } else {
                surface.lockCanvas(null)
            }
        try {
            canvas.drawColor(Color.BLACK)
            val dst = Rect(0, 0, width, height)
            val r = retriever
            if (r != null && bgDurationUs > 0) {
                var us = index * 1_000_000L / fps
                us %= bgDurationUs // kürzeres Video in Schleife
                val bg = r.getFrameAtTime(us, MediaMetadataRetriever.OPTION_CLOSEST)
                if (bg != null) {
                    canvas.drawBitmap(bg, coverRect(bg.width, bg.height), dst, null)
                    bg.recycle()
                }
            }
            canvas.drawBitmap(bitmap, Rect(0, 0, width, height), dst, null)
        } finally {
            surface.unlockCanvasAndPost(canvas)
        }
        drain(false)
    }

    /// Ausschnitt des Hintergrundvideos, der das Ziel vollständig füllt (cover).
    private fun coverRect(bw: Int, bh: Int): Rect {
        val target = width.toDouble() / height
        val src = bw.toDouble() / bh
        return if (src > target) {
            val cw = (bh * target).toInt()
            val x = (bw - cw) / 2
            Rect(x, 0, x + cw, bh)
        } else {
            val ch = (bw / target).toInt()
            val y = (bh - ch) / 2
            Rect(0, y, bw, y + ch)
        }
    }

    private var ptsIndex = 0L

    private fun drain(end: Boolean) {
        if (end) codec.signalEndOfInputStream()
        while (true) {
            val idx = codec.dequeueOutputBuffer(info, if (end) 10_000 else 0)
            when {
                idx == MediaCodec.INFO_TRY_AGAIN_LATER -> if (!end) return
                idx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    track = muxer.addTrack(codec.outputFormat)
                    muxer.start()
                    muxing = true
                }
                idx >= 0 -> {
                    val buf = codec.getOutputBuffer(idx)
                    val config = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    if (buf != null && info.size > 0 && muxing && !config) {
                        // Gleichmäßige Zeitstempel (Frame-Nummer / fps).
                        info.presentationTimeUs = ptsIndex * 1_000_000L / fps
                        ptsIndex++
                        buf.position(info.offset)
                        buf.limit(info.offset + info.size)
                        muxer.writeSampleData(track, buf, info)
                    }
                    codec.releaseOutputBuffer(idx, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
                }
                else -> {} // z. B. veraltetes OUTPUT_BUFFERS_CHANGED
            }
        }
    }

    fun finish(): String {
        try {
            drain(true)
        } finally {
            release()
        }
        return path
    }

    fun cancel() {
        try {
            release()
        } catch (_: Throwable) {
        }
        File(path).delete()
    }

    private var released = false

    private fun release() {
        if (released) return
        released = true
        try { codec.stop() } catch (_: Throwable) {}
        codec.release()
        surface.release()
        if (muxing) {
            try { muxer.stop() } catch (_: Throwable) {}
        }
        muxer.release()
        retriever?.release()
        bitmap.recycle()
    }
}
