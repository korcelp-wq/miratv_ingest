package com.miratv.app.models

data class EpisodeItem(
    val id: String,  // Changed from Int to String (matches your API)
    val title: String,
    val season: Int,
    val episodeNum: Int,  // Changed from 'episode' to 'episodeNum'
    val streamUrl: String,
    val cover: String? = null  // Added optional cover
)