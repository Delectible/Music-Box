package com.dingo.roadie

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * A "Downloading" notification while Get music has work, so Android keeps
 * Roadie's network and CPU going with the screen off or in another app.
 */
class DownloadService : Service() {
    private var wake: PowerManager.WakeLock? = null
    private var wifi: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val active = intent?.getIntExtra("active", 0) ?: 0
        val done = intent?.getIntExtra("done", 0) ?: 0
        if (active <= 0) {
            stopSelf()
            return START_NOT_STICKY
        }
        running = true
        val n = notification(this, active, done)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(ID, n)
        }
        if (wake == null) {
            wake = (getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "roadie:downloads").apply {
                    setReferenceCounted(false)
                    acquire(3 * 60 * 60 * 1000L)
                }
        }
        if (wifi == null) {
            @Suppress("DEPRECATION")
            wifi = (applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager)
                .createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "roadie:downloads").apply {
                    setReferenceCounted(false)
                    acquire()
                }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        try { wake?.release() } catch (_: Exception) {}
        try { wifi?.release() } catch (_: Exception) {}
        wake = null
        wifi = null
        super.onDestroy()
    }

    companion object {
        private const val ID = 4107
        private const val CHANNEL = "com.dingo.roadie.downloads"
        @Volatile private var running = false

        /** Starts, refreshes or stops the service. Refreshing only re-posts the
         * notification: Android 12+ won't start services from the background. */
        fun update(context: Context, active: Int, done: Int) {
            val i = Intent(context, DownloadService::class.java).putExtra("active", active).putExtra("done", done)
            when {
                active <= 0 -> context.stopService(i)
                running -> (context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                    .notify(ID, notification(context, active, done))
                Build.VERSION.SDK_INT >= 26 -> context.startForegroundService(i)
                else -> context.startService(i)
            }
        }

    private fun notification(context: Context, active: Int, done: Int): Notification {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(
                NotificationChannel(CHANNEL, "Downloads", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val open = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL)
        else @Suppress("DEPRECATION") Notification.Builder(context)
        return b.setSmallIcon(R.drawable.ic_stat_roadie)
            .setContentTitle("Downloading $active ${if (active == 1) "song" else "songs"}")
            .setContentText(if (done > 0) "$done done so far" else "Getting music")
            .setOngoing(true)
            .setContentIntent(open)
            .build()
    }
    }
}
