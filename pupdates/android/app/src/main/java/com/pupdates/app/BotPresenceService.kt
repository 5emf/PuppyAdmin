package com.pupdates.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper

/**
 * Keeps the bot online with its status ("Listening to Jae but mainly Claude") while the switch in
 * Status is on, also when Pupdates' window is closed: a foreground service with a small notification
 * (Android stops background network work otherwise). Settings: bot_online, bot_activity_type,
 * bot_activity_text, bot_status; the token is the saved bot token.
 */
class BotPresenceService : Service() {
    private var presence: Gateway.BotPresence? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            Store(this).setBool("bot_online", false)
            stopSelf()
            return START_NOT_STICKY
        }
        val store = Store(this)
        val token = store.secret("bot_token")
        val kind = store.get("bot_activity_type", "Listening")
        val text = store.get("bot_activity_text", DEFAULT_TEXT)
        val status = store.get("bot_status", "online")
        notice(if (presence == null) "Connecting..." else state.first)
        if (token.isEmpty()) { report("Save your bot's token in Bot first.", false); stopSelf(); return START_NOT_STICKY }
        val running = presence
        if (running != null && !running.isStopped) {
            if (intent?.action == ACTION_UPDATE) {
                running.setPresence(kind, text, status)
                report(if (text.isBlank()) "Now online with no status line." else "Now $kind $text.", true)
            } else report(state.first, state.second)       // the window opened again: keep the connection
        } else {
            running?.stop()
            presence = Gateway.BotPresence(token, kind, text, status, onState = { t, ok -> main.post { report(t, ok) } }).start()
        }
        return START_STICKY
    }

    override fun onDestroy() {
        presence?.stop()
        presence = null
        main.removeCallbacksAndMessages(null)
        state = "Off: the bot shows as offline within a minute." to false
        listener?.invoke(state.first, state.second)
        super.onDestroy()
    }

    private fun report(text: String, ok: Boolean) {
        state = text to ok
        listener?.invoke(text, ok)
        if (presence != null) notice(text)
    }

    private fun notice(text: String) {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Bot status", NotificationManager.IMPORTANCE_MIN))
        val stop = PendingIntent.getService(this, 4, Intent(this, BotPresenceService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        val open = PendingIntent.getActivity(this, 5, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK), PendingIntent.FLAG_IMMUTABLE)
        val n = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.presence_audio_online)
            .setContentTitle("Pupdates keeps the bot online")
            .setContentText(text)
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "Go offline", stop).build())
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) startForeground(NOTE_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        else startForeground(NOTE_ID, n)
    }

    companion object {
        const val ACTION_UPDATE = "com.pupdates.app.BOT_STATUS_UPDATE"
        const val ACTION_STOP = "com.pupdates.app.BOT_STATUS_STOP"
        const val DEFAULT_TEXT = "Jae but mainly Claude"
        private const val CHANNEL = "bot_status"
        private const val NOTE_ID = 8

        /** the last state (shown in Status), and the open window's listener (main thread) */
        @Volatile var state: Pair<String, Boolean> = "Off." to false
        var listener: ((String, Boolean) -> Unit)? = null

        fun start(context: Context, update: Boolean = false) {
            context.startForegroundService(Intent(context, BotPresenceService::class.java).apply { if (update) action = ACTION_UPDATE })
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, BotPresenceService::class.java))
        }
    }
}
