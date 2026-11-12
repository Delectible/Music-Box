package com.dingo.roadie

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.plugin.common.MethodChannel
import org.json.JSONTokener

/**
 * A hidden browser that repeats the steps a person taught Roadie for a site
 * (lib/core/recipe.dart): open a page, find a link or button, press it, and
 * catch where it leads: a new page or a file. It shares cookies with the
 * visible browser, so a sign-in done there carries over. Main thread only.
 */
class PageRunner(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private var web: WebView? = null

    // What the current load / click is waiting for.
    private var waiting: MethodChannel.Result? = null
    private var waitingFor = ""          // "load" or "click"
    private var startUrl = ""
    private var settle: Runnable? = null
    private var timeout: Runnable? = null

    private val audio = Regex("""\.(mp3|flac|m4a|aac|ogg|oga|opus|wav|aiff?)(\?|#|$)""", RegexOption.IGNORE_CASE)

    @SuppressLint("SetJavaScriptEnabled")
    private fun view(): WebView = web ?: WebView(context).also { w ->
        w.settings.javaScriptEnabled = true
        w.settings.domStorageEnabled = true
        w.settings.mediaPlaybackRequiresUserGesture = true
        w.settings.setSupportMultipleWindows(false) // target=_blank opens here
        CookieManager.getInstance().setAcceptThirdPartyCookies(w, true)
        w.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val url = request.url.toString()
                // A music file: that's the answer; don't open it as a page.
                if (waitingFor == "click" && audio.containsMatchIn(request.url.path ?: url)) {
                    finish(mapOf("kind" to "download", "url" to url))
                    return true
                }
                return false
            }

            override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
                settle?.let { main.removeCallbacks(it) }
            }

            override fun onPageFinished(view: WebView, url: String) {
                if (waiting == null) return
                if (waitingFor == "click" && url == startUrl) return // still the same page
                // Give scripts a moment to fill the page in.
                settle?.let { main.removeCallbacks(it) }
                settle = Runnable {
                    finish(mapOf("kind" to if (waitingFor == "click") "nav" else "load", "url" to (view.url ?: url)))
                }.also { main.postDelayed(it, 1500) }
            }
        }
        // A button that downloads (Content-Disposition: attachment).
        w.setDownloadListener { url, _, _, _, _ ->
            if (waiting != null) finish(mapOf("kind" to "download", "url" to url))
        }
        web = w
    }

    private fun finish(value: Map<String, Any?>) {
        val r = waiting ?: return
        waiting = null
        waitingFor = ""
        settle?.let { main.removeCallbacks(it) }
        timeout?.let { main.removeCallbacks(it) }
        r.success(value)
    }

    private fun arm(result: MethodChannel.Result, kind: String, ms: Long) {
        waiting?.success(mapOf("kind" to "none", "url" to (web?.url ?: ""))) // replaced
        waiting = result
        waitingFor = kind
        startUrl = web?.url ?: ""
        timeout = Runnable { finish(mapOf("kind" to "none", "url" to (web?.url ?: ""))) }.also {
            main.postDelayed(it, ms)
        }
    }

    /** Opens [url]; answers {kind: load|none, url} once it has settled. */
    fun load(url: String, ms: Long, result: MethodChannel.Result) {
        val w = view()
        arm(result, "load", ms)
        w.loadUrl(url)
    }

    /** Runs [code] in the page; answers its (string) result. */
    fun eval(code: String, result: MethodChannel.Result) {
        view().evaluateJavascript(code) { v ->
            try {
                val decoded = if (v == null || v == "null") null else JSONTokener(v).nextValue()
                result.success(decoded?.toString())
            } catch (e: Exception) {
                result.error("js", e.message, v?.take(500))
            }
        }
    }

    /**
     * Runs [code] (which clicks something) and answers where it led:
     * {kind: download|nav|none, url}. Waits up to [ms] (countdown pages).
     */
    fun click(code: String, ms: Long, result: MethodChannel.Result) {
        val w = view()
        arm(result, "click", ms)
        w.evaluateJavascript(code, null)
    }

    /** Cookies the site set (for downloading the file outside the WebView). */
    fun cookies(url: String): String? = CookieManager.getInstance().getCookie(url)

    fun dispose() {
        waiting?.success(mapOf("kind" to "none", "url" to ""))
        waiting = null
        web?.destroy()
        web = null
    }
}
