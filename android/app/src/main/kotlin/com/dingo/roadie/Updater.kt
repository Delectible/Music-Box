package com.dingo.roadie

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.StatFs
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

/**
 * Updates for the APK from GitHub Releases (channel `roadie/update`): how
 * Roadie was installed, checking a downloaded APK, and handing it to
 * Android's installer. The download itself is done in Dart.
 */
object Updater {
    private val stores = setOf("com.android.vending", "com.google.android.feedback")

    fun handle(a: Activity, call: MethodCall, result: MethodChannel.Result, background: (() -> Any?) -> Unit) {
        when (call.method) {
            "info" -> result.success(info(a))
            "check" -> background { check(a, call.argument<String>("path") ?: "") }
            "allowInstalls" -> {
                val pkg = Uri.parse("package:${a.packageName}")
                val ok = start(a, Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, pkg)) ||
                    start(a, Intent(Settings.ACTION_SECURITY_SETTINGS))
                result.success(ok)
            }
            "install" -> {
                try {
                    val file = File(call.argument<String>("path") ?: "")
                    val uri = FileProvider.getUriForFile(a, "${a.packageName}.updates", file)
                    val i = Intent(Intent.ACTION_VIEW)
                        .setDataAndType(uri, "application/vnd.android.package-archive")
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                    a.startActivity(i)
                    result.success(true)
                } catch (e: ActivityNotFoundException) {
                    result.error("update", "This device has no app installer to open the update with.", null)
                } catch (e: Exception) {
                    result.error("update", e.message ?: e.toString(), null)
                }
            }
            "openUrl" -> result.success(start(a, Intent(Intent.ACTION_VIEW, Uri.parse(call.argument<String>("url") ?: ""))))
            else -> result.notImplemented()
        }
    }

    private fun start(a: Activity, i: Intent): Boolean = try {
        a.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (_: Exception) {
        false
    }

    @Suppress("DEPRECATION")
    private fun packageInfo(pm: PackageManager, pkg: String, flags: Int): PackageInfo =
        if (Build.VERSION.SDK_INT >= 33) pm.getPackageInfo(pkg, PackageManager.PackageInfoFlags.of(flags.toLong()))
        else pm.getPackageInfo(pkg, flags)

    @Suppress("DEPRECATION")
    private fun code(p: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) p.longVersionCode else p.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun info(a: Activity): Map<String, Any?> {
        val pm = a.packageManager
        val installer = try {
            if (Build.VERSION.SDK_INT >= 30) pm.getInstallSourceInfo(a.packageName).installingPackageName
            else pm.getInstallerPackageName(a.packageName)
        } catch (_: Exception) {
            null
        }
        val p = packageInfo(pm, a.packageName, PackageManager.GET_PERMISSIONS)
        val store = installer != null && installer in stores
        val declared = p.requestedPermissions?.contains(Manifest.permission.REQUEST_INSTALL_PACKAGES) == true
        val dir = File(a.cacheDir, "updates")
        val free = try { StatFs(a.cacheDir.path).availableBytes } catch (_: Exception) { -1L }
        return mapOf(
            "installer" to installer,
            "fromStore" to store,
            "canUpdate" to (declared && !store),
            "canInstall" to pm.canRequestPackageInstalls(),
            "versionCode" to code(p),
            "versionName" to p.versionName,
            "dir" to dir.path,
            "freeBytes" to free,
        )
    }

    /** What's in a downloaded APK: is it Roadie, which build, signed by the same key, its SHA-256. */
    @Suppress("DEPRECATION")
    private fun check(a: Activity, path: String): Map<String, Any?> {
        val pm = a.packageManager
        val f = File(path)
        val out = HashMap<String, Any?>()
        out["sha256"] = sha256(f)
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val apk = pm.getPackageArchiveInfo(path, flags)
        out["valid"] = apk != null
        if (apk == null) return out
        out["package"] = apk.packageName
        out["versionCode"] = code(apk)
        val mine = signers(packageInfo(pm, a.packageName, flags))
        val theirs = signers(apk)
        // Unknown (some Android versions don't read an APK's signer) counts as fine:
        // the installer checks it again anyway.
        out["sameSigner"] = if (mine.isEmpty() || theirs.isEmpty()) null else mine == theirs
        return out
    }

    @Suppress("DEPRECATION")
    private fun signers(p: PackageInfo): Set<String> {
        val sigs = if (Build.VERSION.SDK_INT >= 28) {
            p.signingInfo?.let { if (it.hasMultipleSigners()) it.apkContentsSigners else it.signingCertificateHistory }
        } else {
            p.signatures
        } ?: return emptySet()
        return sigs.map { hex(MessageDigest.getInstance("SHA-256").digest(it.toByteArray())) }.toSet()
    }

    private fun sha256(f: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        f.inputStream().use { input ->
            val buf = ByteArray(1 shl 16)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                md.update(buf, 0, n)
            }
        }
        return hex(md.digest())
    }

    private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
}
