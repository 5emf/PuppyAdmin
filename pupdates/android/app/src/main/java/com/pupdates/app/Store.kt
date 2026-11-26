package com.pupdates.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Pupdates' settings. The webhook, the access key and the admin key are encrypted with an AES key
 * that lives in the Android Keystore (it never leaves the phone's key store and is lost with the app).
 */
class Store(context: Context) {
    private val prefs = context.getSharedPreferences("pupdates", Context.MODE_PRIVATE)

    fun get(key: String, def: String = ""): String = prefs.getString(key, def) ?: def
    fun getBool(key: String, def: Boolean): Boolean = prefs.getBoolean(key, def)
    fun set(key: String, value: String) = prefs.edit().putString(key, value).apply()
    fun setBool(key: String, value: Boolean) = prefs.edit().putBoolean(key, value).apply()

    fun secret(key: String): String {
        val blob = prefs.getString("secret_$key", null) ?: return ""
        return try {
            val raw = Base64.decode(blob, Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORM)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, raw, 0, IV))
            String(cipher.doFinal(raw, IV, raw.size - IV), Charsets.UTF_8)
        } catch (e: Exception) {
            ""
        }
    }

    fun setSecret(key: String, value: String) {
        val v = value.trim()
        if (v.isEmpty()) {
            prefs.edit().remove("secret_$key").apply()
            return
        }
        val cipher = Cipher.getInstance(TRANSFORM)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val iv = cipher.iv
        val out = iv + cipher.doFinal(v.toByteArray(Charsets.UTF_8))
        prefs.edit().putString("secret_$key", Base64.encodeToString(out, Base64.NO_WRAP)).apply()
    }

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build())
        return gen.generateKey()
    }

    companion object {
        private const val ALIAS = "pupdates_secrets"
        private const val TRANSFORM = "AES/GCM/NoPadding"
        private const val IV = 12
    }
}
