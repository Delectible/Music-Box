package com.dingo.roadie

import android.app.Application
import android.content.Context
import android.os.Build
import androidx.work.Configuration
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.util.Date

/**
 * Catches crashes from the very start (before any screen), so they show
 * under Settings > Problem reports next time; and starts WorkManager (the
 * daily yt-dlp update check) only when it's first used, not at every
 * launch: if it ever fails, the app still opens.
 */
class RoadieApp : Application(), Configuration.Provider {
    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, e ->
            try {
                val sw = StringWriter()
                e.printStackTrace(PrintWriter(sw))
                File(base.filesDir, "native_crash.txt").appendText(
                    "=== ${Date()} (thread ${thread.name}, Android ${Build.VERSION.SDK_INT}, " +
                        "${Build.MANUFACTURER} ${Build.MODEL})\n$sw\n",
                )
            } catch (_: Throwable) {
            }
            previous?.uncaughtException(thread, e)
        }
    }

    override val workManagerConfiguration: Configuration
        get() = Configuration.Builder().build()
}
