package com.miratv.app.xtream

import com.miratv.app.models.raw.XtreamRawModels
import retrofit2.http.GET
import retrofit2.http.Query

interface XtreamService {

    @GET("player_api.php")
    suspend fun getAccountInfo(
        @Query("username") username: String,
        @Query("password") password: String
    ): XtreamRawModels.XcAccountRaw?  // Make sure this exists in your raw models

    @GET("player_api.php?action=get_live_categories")
    suspend fun getLiveCategories(
        @Query("username") username: String,
        @Query("password") password: String
    ): List<XtreamRawModels.XcCategoryRaw>

    @GET("player_api.php?action=get_live_streams")
    suspend fun getLiveStreams(
        @Query("username") username: String,
        @Query("password") password: String
    ): List<XtreamRawModels.XcChannelRaw>

    @GET("player_api.php?action=get_vod_categories")
    suspend fun getVodCategories(
        @Query("username") username: String,
        @Query("password") password: String
    ): List<XtreamRawModels.VodCategoryRaw>

    @GET("player_api.php?action=get_vod_streams")
    suspend fun getVodStreams(
        @Query("username") username: String,
        @Query("password") password: String
    ): List<XtreamRawModels.VodItemRaw>

    @GET("player_api.php?action=get_series_categories")
    suspend fun getSeriesCategories(
        @Query("username") username: String,
        @Query("password") password: String
    ): List<XtreamRawModels.SeriesCategoryRaw>

    @GET("player_api.php?action=get_series")
    suspend fun getSeries(
        @Query("username") username: String,
        @Query("password") password: String,
        @Query("category_id") categoryId: Int? = null
    ): List<XtreamRawModels.SeriesItemRaw>

    @GET("player_api.php?action=get_series_info")
    suspend fun getSeriesInfo(
        @Query("username") username: String,
        @Query("password") password: String,
        @Query("series_id") seriesId: Int
    ): XtreamRawModels.SeriesInfoRaw  // Make sure this exists
}