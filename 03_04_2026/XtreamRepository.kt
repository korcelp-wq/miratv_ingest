package com.miratv.app.xtream

import android.content.Context
import android.util.Log
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
            // Gateway for API calls (categories, series, etc.)
            val gatewayUrl = session.getGatewayUrl()

            // 🔍 LOG THE GATEWAY URL AT CREATION
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

        // Use provider URL for API calls
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
        Log.d(TAG, "[getSeriesByCategory] Full endpoint: ${session.getGatewayUrl()}series/concepts/by-category?token=$WORKERS_API_TOKEN&categoryId=$categoryId&limit=$limit&offset=$offset")

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

        // Use provider URL for API calls
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
    // SERIES EPISODES - CRITICAL FLOW WITH PROVIDER-SPECIFIC PARSING
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
            Log.d(tag, "📚 Database endpoint: ${session.getGatewayUrl()}series/concepts/episodes?token=$WORKERS_API_TOKEN&seriesId=$seriesId")

            val dbEpisodes = workersApi.getEpisodesBySeriesId(
                token = WORKERS_API_TOKEN,
                seriesId = seriesId
            )

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
            Log.e(tag, "❌ Database URL attempted: ${session.getGatewayUrl()}series/concepts/episodes?token=$WORKERS_API_TOKEN&seriesId=$seriesId")
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
                    .client(OkHttpClient.Builder()
                        .callTimeout(30, TimeUnit.SECONDS)
                        .connectTimeout(30, TimeUnit.SECONDS)
                        .readTimeout(30, TimeUnit.SECONDS)
                        .build())
                    .build()

                // Use the PROVIDER-SPECIFIC service that matches the actual API response
                val providerApi = providerRetrofit.create(ProviderXtreamService::class.java)

                // Call the provider API
                val providerResponse = providerApi.getSeriesInfo(u, p, "get_series_info", seriesId)

                // Convert provider episodes to your app's EpisodeItem format
                val providerEpisodes = mutableListOf<AppModels.EpisodeItem>()

                providerResponse.episodes?.forEach { (seasonNum, episodeList) ->
                    episodeList.forEach { providerEpisode ->

                        // Build the stream URL for this episode using the correct format
                        // Format: http://server:port/series/username/password/EPISODE_ID
                        val streamUrl = "$providerUrl/series/$u/$p/${providerEpisode.id}"

                        // Get cover image if available from info
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

    /**
     * Triggers the one_off_runner.bat with the given series_id in background
     * NO JSON - just passes the series_id as a parameter
     */
    private fun triggerOneOffIngestion(seriesId: Int) {
        val tag = "$TAG.triggerOneOffIngestion"

        try {
            // Path to your one_off_runner.bat
            val batchFilePath = "C:\\miratv_ingest\\one_off_runner.bat"

            // Check if file exists
            val batchFile = java.io.File(batchFilePath)
            if (!batchFile.exists()) {
                Log.e(tag, "❌ Batch file not found: $batchFilePath")
                return
            }

            // Build the command: one_off_runner.bat 12345
            // NO JSON - just the series_id as a parameter
            val command = arrayOf("cmd", "/c", batchFilePath, seriesId.toString())

            Log.d(tag, "🔄 Triggering background ingestion for series $seriesId")
            Log.d(tag, "📋 Command: ${command.joinToString(" ")}")

            // Use ProcessBuilder to run the batch file asynchronously
            val processBuilder = ProcessBuilder(*command)
            processBuilder.directory(batchFile.parentFile)
            processBuilder.redirectErrorStream(true)

            val process = processBuilder.start()

            // Read output in a separate thread to avoid blocking
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

    /**
     * Optional: Method to check if ingestion is complete and refresh from database
     */
    suspend fun refreshEpisodesFromDatabase(seriesId: Int): List<AppModels.EpisodeItem>? = withContext(Dispatchers.IO) {
        val tag = "$TAG.refreshEpisodesFromDatabase($seriesId)"

        try {
            Log.d(tag, "🔄 Checking if ingestion completed for series $seriesId")

            val dbEpisodes = workersApi.getEpisodesBySeriesId(
                token = WORKERS_API_TOKEN,
                seriesId = seriesId
            )

            if (dbEpisodes.isNotEmpty()) {
                Log.d(tag, "✅ Ingestion complete! ${dbEpisodes.size} episodes now in database")
                episodeCache[seriesId] = dbEpisodes
                return@withContext dbEpisodes
            } else {
                Log.d(tag, "⏳ Ingestion still in progress for series $seriesId")
                return@withContext null
            }

        } catch (e: Exception) {
            Log.e(tag, "❌ Error checking ingestion status", e)
            return@withContext null
        }
    }

    private suspend fun saveEpisodesToDatabase(seriesId: Int, episodes: List<AppModels.EpisodeItem>) {
        // Placeholder: implement when you have an endpoint to save episodes
        Log.d(TAG, "💾 Would save ${episodes.size} episodes for series $seriesId to database")
        Log.d(TAG, "💾 Save endpoint would be: ${session.getGatewayUrl()}series/details/episodes/save")
    }

    // =============================================
    // STREAM URL BUILDERS - CORRECT XTREAM PATHS
    // =============================================

    fun buildLiveUrl(streamId: String): String {
        val providerUrl = session.getProviderUrl()?.removeSuffix("/") ?: ""
        val username = session.getUsername() ?: ""
        val password = session.getPassword() ?: ""

        val fullUrl = "$providerUrl/live/$username/$password/$streamId.ts"

        Log.d(TAG, "========== BUILD LIVE URL ==========")
        Log.d(TAG, "Provider URL: $providerUrl")
        Log.d(TAG, "Stream ID: $streamId")
        Log.d(TAG, "Final URL: $fullUrl")
        Log.d(TAG, "=====================================")

        return fullUrl
    }

    fun buildVodUrl(streamId: String, ext: String = "mkv"): String {
        val providerUrl = session.getProviderUrl()?.removeSuffix("/") ?: ""
        val username = session.getUsername() ?: ""
        val password = session.getPassword() ?: ""

        val fullUrl = "$providerUrl/movie/$username/$password/$streamId.$ext"

        Log.d(TAG, "========== BUILD VOD URL ==========")
        Log.d(TAG, "Provider URL: $providerUrl")
        Log.d(TAG, "Stream ID: $streamId")
        Log.d(TAG, "Final URL: $fullUrl")
        Log.d(TAG, "====================================")

        return fullUrl
    }

    fun buildSeriesEpisodeUrl(episodeId: String, ext: String = ""): String {
        val providerUrl = session.getProviderUrl()?.removeSuffix("/") ?: ""
        val username = session.getUsername() ?: ""
        val password = session.getPassword() ?: ""

        // IMPORTANT: /series/username/password/EPISODE_ID
        // Some servers work without extension
        val fullUrl = if (ext.isNotEmpty()) {
            "$providerUrl/series/$username/$password/$episodeId.$ext"
        } else {
            "$providerUrl/series/$username/$password/$episodeId"
        }

        Log.d(TAG, "========== BUILD EPISODE URL ==========")
        Log.d(TAG, "Provider URL: $providerUrl")
        Log.d(TAG, "Episode ID: $episodeId")
        Log.d(TAG, "Final URL: $fullUrl")
        Log.d(TAG, "========================================")

        return fullUrl
    }

    suspend fun resolveLiveUrl(streamId: String): String = withContext(Dispatchers.IO) {
        val providerUrl = session.getProviderUrl()?.removeSuffix("/") ?: ""
        val username = session.getUsername() ?: ""
        val password = session.getPassword() ?: ""

        Log.d(TAG, "========== RESOLVE LIVE URL ==========")
        Log.d(TAG, "Provider URL: $providerUrl")
        Log.d(TAG, "Stream ID: $streamId")
        Log.d(TAG, "Testing extensions...")
        Log.d(TAG, "======================================")

        val extensions = listOf("ts", "m3u8", "mp4")
        for (ext in extensions) {
            val url = "$providerUrl/live/$username/$password/$streamId.$ext"
            Log.d(TAG, "Testing: $url")
            if (isReachable(url)) {
                Log.d(TAG, "✅ Found working URL: $url")
                return@withContext url
            }
        }
        val fallbackUrl = "$providerUrl/live/$username/$password/$streamId.ts"
        Log.d(TAG, "⚠️ Using fallback URL: $fallbackUrl")
        return@withContext fallbackUrl
    }

    private suspend fun isReachable(url: String): Boolean = withContext(Dispatchers.IO) {
        try {
            val client = OkHttpClient.Builder()
                .callTimeout(3, TimeUnit.SECONDS)
                .connectTimeout(3, TimeUnit.SECONDS)
                .readTimeout(3, TimeUnit.SECONDS)
                .build()

            val request = Request.Builder()
                .url(url)
                .head()
                .build()

            client.newCall(request).execute().use { resp ->
                val reachable = resp.isSuccessful
                Log.d(TAG, "isReachable: $url - ${if (reachable) "✅" else "❌"} (${resp.code})")
                reachable
            }
        } catch (e: Exception) {
            Log.d(TAG, "isReachable: $url - ❌ Failed: ${e.message}")
            false
        }
    }
}