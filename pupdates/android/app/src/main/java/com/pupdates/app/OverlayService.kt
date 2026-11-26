package com.pupdates.app

import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.PixelFormat
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.WindowManager
import android.widget.ImageView
import kotlin.math.abs

/**
 * The optional overlay: a round Pupdates bubble drawn over every other app (needs "Display over
 * other apps"). Tap it to open Pupdates on top of whatever is on screen (its window has no
 * backdrop, so the app underneath stays visible); drag it anywhere; long-press to remove it.
 * A foreground service with a small notification, so Android does not stop it.
 */
class OverlayService : Service() {
    private var bubble: ImageView? = null
    private lateinit var wm: WindowManager

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        startForegroundNotice()
        if (!Settings.canDrawOverlays(this)) { stopSelf(); return }
        showBubble()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) { stopSelf(); return START_NOT_STICKY }
        return START_STICKY
    }

    override fun onDestroy() {
        bubble?.let { try { wm.removeView(it) } catch (e: Exception) {} }
        bubble = null
        super.onDestroy()
    }

    private fun startForegroundNotice() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Pupdates bubble", NotificationManager.IMPORTANCE_MIN))
        val stop = PendingIntent.getService(this, 2, Intent(this, OverlayService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        val open = PendingIntent.getActivity(this, 3, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), PendingIntent.FLAG_IMMUTABLE)
        val n = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setContentTitle("Pupdates bubble is on")
            .setContentText("Tap the bubble to open Pupdates over any app.")
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "Remove bubble", stop).build())
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) startForeground(NOTE_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        else startForeground(NOTE_ID, n)
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun showBubble() {
        val prefs = getSharedPreferences("pupdates", MODE_PRIVATE)
        val size = (56 * resources.displayMetrics.density).toInt()
        val lp = WindowManager.LayoutParams(size, size, WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS, PixelFormat.TRANSLUCENT).apply {
            gravity = Gravity.TOP or Gravity.START
            x = prefs.getInt("bubble_x", 0)
            y = prefs.getInt("bubble_y", (200 * resources.displayMetrics.density).toInt())
        }
        val view = ImageView(this).apply {
            setImageResource(R.mipmap.ic_launcher)
            contentDescription = "Pupdates"
        }
        var downX = 0f
        var downY = 0f
        var startX = 0
        var startY = 0
        var moved = false
        var downAt = 0L
        view.setOnTouchListener { _, e ->
            when (e.actionMasked) {
                MotionEvent.ACTION_DOWN -> { downX = e.rawX; downY = e.rawY; startX = lp.x; startY = lp.y; moved = false; downAt = e.eventTime }
                MotionEvent.ACTION_MOVE -> {
                    val dx = e.rawX - downX
                    val dy = e.rawY - downY
                    if (abs(dx) > 12 || abs(dy) > 12) moved = true
                    if (moved) { lp.x = startX + dx.toInt(); lp.y = startY + dy.toInt(); wm.updateViewLayout(view, lp) }
                }
                MotionEvent.ACTION_UP -> {
                    if (moved) prefs.edit().putInt("bubble_x", lp.x).putInt("bubble_y", lp.y).apply()
                    else if (e.eventTime - downAt > 700) {
                        prefs.edit().putBoolean("overlay", false).apply()
                        stopSelf()
                    } else startActivity(Intent(this, MainActivity::class.java)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT))
                }
            }
            true
        }
        wm.addView(view, lp)
        bubble = view
    }

    companion object {
        const val ACTION_STOP = "com.pupdates.app.STOP_BUBBLE"
        private const val CHANNEL = "bubble"
        private const val NOTE_ID = 7
    }
}
