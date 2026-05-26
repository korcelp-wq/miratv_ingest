package com.miratv.app.vod

import android.content.Context
import com.miratv.app.config.ProviderContextBuilder

/**
 * VodResolver
 *
 * Responsible ONLY for constructing VOD playback URLs.
 * No network calls.
 * No activation logic.
 * No discovery.
 */
object VodResolver {

    /**
     * Build a VOD playback URL.
     *
     * @param context Android context
     * @param streamId Xtream VOD stream_id
     * @param extension File extension (mp4, mkv, etc.)
     */
    fun buildVodUrl(
        context: Context,
        streamId: Int,
        extension: String
    ): String? {

        val ctx = ProviderContextBuilder.build(context) ?: return null

        return buildString {
            append(ctx.baseUrl)
            append("/movie/")
            append(ctx.username)
            append("/")
            append(ctx.password)
            append("/")
            append(streamId)
            append(".")
            append(extension)
        }
    }
}
