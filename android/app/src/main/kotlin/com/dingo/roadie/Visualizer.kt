package com.dingo.roadie

import android.media.audiofx.Visualizer
import io.flutter.plugin.common.EventChannel

/**
 * Streams the playing sound's spectrum and waveform (Android's Visualizer on
 * the player's audio session) to the visualiser screen, about 20 times a second.
 */
class VizStream : EventChannel.StreamHandler {
    private var viz: Visualizer? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        stop()
        val session = (arguments as? Number)?.toInt() ?: 0
        try {
            val v = Visualizer(session)
            v.setEnabled(false)
            v.setCaptureSize(Visualizer.getCaptureSizeRange()[1].coerceAtMost(1024))
            v.setDataCaptureListener(object : Visualizer.OnDataCaptureListener {
                override fun onWaveFormDataCapture(vz: Visualizer, wave: ByteArray, rate: Int) {
                    events.success(mapOf("wave" to wave))
                }

                override fun onFftDataCapture(vz: Visualizer, fft: ByteArray, rate: Int) {
                    events.success(mapOf("fft" to fft))
                }
            }, Visualizer.getMaxCaptureRate(), true, true)
            v.setEnabled(true)
            viz = v
        } catch (e: Throwable) {
            events.error("viz", e.message ?: e.toString(), null)
        }
    }

    override fun onCancel(arguments: Any?) = stop()

    fun stop() {
        try {
            viz?.setEnabled(false)
            viz?.release()
        } catch (_: Throwable) {
        }
        viz = null
    }
}
