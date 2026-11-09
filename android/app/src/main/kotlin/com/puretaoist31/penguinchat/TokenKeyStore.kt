package com.puretaoist31.penguinchat

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * 用 Android Keystore 里一把不可导出的 AES 密钥，包裹一把随机数据密钥。
 *
 * 被包裹后的数据密钥只落在应用私有 SharedPreferences；明文数据密钥只在
 * 本进程内交给 Dart 做票据文件的 AES-GCM。这样即便应用数据目录被拷走，
 * 没有 Keystore 里的硬件/系统密钥也解不开票据。
 *
 * 关键约束：**已有密文时绝不重新生成密钥**。否则旧票据会永久解不开，
 * 而用户看到的只是"没有会话"，无从判断是密钥丢了。
 */
internal object TokenKeyStore {
    private const val PREFS = "qq8_token_key_wrap_v1"
    private const val WRAPPED_DATA_KEY = "wrapped_data_key"
    private const val KEY_ALIAS = "penguinchat.qq8.token.wrap.v1"
    private const val GCM_TAG_BITS = 128
    private const val IV_BYTES = 12
    private const val DATA_KEY_BYTES = 32

    @Synchronized
    fun getOrCreateDataKey(context: Context, hasEncryptedTokens: Boolean): ByteArray {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val wrapped = prefs.getString(WRAPPED_DATA_KEY, null)
        if (wrapped != null) {
            val bytes = android.util.Base64.decode(wrapped, android.util.Base64.NO_WRAP)
            if (bytes.size <= IV_BYTES) {
                throw IllegalStateException("Wrapped token key is malformed")
            }
            val iv = bytes.copyOfRange(0, IV_BYTES)
            val ciphertext = bytes.copyOfRange(IV_BYTES, bytes.size)
            val wrappingKey = loadWrappingKey(create = false)
                ?: throw IllegalStateException("Android Keystore wrapping key is missing")
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, wrappingKey, GCMParameterSpec(GCM_TAG_BITS, iv))
            return cipher.doFinal(ciphertext).also {
                if (it.size != DATA_KEY_BYTES) {
                    throw IllegalStateException("Unwrapped token key has invalid length")
                }
            }
        }

        if (hasEncryptedTokens) {
            throw IllegalStateException(
                "Token key metadata is missing while encrypted sessions exist",
            )
        }
        val wrappingKey = loadWrappingKey(create = true)
            ?: throw IllegalStateException("Unable to create Android Keystore wrapping key")
        val dataKey = ByteArray(DATA_KEY_BYTES).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, wrappingKey)
        val iv = cipher.iv
        val ciphertext = cipher.doFinal(dataKey)
        val packed = ByteArray(iv.size + ciphertext.size)
        System.arraycopy(iv, 0, packed, 0, iv.size)
        System.arraycopy(ciphertext, 0, packed, iv.size, ciphertext.size)
        val committed = prefs.edit()
            .putString(
                WRAPPED_DATA_KEY,
                android.util.Base64.encodeToString(packed, android.util.Base64.NO_WRAP),
            )
            .commit()
        if (!committed) {
            throw IllegalStateException("Unable to persist wrapped token key")
        }
        return dataKey
    }

    private fun loadWrappingKey(create: Boolean): SecretKey? {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = store.getKey(KEY_ALIAS, null) as? SecretKey
        if (existing != null || !create) return existing
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.M) {
            throw IllegalStateException("Android Keystore AES-GCM wrapping requires API 23+")
        }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setKeySize(256)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .setUserAuthenticationRequired(false)
                .build(),
        )
        return generator.generateKey()
    }
}
