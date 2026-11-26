package com.pupdates.app

import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

/** The same checks as the desktop's test_presence (WebSocket codec + the gateway session). */
class GatewayTest {
    private val token = listOf("MTIzNDU2Nzg5MDEyMzQ1Njc4", "Ga" + "BcDe", "abcdefghijklmnop" + "qrstuvwxyz012345").joinToString(".")

    private fun serverFrame(op: Int, payload: ByteArray, fin: Boolean = true): ByteArray {
        val out = ByteArrayOutputStream()
        out.write((if (fin) 0x80 else 0) or op)
        when {
            payload.size < 126 -> out.write(payload.size)
            payload.size < 65536 -> { out.write(126); out.write(payload.size ushr 8); out.write(payload.size and 0xFF) }
            else -> { out.write(127); for (i in 7 downTo 0) out.write(((payload.size.toLong() ushr (8 * i)) and 0xFF).toInt()) }
        }
        out.write(payload)
        return out.toByteArray()
    }

    @Test fun acceptKeyMatchesTheRfcExample() {
        assertEquals("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", Gateway.acceptKey("dGhlIHNhbXBsZSBub25jZQ=="))
    }

    @Test fun framesAreMaskedWithTheRightLength() {
        val mask = byteArrayOf(1, 2, 3, 4)
        for (n in listOf(0, 5, 125, 126, 65535, 65536, 70000)) {
            val payload = ByteArray(n) { (it % 251).toByte() }
            val f = Gateway.frame(1, payload, mask)
            assertEquals(0x81, f[0].toInt() and 0xFF)
            assertTrue(f[1].toInt() and 0x80 != 0)
            val (len, at) = when (f[1].toInt() and 0x7F) {
                126 -> (((f[2].toInt() and 0xFF) shl 8) or (f[3].toInt() and 0xFF)) to 4
                127 -> (0 until 8).fold(0L) { a, i -> (a shl 8) or (f[2 + i].toLong() and 0xFF) }.toInt() to 10
                else -> (f[1].toInt() and 0x7F) to 2
            }
            assertEquals(n, len)
            val m = f.copyOfRange(at, at + 4)
            val body = f.copyOfRange(at + 4, f.size)
            assertArrayEquals(payload, ByteArray(n) { (body[it].toInt() xor m[it % 4].toInt()).toByte() })
        }
    }

    @Test fun readsTextsFragmentsPingsAndClose() {
        val inData = ByteArrayOutputStream().apply {
            write(serverFrame(1, "{\"op\":10}".toByteArray()))
            write(serverFrame(9, "hi".toByteArray()))
            write(serverFrame(1, "{\"a\":".toByteArray(), fin = false)); write(serverFrame(0, "1}".toByteArray()))
            write(serverFrame(8, byteArrayOf(0x0F, 0xA4.toByte()) + "Authentication failed.".toByteArray()))
        }.toByteArray()
        val out = ByteArrayOutputStream()
        val ws = Gateway.WebSocket(ByteArrayInputStream(inData), out, Closeable {})
        assertEquals("{\"op\":10}", ws.recvText())
        assertEquals("{\"a\":1}", ws.recvText())
        assertEquals(0x8A, out.toByteArray()[0].toInt() and 0xFF)           // the ping was answered with a pong
        try { ws.recvText(); throw AssertionError("expected a close") } catch (e: Gateway.Closed) {
            assertEquals(4004, e.code)
            assertTrue(e.reason.contains("Authentication"))
        }
    }

    private class FakeSocket : Gateway.Socket {
        val inbox = LinkedBlockingQueue<Any>()
        val sent = java.util.Collections.synchronizedList(mutableListOf<JSONObject>())
        override fun recvText(): String {
            val item = inbox.poll(5, TimeUnit.SECONDS) ?: throw Gateway.Closed(null, "test timeout")
            if (item is Gateway.Closed) throw item
            return item.toString()
        }
        override fun sendText(text: String) { sent.add(JSONObject(text)) }
        override fun close(code: Int) { inbox.put(Gateway.Closed(code, "closed by the client")) }
    }

