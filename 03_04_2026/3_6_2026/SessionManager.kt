package com.miratv.app.util

import android.content.Context
import android.content.SharedPreferences
import android.provider.Settings
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone

class SessionManager(context: Context) {

    private val appContext = context.applicationContext
    private val prefs: SharedPreferences =
        appContext.getSharedPreferences("mira_session", Context.MODE_PRIVATE)

    companion object {
        // Activation Inputs
        private const val KEY_MAC = "mac"
        private const val KEY_CODE = "code"
        private const val KEY_DEVICE_FP = "device_fingerprint"

        // Credentials
        private const val KEY_USERNAME = "username"
        private const val KEY_PASSWORD = "password"
        private const val KEY_EXPIRES_DATE = "expires"
        private const val KEY_EXPIRES_EPOCH_SEC = "expires_epoch_sec"

        // Service metadata
        private const val KEY_DNS = "dns"
        private const val KEY_BOUND_TO = "bound_to"
        private const val KEY_M3U_LINK = "m3u_link"

        // Metadata
        private const val KEY_ACTIVATED_AT = "activated_at"
        private const val KEY_LAST_VERIFIED_AT = "last_verified_at"

        // Derived
        private const val KEY_ACTIVATED = "activated"
    }

    /* -----------------------
     * MAC (LAZY, SAFE)
     * ----------------------- */

    fun getMac(): String {
        val existing = prefs.getString(KEY_MAC, null)
        if (!existing.isNullOrBlank()) return existing

        return try {
            val androidId = Settings.Secure.getString(
                appContext.contentResolver,
                Settings.Secure.ANDROID_ID
            ).orEmpty()

            val opaque = sha256Hex(androidId.ifEmpty { "unknown_android_id" })
            prefs.edit().putString(KEY_MAC, opaque).apply()
            opaque
        } catch (_: Exception) {
            "unknown_device"
        }
    }

    /* -----------------------
     * ACTIVATION (AUTHORITATIVE)
     * ----------------------- */

    fun saveActivationSuccess(
        mac: String,
        code: String,
        deviceFingerprint: String,
        dns: String,
        boundTo: String,
        username: String,
        password: String,
        expiresDate: String,
        m3uLink: String?
    ) {
        val expiryEpoch = parseDateToEpochSecondsUtc(expiresDate)
        val nowEpoch = System.currentTimeMillis() / 1000

        prefs.edit()
            .putString(KEY_MAC, mac)
            .putString(KEY_CODE, code)
            .putString(KEY_DEVICE_FP, deviceFingerprint)

            .putString(KEY_USERNAME, username)
            .putString(KEY_PASSWORD, password)
            .putString(KEY_EXPIRES_DATE, expiresDate)
            .putLong(KEY_EXPIRES_EPOCH_SEC, expiryEpoch)

            .putString(KEY_DNS, dns)
            .putString(KEY_BOUND_TO, boundTo)
            .putString(KEY_M3U_LINK, m3uLink)

            .putLong(KEY_ACTIVATED_AT, nowEpoch)
            .putLong(KEY_LAST_VERIFIED_AT, nowEpoch)

            .putBoolean(KEY_ACTIVATED, true)
            .apply()
    }

    fun saveFromActivationApi(
        code: String,
        dns: String,
        username: String,
        password: String,
        expiresDate: String,
        m3uLink: String?,
        boundTo: String = "provider",
        deviceFingerprint: String = ""
    ) {
        saveActivationSuccess(
            mac = getMac(),
            code = code,
            deviceFingerprint = deviceFingerprint,
            dns = dns,
            boundTo = boundTo,
            username = username,
            password = password,
            expiresDate = expiresDate,
            m3uLink = m3uLink
        )
    }

    /* -----------------------
     * Explicit activation control
     * ----------------------- */

    fun setActivated(activated: Boolean) {
        prefs.edit()
            .putBoolean(KEY_ACTIVATED, activated)
            .apply()
    }

    /* -----------------------
     * Read accessors
     * ----------------------- */

    fun isActivated(): Boolean =
        prefs.getBoolean(KEY_ACTIVATED, false)

    fun getUsername(): String? =
        prefs.getString(KEY_USERNAME, null)

    fun getPassword(): String? =
        prefs.getString(KEY_PASSWORD, null)

    // =====================================================
    // 🟢 BACKEND SERVER - For activation only
    // =====================================================
    /**
     * BACKEND URL - Your activation server
     * This handles: activation, code validation
     * From AppConfig.BACKEND_BASE_URL
     */
    fun getBackendUrl(): String {
        return AppConfig.BACKEND_BASE_URL
    }

    /**
     * Full activation URL with path
     */
    fun getActivationUrl(): String {
        return AppConfig.BACKEND_BASE_URL + AppConfig.ACTIVATE_PATH
    }

