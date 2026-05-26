package com.miratv.app.xtream

import android.content.Context
import android.util.Log
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import com.miratv.app.api.WorkersSeriesService
import com.miratv.app.mapping.ModelMapper
import com.miratv.app.models.AppModels
import com.miratv.app.util.SessionManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import retrofit2.Retrofit
import retrofit2.converter.gson.GsonConverterFactory
import retrofit2.http.GET
import retrofit2.http.Query
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

// =============================================
// PROVIDER-SPECIFIC MODELS THAT MATCH THE ACTUAL API RESPONSE
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

data class ProviderEpisode(
    val id: String,
    val episode_num: Int,
    val title: String,
    val container_extension: String,
    val info: ProviderEpisodeInfo?,
    val custom_sid: String?,
    val added: String?,
    val season: Int?,
    val direct_source: String?
)

data class ProviderEpisodeInfo(
    val movie_image: String?,
    val plot: String?,
    val releasedate: String?,
    val rating: Double?,
    val duration_secs: Int?,
    val duration: String?
)

data class ProviderSeriesInfoResponse(
    val seasons: List<ProviderSeason>?,
    val info: ProviderInfo?,
    val episodes: Map<String, List<ProviderEpisode>>? // Map of season number to episodes
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
// MAIN REPOSITORY CLASS
// =============================================

class XtreamRepository(
    private val api: XtreamService,
    private val workersApi: WorkersSeriesService,
    private val session: SessionManager
) {

    private val TAG = "XtreamRepository"

    // Simple in-memory cache for episodes by seriesId
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

    // =============================================
    // HELPER METHOD TO LOG SESSION INFO
    // =============================================

    private fun logSessionInfo(context: String) {
        Log.d(TAG, "========== SESSION INFO [$context] ==========")
        Log.d(TAG, "Provider URL: ${session.getProviderUrl()?.removeSuffix("/") ?: "NULL"}")
        Log.d(TAG, "Gateway URL: ${session.getGatewayUrl() ?: "NULL"}")
        Log.d(TAG, "Username: ${session.getUsername() ?: "NULL"}")
        Log.d(TAG, "Password present: ${session.getPassword() != null}")
        Log.d(TAG, "==========================================")
    }

    // =============================================
    // LIVE STREAMS (username/password API)
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

        Log.d(TAG, "[getLiveStreams] Fetching for user: $u")
        Log.d(TAG, "[getLiveStreams] API base URL: ${session.getProviderUrl()}")

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
    // SERIES CATEGORIES (workers token API)
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

    // =============================================
    // SERIES LIST BY CATEGORY (workers token API)
    // =============================================

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
        Log.d(TAG, "[getSeriesByCategory] Base URL: ${session.getGatewayUrl()}")
        Log.d(
            TAG,
            "[getSeriesByCategory] Full endpoint: ${session.getGatewayUrl()}series/concepts/by-category?token=$WORKERS_API_TOKEN&categoryId=$categoryId&limit=$limit&offset=$offset"
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

    // =============================================
    // LIVE TV CATEGORIES (username/password API)
    // =============================================

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

        Log.d(TAG, "[getLiveCategories] Fetching for user: $u")
        Log.d(TAG, "[getLiveCategories] API base URL: ${session.getProviderUrl()}")

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

    /**
     * DB Episodes fetch (Workers gateway)
     * IMPORTANT: This is a PHP file endpoint and MUST include ".php".
     *
     * We intentionally use raw OkHttp here so we are not dependent on Retrofit @GET pathing.
     */
    private suspend fun fetchEpisodesFromDatabase(seriesId: Int): List<AppModels.EpisodeItem> =
        withContext(Dispatchers.IO) {
            val base = (session.getGatewayUrl() ?: "").trim()
            if (base.isBlank()) {
                Log.e(TAG, "❌ fetchEpisodesFromDatabase: gatewayUrl is blank")
                return@withContext emptyList()
            }

            val gateway = if (base.endsWith("/")) base else "$base/"
            val url = "${gateway}series/concepts/episodes.php?token=$WORKERS_API_TOKEN&seriesId=$seriesId"

            return@withContext try {
                val client = OkHttpClient.Builder()
                    .callTimeout(15, TimeUnit.SECONDS)
                    .connectTimeout(10, TimeUnit.SECONDS)
                    .readTimeout(15, TimeUnit.SECONDS)
                    .build()

                val request = Request.Builder()
                    .url(url)
                    .get()
                    .header("Accept", "application/json")
                    .build()

                client.newCall(request).execute().use { resp ->
                    val body = resp.body?.string().orEmpty()

                    if (!resp.isSuccessful) {
                        Log.e(TAG, "❌ DB episodes HTTP ${resp.code} for seriesId=$seriesId")
                        Log.e(TAG, "❌ DB episodes URL: $url")
                        Log.e(TAG, "❌ DB episodes body(first300)=${body.take(300)}")
                        return@withContext emptyList()
                    }

                    if (body.isBlank() || body == "[]") {
                        return@withContext emptyList()
                    }

                    val listType = object : TypeToken<List<AppModels.EpisodeItem>>() {}.type
                    val parsed: List<AppModels.EpisodeItem> =
                        Gson().fromJson(body, listType) ?: emptyList()

                    parsed
                }
            } catch (e: Exception) {
                Log.e(TAG, "❌ DB episodes exception for seriesId=$seriesId : ${e.javaClass.name}: ${e.message}", e)
                Log.e(TAG, "❌ DB episodes URL: $url")
                emptyList()
            }
        }

    // =============================================
    // EPISODES - DB FIRST THEN PROVIDER-SPECIFIC PARSING
    // =============================================

    suspend fun getEpisodes(seriesId: Int): List<AppModels.EpisodeItem> = withContext(Dispatchers.IO) {
        val tag = "$TAG.getEpisodes($seriesId)"
        Log.d(tag, "🚀 [getEpisodes] Start for seriesId=$seriesId")

        // Log session info at the start
        logSessionInfo("getEpisodes-$seriesId")

        // STEP 0: Check memory cache first (fastest)
        episodeCache[seriesId]?.let { cached ->
            Log.d(tag, "✅ Using cached episodes: ${cached.size}")
            return@withContext cached
        }

        var dbWasEmpty = false

        // STEP 1: TRY DATABASE FIRST
        try {
            Log.d(tag, "📚 [getEpisodes] Checking database for episodes...")
            Log.d(tag, "📚 Database endpoint: ${session.getGatewayUrl()}series/concepts/episodes.php?token=$WORKERS_API_TOKEN&seriesId=$seriesId")

            val dbEpisodes = fetchEpisodesFromDatabase(seriesId)

            Log.d(
                tag,
                "📚 [getEpisodes] DB returned ${dbEpisodes.size}. Sample: ${
                    if (dbEpisodes.isNotEmpty()) dbEpisodes[0].toString() else "<empty>"
                }"
            )

            if (dbEpisodes.isNotEmpty()) {
                // Database has episodes - cache and return
                episodeCache[seriesId] = dbEpisodes
                Log.d(tag, "✅ Using episodes from DATABASE")
                return@withContext dbEpisodes
            } else {
                dbWasEmpty = true
                Log.d(tag, "📚 Database empty for series $seriesId - will fetch from provider")
            }
        } catch (e: Exception) {
            Log.e(tag, "❌ Database fetch failed", e)
            Log.e(tag, "❌ Database URL attempted: ${session.getGatewayUrl()}series/concepts/episodes.php?token=$WORKERS_API_TOKEN&seriesId=$seriesId")
            dbWasEmpty = true
        }

        // STEP 2: IF DATABASE EMPTY, FETCH FROM PROVIDER TO SERVE USER NOW
        if (dbWasEmpty) {
            try {
                Log.d(tag, "🌐 [getEpisodes] Fetching from provider API to serve user immediately...")

                val u = session.getUsername()
                if (u == null) {
                    Log.e(tag, "❌ Username is null")
                    return@withContext emptyList()
                }

                val p = session.getPassword()
                if (p == null) {
                    Log.e(tag, "❌ Password is null")
                    return@withContext emptyList()
                }

                // Get the provider URL
                val providerUrl = session.getProviderUrl()?.removeSuffix("/") ?: ""

                Log.d(tag, "🔍 PROVIDER URL: $providerUrl")
                Log.d(tag, "🔍 FETCHING FROM: ${providerUrl}/player_api.php?username=$u&password=$p&action=get_series_info&series_id=$seriesId")

                // Create a new Retrofit instance with the provider URL
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
                    episodeList.forEach { providerEpisode ->

                        // Format: http://server:port/series/username/password/EPISODE_ID
                        val streamUrl = "$providerUrl/series/$u/$p/${providerEpisode.id}"

                        val coverUrl = providerEpisode.info?.movie_image

                        val episodeItem = AppModels.EpisodeItem(
                            id = providerEpisode.id,
                            title = providerEpisode.title,
                            season = seasonNum.toIntOrNull() ?: 1,
                            episodeNum = providerEpisode.episode_num,
                            streamUrl = streamUrl,
                            cover = coverUrl
                        )
                        providerEpisodes.add(episodeItem)
                    }
                }

                Log.d(tag, "✅ Provider returned ${providerEpisodes.size} episodes")

                if (providerEpisodes.isEmpty()) {
                    Log.w(tag, "⚠️ No episodes found in provider response")
                    return@withContext emptyList()
                }

                // Cache in memory for immediate use
                episodeCache[seriesId] = providerEpisodes

                // STEP 3: TRIGGER BACKGROUND INGESTION - just pass the series_id, no JSON
                Log.d(tag, "🔄 Triggering background ingestion for series $seriesId")
                triggerOneOffIngestion(seriesId)

                Log.d(tag, "✅ Returning ${providerEpisodes.size} episodes to user (from provider)")
                Log.d(tag, "🔄 Background ingestion triggered for series_id=$seriesId")

                return@withContext providerEpisodes

            } catch (e: Exception) {
                Log.e(tag, "❌ Provider fetch failed", e)
                Log.e(tag, "❌ Provider URL attempted: ${session.getProviderUrl()}")
            }
        }

        Log.w(tag, "⚠️ No episodes found for series $seriesId from any source")
        return@withContext emptyList()
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
    // STREAM URL BUILDERS - CORRECT XTREAM PATHS
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