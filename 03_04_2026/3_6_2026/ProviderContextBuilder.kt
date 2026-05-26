package com.miratv.app.config

import android.content.Context
import android.util.Log
import com.miratv.app.util.SessionManager

/**
 * ProviderContextBuilder
 *
 * Translation layer:
 * SessionManager (activation state) -> playback inputs
 *
 * NO discovery
 * NO parameter merging
 * NO environment logic
 */
object ProviderContextBuilder {

    data class ProviderContext(
        val baseUrl: String,
        val username: String,
        val password: String
    )

    fun build(context: Context): ProviderContext? {
        val session = SessionManager(context)

        val dns = session.getDns()
        val username = session.getUsername()
        val password = session.getPassword()

        // DEBUG: INPUT FROM SESSION
        Log.e(
            "PROVIDER_CONTEXT_IN",
            """
            dns=$dns
            username=$username
            password=${password?.let { "***" }}
            """.trimIndent()
        )

        if (dns.isNullOrBlank() || username.isNullOrBlank() || password.isNullOrBlank()) {
            Log.e("PROVIDER_CONTEXT", "Missing required provider fields — cannot build context")
            return null
        }

        //val baseUrl = normalizeBaseUrl(dns)
        val normalizedBaseUrl = session.getProviderUrl()
        
        // DEBUG: OUTPUT BASE URL
        Log.e(
            "PROVIDER_CONTEXT_OUT",
            """
            normalizedBaseUrl=$baseUrl
            """.trimIndent()
        )

        return ProviderContext(
            baseUrl = baseUrl,
            username = username,
            password = password
        )
    }

    /**
     * Normalize provider base URL.
     *
     * Rules:
     * - Default to HTTP for IPTV providers
     * - Accept HTTPS only if explicitly supplied
     * - Always enforce trailing slash
     */
    private fun normalizeBaseUrl(dnsOrUrl: String): String {
        var u = dnsOrUrl.trim()

        Log.e("PROVIDER_URL_NORMALIZE", "input=$u")

        // Default to HTTP (DO NOT force HTTPS)
        if (!u.startsWith("http://") && !u.startsWith("https://")) {
            u = "http://$u"
            Log.e("PROVIDER_URL_NORMALIZE", "added http scheme -> $u")
        }

        if (!u.endsWith("/")) {
            u += "/"
            Log.e("PROVIDER_URL_NORMALIZE", "added trailing slash -> $u")
        }

        return u
    }
}