    // =====================================================
    // 🟢 GATEWAY SERVER - For ALL API/database calls
    // =====================================================
    /**
     * GATEWAY URL - Your server for all API/database operations
     * This handles: categories, series, VOD lists, EPG, search
     * From AppConfig.GATEWAY_BASE_URL
     *
     * THIS IS THE CORRECT URL FOR ALL NON-STREAMING REQUESTS
     */
    fun getGatewayUrl(): String {
        return AppConfig.GATEWAY_BASE_URL
    }

    // =====================================================
    // 🟢 PROVIDER SERVER - For video streaming ONLY
    // =====================================================
    /**
     * PROVIDER URL - For video streaming ONLY
     * This comes from activation DNS, with fallback to default
     *
     * ⚠️ WARNING: This should ONLY be used for:
     * - Video stream URLs (.m3u8, .ts, .mp4)
     * - Direct playback endpoints
     *
     * ❌ DO NOT use this for:
     * - Categories, series, VOD lists
     * - EPG data
     * - Search
     * - Any metadata API calls
     */
    fun getProviderUrl(): String {
        // Try activation DNS first (most dynamic)
        val dns = getDns()?.trim().orEmpty()
        if (dns.isNotBlank()) {
            var url = dns
            if (!url.startsWith("http://") && !url.startsWith("https://")) {
                url = "http://$url"
            }
            if (!url.endsWith("/")) url += "/"
            return url
        }

        // Fallback to default provider URL from AppConfig
        return AppConfig.DEFAULT_PROVIDER_URL
    }

    /**
     * Legacy method - Use getProviderUrl() instead
     * Kept for compatibility during migration
     */
    @Deprecated("Use getProviderUrl() for streaming or getGatewayUrl() for API calls")
    fun getXtreamBaseUrl(): String {
        return getProviderUrl()
    }

    /**
     * Get DNS value from activation (raw, without normalization)
     */
    fun getDns(): String? =
        prefs.getString(KEY_DNS, null)

    fun getM3uLink(): String? =
        prefs.getString(KEY_M3U_LINK, null)

    fun getExpiresDate(): String? =
        prefs.getString(KEY_EXPIRES_DATE, null)

    fun getExpiryEpochSeconds(): Long =
        prefs.getLong(KEY_EXPIRES_EPOCH_SEC, 0L)

    fun getBoundTo(): String? =
        prefs.getString(KEY_BOUND_TO, null)

    fun getLastCode(): String? =
        prefs.getString(KEY_CODE, null)

    fun isCredentialsValid(
        nowEpochSeconds: Long = System.currentTimeMillis() / 1000
    ): Boolean {
        val u = getUsername()
        val p = getPassword()
        if (u.isNullOrBlank() || p.isNullOrBlank()) return false

        val exp = getExpiryEpochSeconds()
        return exp > 0 && nowEpochSeconds < exp
    }

    /* -----------------------
     * Derived / compatibility
     * ----------------------- */

    fun clearCredentialsOnly() {
        prefs.edit()
            .remove(KEY_USERNAME)
            .remove(KEY_PASSWORD)
            .remove(KEY_EXPIRES_DATE)
            .remove(KEY_EXPIRES_EPOCH_SEC)
            .remove(KEY_DNS)
            .remove(KEY_M3U_LINK)
            .putBoolean(KEY_ACTIVATED, false)
            .apply()
    }

    fun clearActivation() {
        prefs.edit()
            .remove(KEY_ACTIVATED)
            .remove(KEY_USERNAME)
            .remove(KEY_PASSWORD)
            .remove(KEY_DNS)
            .remove(KEY_M3U_LINK)
            .apply()
    }

    fun getSubscriptionExpiry(): String? =
        getExpiresDate()

    /* -----------------------
     * Helpers
     * ----------------------- */

    private fun sha256Hex(input: String): String {
        val md = MessageDigest.getInstance("SHA-256")
        val bytes = md.digest(input.toByteArray(Charsets.UTF_8))
        return bytes.joinToString("") { "%02x".format(it) }
    }

    private fun parseDateToEpochSecondsUtc(date: String): Long {
        if (date.isBlank()) return 0L
        return try {
            val sdf = SimpleDateFormat("yyyy-MM-dd", Locale.US)
            sdf.timeZone = TimeZone.getTimeZone("UTC")
            val parsed = sdf.parse(date) ?: return 0L
            parsed.time / 1000
        } catch (_: Exception) {
            0L
        }
    }

    // =====================================================
    // 🟢 DEBUG: Log current URL configuration
    // =====================================================
    fun logUrls() {
        android.util.Log.d("URL_CONFIG", """
            ========== URL CONFIGURATION ==========
            BACKEND_URL: ${getBackendUrl()}
            ACTIVATION_URL: ${getActivationUrl()}
            GATEWAY_URL: ${getGatewayUrl()}
            PROVIDER_URL: ${getProviderUrl()}
            DNS (raw): ${getDns() ?: "none"}
            ========================================
        """.trimIndent())
    }
}