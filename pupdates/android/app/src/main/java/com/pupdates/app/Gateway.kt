package com.pupdates.app

import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.URI
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.Base64
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import kotlin.random.Random

/**
 * Keeps the bot online with a status ("Listening to ...") while the service runs: a small WebSocket
 * client and Discord's gateway v10 (Hello -> Identify with the presence -> heartbeats; op 3 changes
 * the status while connected). The same rules as the desktop app's gateway.py. Bots show one line only.
 */
object Gateway {
    const val URL = "wss://gateway.discord.gg/?v=10&encoding=json"
    val TYPES = linkedMapOf("Playing" to 0, "Listening" to 2, "Watching" to 3, "Competing" to 5)
    val STATUSES = listOf("online", "idle", "dnd")
    private const val GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    val FATAL = mapOf(
        4004 to "Discord refused the bot's token (it is wrong or was reset)",
        4010 to "Discord says the shard settings are invalid",
        4011 to "The bot is in too many servers to connect without sharding",
        4013 to "Discord says the intents are invalid",
        4014 to "Discord says the intents are not allowed")

    class Closed(val code: Int?, val reason: String) : IOException("closed $code $reason")

    // ------------------------------------------------------------------ WebSocket (RFC 6455, client side)
    /** one masked, final frame (clients must mask) */
    fun frame(opcode: Int, payload: ByteArray, mask: ByteArray = ByteArray(4).also { SecureRandom().nextBytes(it) }): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(0x80 or opcode)
        val n = payload.size
        when {
            n < 126 -> out.write(0x80 or n)
            n < 65536 -> { out.write(0x80 or 126); out.write(n ushr 8); out.write(n and 0xFF) }
            else -> { out.write(0x80 or 127); for (i in 7 downTo 0) out.write(((n.toLong() ushr (8 * i)) and 0xFF).toInt()) }
        }
        out.write(mask)
        for (i in payload.indices) out.write(payload[i].toInt() xor mask[i % 4].toInt())
        return out.toByteArray()
    }

    fun acceptKey(key: String): String =
        Base64.getEncoder().encodeToString(MessageDigest.getInstance("SHA-1").digest((key + GUID).toByteArray(Charsets.US_ASCII)))

    interface Socket {
        fun recvText(): String
        fun sendText(text: String)
        fun close(code: Int = 1000)
    }

    class WebSocket(private val input: InputStream, private val output: OutputStream, private val closer: Closeable) : Socket {
        private val lock = Any()

        private fun readFully(n: Int): ByteArray {
            val buf = ByteArray(n)
            var got = 0
            while (got < n) {
                val r = input.read(buf, got, n - got)
                if (r < 0) throw Closed(null, "connection lost")
                got += r
            }
            return buf
        }

        fun handshake(host: String, path: String) {
            val key = Base64.getEncoder().encodeToString(ByteArray(16).also { SecureRandom().nextBytes(it) })
            output.write(("GET $path HTTP/1.1\r\nHost: $host\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
                "Sec-WebSocket-Key: $key\r\nSec-WebSocket-Version: 13\r\nUser-Agent: Pupdates\r\n\r\n").toByteArray(Charsets.US_ASCII))
            output.flush()
            val head = ByteArrayOutputStream()
            var last4 = 0
            while (last4 != 0x0D0A0D0A) {
                val b = input.read()
                if (b < 0) throw Closed(null, "the server closed during the handshake")
                head.write(b)
                last4 = (last4 shl 8) or b
                if (head.size() > 16384) throw Closed(null, "bad WebSocket handshake")
            }
            val lines = head.toString("ISO-8859-1").split("\r\n")
            if (!(lines[0] + " ").contains(" 101 ")) throw Closed(null, "the server refused the WebSocket (${lines[0]})")
            val accept = lines.drop(1).firstOrNull { it.lowercase().startsWith("sec-websocket-accept:") }?.substringAfter(":")?.trim()
            if (accept != acceptKey(key)) throw Closed(null, "bad WebSocket handshake")
        }

        private fun send(opcode: Int, payload: ByteArray) = synchronized(lock) { output.write(frame(opcode, payload)); output.flush() }

        override fun sendText(text: String) = send(0x1, text.toByteArray(Charsets.UTF_8))

        override fun recvText(): String {
            val parts = ByteArrayOutputStream()
            while (true) {
                val h = readFully(2)
                val b1 = h[0].toInt() and 0xFF
                val b2 = h[1].toInt() and 0xFF
                val op = b1 and 0x0F
                var n = (b2 and 0x7F).toLong()
                if (n == 126L) n = readFully(2).fold(0L) { a, b -> (a shl 8) or (b.toLong() and 0xFF) }
                else if (n == 127L) n = readFully(8).fold(0L) { a, b -> (a shl 8) or (b.toLong() and 0xFF) }
                if (n > 16L * 1024 * 1024) throw Closed(null, "a message was too big")
                val mask = if (b2 and 0x80 != 0) readFully(4) else null
                val data = readFully(n.toInt())
                if (mask != null) for (i in data.indices) data[i] = (data[i].toInt() xor mask[i % 4].toInt()).toByte()
                when (op) {
                    0x9 -> { send(0xA, data); continue }
                    0xA -> continue
                    0x8 -> {
                        val code = if (data.size >= 2) ((data[0].toInt() and 0xFF) shl 8) or (data[1].toInt() and 0xFF) else null
                        throw Closed(code, if (data.size > 2) String(data, 2, data.size - 2, Charsets.UTF_8) else "")
                    }
                }
                parts.write(data)
                if (b1 and 0x80 != 0) return parts.toString("UTF-8")
            }
        }

        override fun close(code: Int) {
            try { send(0x8, byteArrayOf((code ushr 8).toByte(), (code and 0xFF).toByte())) } catch (e: IOException) {}
            try { closer.close() } catch (e: IOException) {}
        }

        companion object {
            fun connect(url: String): Socket {
                val u = URI(url)
                val host = u.host
                val sock = SSLSocketFactory.getDefault().createSocket(host, if (u.port > 0) u.port else 443) as SSLSocket
                sock.soTimeout = 30_000
                sock.startHandshake()
                val ws = WebSocket(sock.inputStream.buffered(), sock.outputStream, sock)
                ws.handshake(host, (u.rawPath.ifEmpty { "/" }) + (u.rawQuery?.let { "?$it" } ?: ""))
                sock.soTimeout = 0
                return ws
            }
        }
    }

    // ------------------------------------------------------------------ the gateway
    fun activity(kind: String, text: String): JSONObject? {
        val t = text.trim().take(128)
        return if (t.isEmpty()) null else JSONObject().put("name", t).put("type", TYPES[kind] ?: 2)
    }

    fun presence(kind: String, text: String, status: String = "online"): JSONObject = JSONObject()
        .put("since", JSONObject.NULL)
        .put("activities", JSONArray().apply { activity(kind, text)?.let { put(it) } })
        .put("status", if (status in STATUSES) status else "online")
        .put("afk", false)

    fun identify(token: String, pres: JSONObject): JSONObject = JSONObject().put("op", 2).put("d", JSONObject()
        .put("token", token).put("intents", 0).put("presence", pres)
        .put("properties", JSONObject().put("os", "android").put("browser", "Pupdates").put("device", "Pupdates")))

    /** "Online as NAME - Listening TEXT" */
    fun onlineText(user: String, pres: JSONObject): String {
        val acts = pres.optJSONArray("activities")
        val act = if (acts != null && acts.length() > 0) acts.getJSONObject(0) else null
        val what = act?.let { a -> " - " + (TYPES.entries.firstOrNull { it.value == a.optInt("type") }?.key ?: "Playing") + " " + a.optString("name") } ?: ""
        return "Online as $user$what"
    }

    /**
     * Runs in its own thread: connect, identify, heartbeat, reconnect with growing pauses (5 s .. 2 min);
     * a refused token stops it. onState(text, online) is called from that thread.
     */
    class BotPresence(
        private val token: String, kind: String, text: String, status: String = "online",
        private val onState: (String, Boolean) -> Unit = { _, _ -> },
        private val connect: (String) -> Socket = { WebSocket.connect(it) },
        private val sleep: (Long) -> Unit = { Thread.sleep(it) },
        wait: ((Long) -> Unit)? = null,
    ) {
        @Volatile var pres: JSONObject = presence(kind, text, status); private set
        @Volatile private var ws: Socket? = null
        @Volatile private var seq: Int? = null
        @Volatile private var acked = true
        private val stopped = CountDownLatch(1)
        private val pause: (Long) -> Unit = wait ?: { ms -> stopped.await(ms, TimeUnit.MILLISECONDS) }
        val isStopped get() = stopped.count == 0L

        fun start(): BotPresence { Thread({ run() }, "pupdates-gateway").apply { isDaemon = true }.start(); return this }

        fun stop() {
            stopped.countDown()
            ws?.close()
        }

        fun setPresence(kind: String, text: String, status: String = "online") {
            pres = presence(kind, text, status)
            try { ws?.sendText(JSONObject().put("op", 3).put("d", pres).toString()) } catch (e: IOException) {}
        }

        fun run() {
            var wait = 5_000L
            while (!isStopped) {
                try {
                    session()
                    wait = 5_000L
                } catch (e: Closed) {
                    if (e.code != null && e.code in FATAL) { onState("Offline: " + FATAL[e.code], false); return }
                    if (!isStopped) onState("Reconnecting (${e.reason.ifEmpty { e.code?.toString() ?: "connection lost" }})...", false)
                } catch (e: Exception) {
                    if (!isStopped) onState("Offline: could not reach Discord (${e.message ?: e.javaClass.simpleName}). Trying again...", false)
                } finally {
                    ws?.close()
                    ws = null
                }
                if (isStopped) break
                pause(wait)
                wait = minOf(wait * 2, 120_000L)
            }
            onState("Offline (stopped).", false)
        }

        private fun beat(socket: Socket, intervalMs: Long) {
            if (stopped.await((intervalMs * Random.nextDouble()).toLong(), TimeUnit.MILLISECONDS)) return
            while (!isStopped && ws === socket) {
                if (!acked) { socket.close(4000); return }      // no answer to the last heartbeat: the link is dead
                acked = false
                try { socket.sendText(JSONObject().put("op", 1).put("d", seq ?: JSONObject.NULL).toString()) } catch (e: IOException) { return }
                if (stopped.await(intervalMs, TimeUnit.MILLISECONDS)) return
            }
        }

        fun session() {
            val socket = connect(URL)
            ws = socket
            val hello = JSONObject(socket.recvText())
            if (hello.optInt("op", -1) != 10) throw Closed(null, "Discord did not say hello")
            val interval = hello.getJSONObject("d").optLong("heartbeat_interval", 41250)
            acked = true
            Thread({ beat(socket, interval) }, "pupdates-heartbeat").apply { isDaemon = true }.start()
            socket.sendText(identify(token, pres).toString())
            while (!isStopped) {
                val msg = JSONObject(socket.recvText())
                if (msg.has("s") && !msg.isNull("s")) seq = msg.optInt("s")
                when (msg.optInt("op", -1)) {
                    11 -> acked = true
                    1 -> socket.sendText(JSONObject().put("op", 1).put("d", seq ?: JSONObject.NULL).toString())
                    0 -> if (msg.optString("t") == "READY") {
                        val me = msg.optJSONObject("d")?.optJSONObject("user")
                        onState(onlineText(me?.optString("username") ?: "the bot", pres), true)
                    }
                    7 -> throw Closed(null, "Discord asked to reconnect")
                    9 -> { sleep(1000L + Random.nextLong(4000)); throw Closed(null, "the session was not accepted") }
                }
            }
        }
    }
}
