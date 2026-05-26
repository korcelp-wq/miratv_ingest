package com.miratv.app.xtream

import android.util.Log
import com.miratv.app.api.WorkersSeriesService
import com.miratv.app.mapping.ModelMapper
import com.miratv.app.models.AppModels
import com.miratv.app.util.SessionManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import retrofit2.Retrofit
import retrofit2.converter.gson.GsonConverterFactory
import retrofit2.http.GET
import retrofit2.http.Query
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

// =============================================
// PROVIDER-SPECIFIC MODELS
// =============================================

data class ProviderSeason(
    val air_date: String?,
    val episode_count: Int?,
    val id: Int?,
    val name: String?,
    val overview: String?,
    val season_number: Int?,
    val cover: String?,
    val cover_big: String?
)

data class ProviderInfo(
    val name: String?,
    val cover: String?,
    val plot: String?,
    val cast: String?,
    val director: String?,
    val genre: String?,
    val releaseDate: String?,
    val last_modified: String?,
    val rating: String?,
    val rating_5based: Int?,
    val backdrop_path: List<String>?,
    val youtube_trailer: String?,
    val episode_run_time: String?,
    val category_id: String?
)

/**
 * IMPORTANT:
 * Some providers return episode.info as:
 * - object
 * - array
 * - null
 *
 * We use Any? here so Gson does not crash on BEGIN_ARRAY.
 */
data class ProviderEpisode(
    val id: String,
    val episode_num: Int,
    val title: String?,
    val container_extension: String?,
    val info: Any?,
    val custom_sid: String?,
    val added: String?,
    val season: Int?,
    val direct_source: String?
)

data class ProviderSeriesInfoResponse(
    val seasons: List<ProviderSeason>?,
    val info: ProviderInfo?,
    val episodes: Map<String, List<ProviderEpisode>>?
)

interface ProviderXtreamService {
    @GET("player_api.php")
    suspend fun getSeriesInfo(
        @Query("username") username: String,
        @Query("password") password: String,
        @Query("action") action: String = "get_series_info",
        @Query("series_id") seriesId: Int
    ): ProviderSeriesInfoResponse
}

// =============================================
// MAIN REPOSITORY
// =============================================