    private fun waitFor(what: () -> Boolean) {
        val end = System.currentTimeMillis() + 5000
        while (!what() && System.currentTimeMillis() < end) Thread.sleep(10)
        assertTrue(what())
    }

    @Test fun identifyCarriesListeningToJaeAndUpdatesChangeIt() {
        val pres = Gateway.presence("Listening", "Jae but mainly Claude")
        assertTrue(pres.isNull("since"))
        assertEquals("online", pres.getString("status"))
        assertFalse(pres.getBoolean("afk"))
        assertEquals("""{"name":"Jae but mainly Claude","type":2}""", pres.getJSONArray("activities").getJSONObject(0).toString())
        val sockets = mutableListOf<FakeSocket>()
        val states = LinkedBlockingQueue<Pair<String, Boolean>>()
        val p = Gateway.BotPresence(token, "Listening", "Jae but mainly Claude", onState = { t, ok -> states.put(t to ok) },
            connect = { url ->
                assertEquals(Gateway.URL, url)
                FakeSocket().also { it.inbox.put(JSONObject("""{"op":10,"d":{"heartbeat_interval":60000}}""")); sockets.add(it) }
            }, sleep = {})
        p.start()
        waitFor { sockets.isNotEmpty() && sockets[0].sent.isNotEmpty() }
        val s = sockets[0]
        val ident = s.sent[0]
        assertEquals(2, ident.getInt("op"))
        assertEquals(token, ident.getJSONObject("d").getString("token"))
        assertEquals(0, ident.getJSONObject("d").getInt("intents"))
        assertEquals("Jae but mainly Claude", ident.getJSONObject("d").getJSONObject("presence").getJSONArray("activities").getJSONObject(0).getString("name"))
        s.inbox.put(JSONObject("""{"op":0,"t":"READY","s":1,"d":{"user":{"username":"Pupdates"}}}"""))
        assertEquals("Online as Pupdates - Listening Jae but mainly Claude" to true, states.poll(5, TimeUnit.SECONDS))
        s.inbox.put(JSONObject("""{"op":1}"""))
        waitFor { s.sent.any { it.getInt("op") == 1 && it.optInt("d") == 1 } }
        p.setPresence("Watching", "the servers", "idle")
        val upd = s.sent.last()
        assertEquals(3, upd.getInt("op"))
        assertEquals("idle", upd.getJSONObject("d").getString("status"))
        assertEquals(3, upd.getJSONObject("d").getJSONArray("activities").getJSONObject(0).getInt("type"))
        p.stop()
        assertEquals("Offline (stopped)." to false, states.poll(5, TimeUnit.SECONDS))
    }

    @Test fun aWrongTokenStopsForGood() {
        var tries = 0
        val states = mutableListOf<Pair<String, Boolean>>()
        val p = Gateway.BotPresence(token, "Listening", "x", onState = { t, ok -> states.add(t to ok) }, connect = {
            tries++
            FakeSocket().apply {
                inbox.put(JSONObject("""{"op":10,"d":{"heartbeat_interval":60000}}"""))
                inbox.put(Gateway.Closed(4004, "Authentication failed."))
            }
        })
        p.run()
        assertEquals(1, tries)
        assertFalse(states.last().second)
        assertTrue(states.last().first.contains("refused the bot's token"))
    }

    @Test fun aDroppedLinkReconnects() {
        val sockets = java.util.Collections.synchronizedList(mutableListOf<FakeSocket>())
        val states = LinkedBlockingQueue<Pair<String, Boolean>>()
        val p = Gateway.BotPresence(token, "Listening", "x", onState = { t, ok -> states.put(t to ok) }, connect = {
            FakeSocket().apply {
                inbox.put(JSONObject("""{"op":10,"d":{"heartbeat_interval":60000}}"""))
                if (sockets.isEmpty()) inbox.put(JSONObject("""{"op":7}"""))
                sockets.add(this)
            }
        }, wait = {})
        val t = Thread { p.run() }.apply { isDaemon = true; start() }
        waitFor { sockets.size >= 2 }
        assertTrue(states.poll(5, TimeUnit.SECONDS)!!.first.startsWith("Reconnecting"))
        p.stop()
        t.join(5000)
        assertEquals(2, sockets.size)
    }
}
