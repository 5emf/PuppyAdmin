package com.pupdates.app

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * Pupdates' own update (the Update button), like the companion's: the Android build publishes
 * Pupdates.apk and pupdates-android.json to the GitHub release "pupdates-android-latest"; this
 * compares versionCode, downloads the APK, checks its SHA-256 and hands it to Android's installer
 * (you confirm; Android only installs it over this app when it is signed with the same key).
 */
object Updater {
    const val BASE = "https://github.com/5emf/PuppyAdmin/releases/download/pupdates-android-latest/"
    const val ACTION_STATUS = "com.pupdates.app.INSTALL_STATUS"

    data class Info(val versionCode: Long, val versionName: String, val sha256: String, val size: Long)

    fun parse(json: String): Info {
        val o = JSONObject(json)
        return Info(o.optLong("versionCode"), o.optString("versionName"), o.optString("sha256").lowercase(), o.optLong("size"))
    }

    fun installed(ctx: Context): Long {
        val p = ctx.packageManager.getPackageInfo(ctx.packageName, 0)
        return if (Build.VERSION.SDK_INT >= 28) p.longVersionCode else @Suppress("DEPRECATION") p.versionCode.toLong()
    }

    fun check(http: Core.Http): Info {
        val r = http.request("GET", BASE + "pupdates-android.json", emptyMap(), null)
        if (r.code == 404) throw Core.PupError("No Pupdates update is published yet")
        if (r.code != 200) throw Core.PupError("GitHub answered HTTP ${r.code}")
        return parse(r.body)
    }

    fun sha256(f: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        f.inputStream().use { input ->
            val buf = ByteArray(64 * 1024)
            while (true) { val n = input.read(buf); if (n < 0) break; md.update(buf, 0, n) }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    /** downloads into the cache folder and checks it; progress(done, total) */
    fun download(ctx: Context, info: Info, progress: (Long, Long) -> Unit): File {
        val out = File(ctx.cacheDir, "update.apk")
        val c = URL(BASE + "Pupdates.apk").openConnection() as HttpURLConnection
        try {
            c.connectTimeout = 20000
            c.readTimeout = 60000
            c.setRequestProperty("User-Agent", "Pupdates-Android-Update")
            if (c.responseCode != 200) throw Core.PupError("GitHub answered HTTP ${c.responseCode}")
            var done = 0L
            c.inputStream.use { input ->
                out.outputStream().use { o ->
                    val buf = ByteArray(64 * 1024)
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        o.write(buf, 0, n)
                        done += n
                        if (done > 200L * 1024 * 1024) throw Core.PupError("The download is too large")
                        progress(done, info.size)
                    }
                }
            }
        } catch (e: java.io.IOException) {
            throw Core.PupError("Could not download the update: ${e.message}")
        } finally {
            c.disconnect()
        }
        if (info.size > 0 && out.length() != info.size) throw Core.PupError("The download is incomplete")
        if (sha256(out) != info.sha256) { out.delete(); throw Core.PupError("The download does not match its checksum: not installed") }
        return out
    }

    /** hands the APK to Android's installer; the result comes back to MainActivity as ACTION_STATUS */
    fun install(ctx: Context, apk: File) {
        val installer = ctx.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        params.setAppPackageName(ctx.packageName)
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            apk.inputStream().use { input ->
                session.openWrite("pupdates.apk", 0, apk.length()).use { out ->
                    input.copyTo(out)
                    session.fsync(out)
                }
            }
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
            val intent = Intent(ctx, MainActivity::class.java).setAction(ACTION_STATUS).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            session.commit(PendingIntent.getActivity(ctx, 1, intent, flags).intentSender)
        }
    }
}
