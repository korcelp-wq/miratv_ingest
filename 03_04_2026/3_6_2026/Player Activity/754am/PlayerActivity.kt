package com.miratv.app.ui

import android.net.Uri
import android.os.Bundle
import android.util.Log
import android.view.View
import android.widget.ProgressBar
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.PlayerView
import com.miratv.app.R
import com.miratv.app.config.ProviderContextBuilder
import java.util.Locale

class PlayerActivity : AppCompatActivity() {

    companion object {
        private const val TAG = "PlayerActivity"
    }

    private lateinit var playerView: PlayerView
    private lateinit var progress: ProgressBar

    private var player: ExoPlayer? = null
    private var streamUrl: String = ""
    private var streamName: String? = null

    private val playbackCandidates = mutableListOf<String>()
    private var currentCandidateIndex = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_player)

        playerView = findViewById(R.id.playerView)
        progress = findViewById(R.id.progress)

        // Accept both legacy and current keys
        streamUrl =
            intent.getStringExtra("STREAM_URL")
                ?: intent.getStringExtra("streamUrl")
                        ?: ""

        streamName =
            intent.getStringExtra("TITLE")
                ?: intent.getStringExtra("streamName")

        Log.d(TAG, "Received STREAM_URL=$streamUrl")
        Log.d(TAG, "Received TITLE=$streamName")

        if (streamName?.isNotBlank() == true) {
            title = streamName
        }

        if (streamUrl.isBlank()) {
            Toast.makeText(this, "Missing stream URL", Toast.LENGTH_LONG).show()
            Log.e(TAG, "Missing stream URL in intent extras")
            finish()
            return
        }

        val ctx = ProviderContextBuilder.build(this)
        if (ctx == null) {
            Toast.makeText(this, "Activation required", Toast.LENGTH_LONG).show()
            Log.e(TAG, "ProviderContextBuilder returned null")
            finish()
            return
        }

        playbackCandidates.clear()
        playbackCandidates.addAll(buildPlaybackCandidates(streamUrl))
        currentCandidateIndex = 0

        Log.d(TAG, "Playback candidates:")
        playbackCandidates.forEachIndexed { index, url ->
            Log.d(TAG, "  [$index] $url")
        }
    }

    override fun onStart() {
        super.onStart()
        initializePlayer()
    }

    override fun onResume() {
        super.onResume()
        player?.playWhenReady = true
    }

    override fun onPause() {
        super.onPause()
        player?.playWhenReady = false
    }

    override fun onStop() {
        super.onStop()
        releasePlayer()
    }

    private fun initializePlayer() {
        if (player != null) return

        progress.visibility = View.VISIBLE

        val initialUrl = getCurrentPlaybackUrl()
        if (initialUrl.isBlank()) {
            Toast.makeText(this, "No playable stream URL", Toast.LENGTH_LONG).show()
            Log.e(TAG, "No playback candidate available")
            finish()
            return
        }

        Log.d(TAG, "Initializing player with URL=$initialUrl")

        val dataSourceFactory = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(15_000)
            .setReadTimeoutMs(15_000)
            .setDefaultRequestProperties(emptyMap())

        val mediaSourceFactory = DefaultMediaSourceFactory(dataSourceFactory)

        player = ExoPlayer.Builder(this)
            .setMediaSourceFactory(mediaSourceFactory)
            .build()
            .also { exo ->
                playerView.player = exo
                playerView.keepScreenOn = true
                playerView.controllerShowTimeoutMs = 3000
                playerView.controllerHideOnTouch = true
                playerView.showController()

                exo.addListener(object : Player.Listener {

                    override fun onPlaybackStateChanged(state: Int) {
                        when (state) {
                            Player.STATE_BUFFERING -> {
                                progress.visibility = View.VISIBLE
                                Log.d(TAG, "Player state = BUFFERING")
                            }

                            Player.STATE_READY -> {
                                progress.visibility = View.GONE
                                Log.d(
                                    TAG,
                                    "Player state = READY (candidateIndex=$currentCandidateIndex url=${getCurrentPlaybackUrl()})"
                                )
                            }

                            Player.STATE_ENDED -> {
                                progress.visibility = View.GONE
                                Log.d(TAG, "Player state = ENDED")
                            }

                            Player.STATE_IDLE -> {
                                Log.d(TAG, "Player state = IDLE")
                            }
                        }
                    }

                    override fun onPlayerError(error: PlaybackException) {
                        progress.visibility = View.GONE
                        Log.e(
                            TAG,
                            "Playback error on candidateIndex=$currentCandidateIndex url=${getCurrentPlaybackUrl()} : ${error.errorCodeName} / ${error.message}",
                            error
                        )

                        if (moveToNextCandidate()) {
                            Toast.makeText(
                                this@PlayerActivity,
                                "Playback error. Trying alternate stream…",
                                Toast.LENGTH_SHORT
                            ).show()
                            retryPlayback()
                        } else {
                            Toast.makeText(
                                this@PlayerActivity,
                                "Playback failed: ${error.errorCodeName}",
                                Toast.LENGTH_LONG
                            ).show()
                        }
                    }
                })

                setPlayerMediaItem(exo, initialUrl)
                exo.prepare()
                exo.playWhenReady = true
            }
    }

    private fun retryPlayback() {
        val retryUrl = getCurrentPlaybackUrl()
        if (retryUrl.isBlank()) {
            Log.e(TAG, "retryPlayback called with blank retry URL")
            progress.visibility = View.GONE
            return
        }

        player?.apply {
            stop()
            clearMediaItems()
            setPlayerMediaItem(this, retryUrl)
            prepare()
            playWhenReady = true
        }

        progress.visibility = View.VISIBLE
        Log.d(TAG, "Retrying playback with URL=$retryUrl")
    }

    private fun setPlayerMediaItem(exoPlayer: ExoPlayer, url: String) {
        val mediaItem = MediaItem.Builder()
            .setUri(Uri.parse(url))
            .build()

        exoPlayer.setMediaItem(mediaItem)
    }

    private fun getCurrentPlaybackUrl(): String {
        return playbackCandidates.getOrNull(currentCandidateIndex).orEmpty()
    }

    private fun moveToNextCandidate(): Boolean {
        if (currentCandidateIndex + 1 >= playbackCandidates.size) {
            return false
        }
        currentCandidateIndex += 1
        Log.d(TAG, "Switching to playback candidate index=$currentCandidateIndex url=${getCurrentPlaybackUrl()}")
        return true
    }

    private fun buildPlaybackCandidates(originalUrl: String): List<String> {
        val ordered = linkedSetOf<String>()
        val trimmed = originalUrl.trim()

        if (trimmed.isBlank()) {
            return emptyList()
        }

        ordered.add(trimmed)

        val noExtensionUrl = removeKnownContainerExtension(trimmed)
        if (noExtensionUrl != null && noExtensionUrl != trimmed) {
            ordered.add(noExtensionUrl)
        }

        return ordered.toList()
    }

    private fun removeKnownContainerExtension(url: String): String? {
        val lower = url.lowercase(Locale.US)
        val knownExtensions = listOf(".mp4", ".mkv", ".avi", ".mov", ".mpeg", ".mpg", ".m4v", ".ts")

        val matchedExtension = knownExtensions.firstOrNull { lower.endsWith(it) } ?: return null
        return url.dropLast(matchedExtension.length)
    }

    private fun releasePlayer() {
        playerView.player = null
        player?.release()
        player = null
    }
}