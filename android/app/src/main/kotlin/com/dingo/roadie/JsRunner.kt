package com.dingo.roadie

import android.annotation.SuppressLint
import android.content.Context
import android.webkit.WebView
import io.flutter.plugin.common.MethodChannel
import org.json.JSONTokener

/**
 * A hidden WebView used as a JavaScript engine: it runs YouTube's stream
 * challenges (yt-dlp's solver) so the browser-type YouTube clients work.
 */
class JsRunner(private val context: Context) {
    private var web: WebView? = null
    private var ready = false

    @SuppressLint("SetJavaScriptEnabled")
    private fun view(): WebView = web ?: WebView(context).also {
        it.settings.javaScriptEnabled = true
        it.loadData("<html><body></body></html>", "text/html", "utf-8")
        web = it
    }

    /** Loads the solver (once). Must be called on the main thread. */
    fun init(script: String, result: MethodChannel.Result) {
        if (ready) return result.success(true)
        view().evaluateJavascript("$script\n;true") { v ->
            ready = v == "true"
            result.success(ready)
        }
    }

    /** Runs [code] and returns its (string) result. Main thread. */
    fun eval(code: String, result: MethodChannel.Result) {
        view().evaluateJavascript(code) { v ->
            try {
                // evaluateJavascript hands back the value JSON-encoded.
                val decoded = if (v == null || v == "null") null else JSONTokener(v).nextValue()
                result.success(decoded?.toString())
            } catch (e: Exception) {
                result.error("js", e.message, v?.take(500))
            }
        }
    }

    fun dispose() {
        web?.destroy()
        web = null
        ready = false
    }
}
