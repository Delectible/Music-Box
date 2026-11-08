package com.dingo.roadie

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import org.jaudiotagger.audio.AudioFileIO
import java.io.File
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.log10
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Volume levelling. ReplayGain from the file's tags when it has them,
 * otherwise the song's loudness measured the broadcast way (ITU-R BS.1770:
 * K-weighted, 400 ms blocks, gated), in LUFS.
 */
object Loudness {
    private val number = Regex("""[-+]?\d+(?:\.\d+)?""")

    /** {trackGain, albumGain} in dB from ReplayGain tags (missing = absent). */
    fun tags(path: String): Map<String, Double> {
        val out = HashMap<String, Double>()
        try {
            Tags // TagOptionSingleton set up for Android
            val tag = AudioFileIO.read(File(path)).tag ?: return out
            for (f in tag.fields) {
                val text = f.toString()
                val key = (f.id + " " + text).uppercase()
                val which = when {
                    key.contains("REPLAYGAIN_TRACK_GAIN") -> "trackGain"
                    key.contains("REPLAYGAIN_ALBUM_GAIN") -> "albumGain"
                    else -> continue
                }
                val v = number.find(text.substringAfter("GAIN", text).ifEmpty { text })?.value?.toDoubleOrNull()
                    ?: number.find(text)?.value?.toDoubleOrNull() ?: continue
                out[which] = v
            }
        } catch (_: Throwable) {
        }
        return out
    }

    private class Biquad(val b0: Double, val b1: Double, val b2: Double, val a1: Double, val a2: Double) {
        var x1 = 0.0; var x2 = 0.0; var y1 = 0.0; var y2 = 0.0
        fun run(x: Double): Double {
            val y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }

    /** The two K-weighting filters for [fs] Hz (pre-filter shelf, then high pass). */
    private fun kWeighting(fs: Double): Pair<Biquad, Biquad> {
        run {
            // Stage 1: high shelf, +4 dB above ~1.7 kHz (the head).
            val g = 3.999843853973347; val q = 0.7071752369554196; val fc = 1681.974450955533
            val a = 10.0.pow(g / 40); val w = 2 * PI * fc / fs; val alpha = sin(w) / (2 * q); val c = cos(w)
            val sa = 2 * sqrt(a) * alpha
            val a0 = (a + 1) - (a - 1) * c + sa
            val shelf = Biquad(
                a * ((a + 1) + (a - 1) * c + sa) / a0,
                -2 * a * ((a - 1) + (a + 1) * c) / a0,
                a * ((a + 1) + (a - 1) * c - sa) / a0,
                2 * ((a - 1) - (a + 1) * c) / a0,
                ((a + 1) - (a - 1) * c - sa) / a0,
            )
            // Stage 2: high pass at ~38 Hz.
            val q2 = 0.5003270373238773; val fc2 = 38.13547087602444
            val w2 = 2 * PI * fc2 / fs; val al2 = sin(w2) / (2 * q2); val c2 = cos(w2)
            val b0 = 1 + al2
            val hp = Biquad((1 + c2) / 2 / b0, -(1 + c2) / b0, (1 + c2) / 2 / b0, -2 * c2 / b0, (1 - al2) / b0)
            return shelf to hp
        }
    }

    /** Integrated loudness of the file in LUFS, or null if it can't be decoded. */
    fun measure(path: String): Double? {
        val ex = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            ex.setDataSource(path)
            val track = (0 until ex.trackCount).firstOrNull {
                ex.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
            } ?: return null
            ex.selectTrack(track)
            val inFmt = ex.getTrackFormat(track)
            codec = MediaCodec.createDecoderByType(inFmt.getString(MediaFormat.KEY_MIME)!!)
            codec.configure(inFmt, null, null, 0)
            codec.start()

            var fs = inFmt.getInteger(MediaFormat.KEY_SAMPLE_RATE).toDouble()
            var ch = inFmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            var float = false
            var filters = Array(ch) { kWeighting(fs) }
            var blockLen = (fs * 0.1).toInt() // 100 ms steps; a block is 4 steps (75% overlap)
            val steps = ArrayList<Double>() // sum of channel mean squares per 100 ms
            var acc = DoubleArray(ch); var n = 0

            val info = MediaCodec.BufferInfo()
            var inDone = false; var outDone = false
            while (!outDone) {
                if (!inDone) {
                    val i = codec.dequeueInputBuffer(10_000)
                    if (i >= 0) {
                        val buf = codec.getInputBuffer(i)!!
                        val size = ex.readSampleData(buf, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(i, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM); inDone = true
                        } else {
                            codec.queueInputBuffer(i, 0, size, ex.sampleTime, 0); ex.advance()
                        }
                    }
                }
                val o = codec.dequeueOutputBuffer(info, 10_000)
                if (o == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    val f = codec.outputFormat
                    fs = f.getInteger(MediaFormat.KEY_SAMPLE_RATE).toDouble()
                    ch = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                    float = f.containsKey(MediaFormat.KEY_PCM_ENCODING) &&
                        f.getInteger(MediaFormat.KEY_PCM_ENCODING) == AudioFormat.ENCODING_PCM_FLOAT
                    filters = Array(ch) { kWeighting(fs) }
                    blockLen = (fs * 0.1).toInt(); acc = DoubleArray(ch); n = 0
                } else if (o >= 0) {
                    val buf = codec.getOutputBuffer(o)!!.order(ByteOrder.nativeOrder())
                    buf.position(info.offset); buf.limit(info.offset + info.size)
                    if (float) {
                        val fb = buf.asFloatBuffer()
                        while (fb.remaining() >= ch) {
                            for (c in 0 until ch) {
                                val y = filters[c].second.run(filters[c].first.run(fb.get().toDouble()))
                                if (c < 2 || ch <= 2) acc[c] += y * y
                            }
                            if (++n == blockLen) { steps += acc.sum() / n; acc = DoubleArray(ch); n = 0 }
                        }
                    } else {
                        val sb = buf.asShortBuffer()
                        while (sb.remaining() >= ch) {
                            for (c in 0 until ch) {
                                val y = filters[c].second.run(filters[c].first.run(sb.get() / 32768.0))
                                if (c < 2 || ch <= 2) acc[c] += y * y
                            }
                            if (++n == blockLen) { steps += acc.sum() / n; acc = DoubleArray(ch); n = 0 }
                        }
                    }
                    codec.releaseOutputBuffer(o, false)
                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) outDone = true
                }
            }
            // 400 ms blocks every 100 ms, then the two gates.
            val blocks = ArrayList<Double>()
            for (i in 0..steps.size - 4) blocks += (steps[i] + steps[i + 1] + steps[i + 2] + steps[i + 3]) / 4
            fun lufs(ms: Double) = -0.691 + 10 * log10(ms)
            val abs = blocks.filter { it > 0 && lufs(it) > -70 }
            if (abs.isEmpty()) return null
            val rel = lufs(abs.average()) - 10
            val gated = abs.filter { lufs(it) > rel }
            return lufs((if (gated.isEmpty()) abs else gated).average())
        } catch (_: Throwable) {
            return null
        } finally {
            try { codec?.stop() } catch (_: Throwable) {}
            try { codec?.release() } catch (_: Throwable) {}
            ex.release()
        }
    }
}