class XtreamRepository(
    private val api: XtreamService,
    private val workersApi: WorkersSeriesService,
    private val session: SessionManager
) {

    private val TAG = "XtreamRepository"
    private val episodeCache = ConcurrentHashMap<Int, List<AppModels.EpisodeItem>>()

    companion object {
        private const val WORKERS_API_TOKEN = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"

        fun create(session: SessionManager): XtreamRepository {
            val gatewayUrl = session.getGatewayUrl()

            Log.d("XtreamRepository", "🔧 CREATING REPOSITORY")
            Log.d("XtreamRepository", "🔧 Gateway URL from session: $gatewayUrl")
            Log.d("XtreamRepository", "🔧 Provider URL from session: ${session.getProviderUrl()}")
            Log.d("XtreamRepository", "🔧 Username from session: ${session.getUsername()}")
            Log.d("XtreamRepository", "🔧 Password set: ${session.getPassword() != null}")

            val retrofit = Retrofit.Builder()
                .baseUrl(gatewayUrl)
                .addConverterFactory(GsonConverterFactory.create())
                .client(OkHttpClient.Builder().build())
                .build()

            val api = retrofit.create(XtreamService::class.java)
            val workersApi = retrofit.create(WorkersSeriesService::class.java)

            return XtreamRepository(api, workersApi, session)
        }
    }

    private fun logSessionInfo(context: String) {
        Log.d(TAG, "========== SESSION INFO [$context] ==========")
        Log.d(TAG, "Provider URL: ${session.getProviderUrl()?.removeSuffix("/") ?: "NULL"}")
        Log.d(TAG, "Gateway URL: ${session.getGatewayUrl() ?: "NULL"}")
        Log.d(TAG, "Username: ${session.getUsername() ?: "NULL"}")
        Log.d(TAG, "Password present: ${session.getPassword() != null}")
        Log.d(TAG, "==========================================")
    }

    // =============================================
    // LIVE STREAMS
    // =============================================

    suspend fun getLiveStreams(): List<AppModels.LiveChannel> {
        logSessionInfo("getLiveStreams")

        val u = session.getUsername()
        if (u == null) {
            Log.e(TAG, "❌ getLiveStreams: Username is null")
            return emptyList()
        }

        val p = session.getPassword()
        if (p == null) {
            Log.e(TAG, "❌ getLiveStreams: Password is null")
            return emptyList()
        }

        val providerUrl = session.getProviderUrl()?.removeSuffix("/") ?: ""
        val providerRetrofit = Retrofit.Builder()
            .baseUrl(providerUrl)
            .addConverterFactory(GsonConverterFactory.create())
            .client(OkHttpClient.Builder().build())
            .build()

        val providerApi = providerRetrofit.create(XtreamService::class.java)
        val raw = providerApi.getLiveStreams(u, p)

        Log.d(TAG, "[getLiveStreams] Returned ${raw.size} streams")
        return raw.mapNotNull { ModelMapper.toLiveChannel(it) }
    }

    // =============================================
    // SERIES CATEGORIES (leave as-is for now)
    // =============================================

    suspend fun getCategories(): List<AppModels.SeriesCategory> {
        logSessionInfo("getCategories")

        Log.d(TAG, "[getCategories] Calling workers API with token=$WORKERS_API_TOKEN")
        Log.d(TAG, "[getCategories] Base URL: ${session.getGatewayUrl()}")
        Log.d(TAG, "[getCategories] Full endpoint: ${session.getGatewayUrl()}series/concepts?token=$WORKERS_API_TOKEN")

        val result = workersApi.getSeriesConcepts(token = WORKERS_API_TOKEN)
        Log.d(
            TAG,
            "[getCategories] Returned ${result.size}. Sample: ${
                if (result.isNotEmpty()) result[0].toString() else "<empty>"
            }"
        )
        return result
    }

    suspend fun getSeriesByCategory(
        categoryId: Int,
        limit: Int = 20,
        offset: Int = 0
    ): List<AppModels.SeriesItem> {
        logSessionInfo("getSeriesByCategory")

        Log.d(
            TAG,
            "[getSeriesByCategory] categoryId=$categoryId, limit=$limit, offset=$offset, token=$WORKERS_API_TOKEN"
        )

        val result = workersApi.getSeriesByCategory(
            token = WORKERS_API_TOKEN,
            categoryId = categoryId,
            limit = limit,
            offset = offset
        )

        Log.d(
            TAG,
            "[getSeriesByCategory] Returned ${result.size}. Sample: ${
                if (result.isNotEmpty()) result[0].toString() else "<empty>"
            }"
        )
        return result
    }

    suspend fun getLiveCategories(): List<AppModels.LiveCategory> {
        logSessionInfo("getLiveCategories")

        val u = session.getUsername()
        if (u == null) {
            Log.e(TAG, "❌ getLiveCategories: Username is null")
            return emptyList()
        }

        val p = session.getPassword()
        if (p == null) {
            Log.e(TAG, "❌ getLiveCategories: Password is null")
            return emptyList()
        }

        val providerUrl = session.getProviderUrl()?.removeSuffix("/") ?: ""
        val providerRetrofit = Retrofit.Builder()
            .baseUrl(providerUrl)
            .addConverterFactory(GsonConverterFactory.create())
            .client(OkHttpClient.Builder().build())
            .build()

        val providerApi = providerRetrofit.create(XtreamService::class.java)
        val raw = providerApi.getLiveCategories(u, p)

        Log.d(TAG, "[getLiveCategories] Returned ${raw.size} categories")
        return raw.map { ModelMapper.toLiveCategory(it) }
    }

    // =============================================
    // EPISODES - PROVIDER ONLY FOR PLAYBACK
    // =============================================

    suspend fun getEpisodes(seriesId: Int): List<AppModels.EpisodeItem> = withContext(Dispatchers.IO) {
        val tag = "$TAG.getEpisodes($seriesId)"
        Log.d(tag, "🚀 [getEpisodes] Start for seriesId=$seriesId")
        logSessionInfo("getEpisodes-$seriesId")

        episodeCache[seriesId]?.let { cached ->
            Log.d(tag, "✅ Using cached episodes: ${cached.size}")
            return@withContext cached
        }

        val u = session.getUsername()
        if (u.isNullOrBlank()) {
            Log.e(tag, "❌ Username is null/blank")
            return@withContext emptyList()
        }

        val p = session.getPassword()
        if (p.isNullOrBlank()) {
            Log.e(tag, "❌ Password is null/blank")
            return@withContext emptyList()
        }

        val providerUrl = session.getProviderUrl()?.removeSuffix("/") ?: ""
        if (providerUrl.isBlank()) {
            Log.e(tag, "❌ Provider URL is blank")
            return@withContext emptyList()
        }

        try {
            Log.d(tag, "🌐 Provider-only episodes fetch")
            Log.d(
                tag,
                "🔍 FETCHING FROM: $providerUrl/player_api.php?username=$u&password=***&action=get_series_info&series_id=$seriesId"
            )

            val providerRetrofit = Retrofit.Builder()
                .baseUrl(providerUrl)
                .addConverterFactory(GsonConverterFactory.create())
                .client(
                    OkHttpClient.Builder()
                        .callTimeout(30, TimeUnit.SECONDS)
                        .connectTimeout(30, TimeUnit.SECONDS)
                        .readTimeout(30, TimeUnit.SECONDS)
                        .build()
                )
                .build()

            val providerApi = providerRetrofit.create(ProviderXtreamService::class.java)
            val providerResponse = providerApi.getSeriesInfo(u, p, "get_series_info", seriesId)

            val providerEpisodes = mutableListOf<AppModels.EpisodeItem>()

            providerResponse.episodes?.forEach { (seasonNum, episodeList) ->
                val seasonInt = seasonNum.toIntOrNull() ?: 1

                episodeList.forEach { ep ->
                    val title = ep.title?.trim().orEmpty().ifBlank {
                        "S${seasonInt.toString().padStart(2, '0')}E${ep.episode_num.toString().padStart(2, '0')}"
                    }

                    val direct = ep.direct_source?.trim().orEmpty()

                    val streamUrl = if (direct.isNotBlank()) {
                        direct
                    } else {
                        val ext = ep.container_extension?.trim().orEmpty().ifBlank { "mp4" }
                        "$providerUrl/series/$u/$p/${ep.id}.$ext"
                    }

                    providerEpisodes.add(
                        AppModels.EpisodeItem(
                            id = ep.id,
                            title = title,
                            season = ep.season ?: seasonInt,
                            episodeNum = ep.episode_num,
                            streamUrl = streamUrl,
                            cover = null
                        )
                    )
                }
            }

            Log.d(tag, "✅ Provider returned ${providerEpisodes.size} episodes")

            if (providerEpisodes.isEmpty()) {
                Log.w(tag, "⚠️ No provider episodes found")
                return@withContext emptyList()
            }

            episodeCache[seriesId] = providerEpisodes

            Log.d(tag, "🔄 Triggering background ingestion for series $seriesId")
            triggerOneOffIngestion(seriesId)

            Log.d(tag, "✅ Returning ${providerEpisodes.size} provider episodes")
            return@withContext providerEpisodes

        } catch (e: Exception) {
            Log.e(tag, "❌ Provider episodes fetch failed", e)
            Log.e(tag, "❌ Provider URL attempted: $providerUrl")
            return@withContext emptyList()
        }
    }

    // =============================================
    // BACKGROUND INGESTION TRIGGER
    // =============================================

    private fun triggerOneOffIngestion(seriesId: Int) {
        val tag = "$TAG.triggerOneOffIngestion"

        try {
            val batchFilePath = "C:\\miratv_ingest\\one_off_runner.bat"
            val batchFile = java.io.File(batchFilePath)
            if (!batchFile.exists()) {
                Log.e(tag, "❌ Batch file not found: $batchFilePath")
                return
            }

            val command = arrayOf("cmd", "/c", batchFilePath, seriesId.toString())

            Log.d(tag, "🔄 Triggering background ingestion for series $seriesId")
            Log.d(tag, "📋 Command: ${command.joinToString(" ")}")

            val processBuilder = ProcessBuilder(*command)
            processBuilder.directory(batchFile.parentFile)
            processBuilder.redirectErrorStream(true)

            val process = processBuilder.start()

            Thread {
                try {
                    process.inputStream.bufferedReader().useLines { lines ->
                        lines.forEach { line ->
                            Log.d(tag, "📤 [ingestion] $line")
                        }
                    }

                    val exitCode = process.waitFor()
                    if (exitCode == 0) {
                        Log.d(tag, "✅ Background ingestion completed successfully for series $seriesId")
                    } else {
                        Log.e(tag, "❌ Background ingestion failed with exit code: $exitCode")
                    }
                } catch (e: Exception) {
                    Log.e(tag, "❌ Error reading ingestion output", e)
                }
            }.start()

            Log.d(tag, "✅ Background ingestion process started for series $seriesId")

        } catch (e: Exception) {
            Log.e(tag, "❌ Error triggering background ingestion", e)
        }
    }

    // =============================================
    // STREAM URL BUILDERS
    // =============================================

    fun buildLiveUrl(streamId: String): String {
        val providerUrl = session.getProviderUrl()?.removeSuffix("/") ?: ""
        val username = session.getUsername() ?: ""
        val password = session.getPassword() ?: ""
        return "$providerUrl/live/$username/$password/$streamId.ts"
    }

    fun buildVodUrl(streamId: String, extension: String = "mp4"): String {
        val providerUrl = session.getProviderUrl()?.removeSuffix("/") ?: ""
        val username = session.getUsername() ?: ""
        val password = session.getPassword() ?: ""
        val ext = extension.trim().ifBlank { "mp4" }
        return "$providerUrl/movie/$username/$password/$streamId.$ext"
    }
}