package com.miratv.app.ui

import android.net.Uri
import android.os.Bundle
import android.util.Log
import android.view.View
import android.widget.ProgressBar
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.ui.PlayerView
import com.miratv.app.R
import com.miratv.app.config.ProviderContextBuilder

class PlayerActivity : AppCompatActivity() {

    companion object {
        private const val TAG = "PlayerActivity"
    }

    private lateinit var playerView: PlayerView
    private lateinit var progress: ProgressBar

    private var player: ExoPlayer? = null
    private var streamUrl: String = ""
    private var streamName: String? = null

    private var hasRetriedOnce = false

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

        // 🔒 HARD GATE — playback is impossible without activation
        val ctx = ProviderContextBuilder.build(this)
        if (ctx == null) {
            Toast.makeText(this, "Activation required", Toast.LENGTH_LONG).show()
            Log.e(TAG, "ProviderContextBuilder returned null")
            finish()
            return
        }
        // NOTE: ctx values are intentionally NOT used here.
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
        Log.d(TAG, "Initializing player with URL=$streamUrl")

        val dataSourceFactory = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(15_000)
            .setReadTimeoutMs(15_000)
            .setDefaultRequestProperties(emptyMap())

        val mediaItem = MediaItem.Builder()
            .setUri(Uri.parse(streamUrl))
            .setMimeType(MimeTypes.VIDEO_MP4)
            .build()

        val mediaSource = ProgressiveMediaSource
            .Factory(dataSourceFactory)
            .createMediaSource(mediaItem)

        player = ExoPlayer.Builder(this).build().also { exo ->
            playerView.player = exo
            playerView.keepScreenOn = true
            playerView.controllerShowTimeoutMs = 3000
            playerView.controllerHideOnTouch = true
            playerView.showController()

            exo.addListener(object : Player.Listener {

                override fun onPlaybackStateChanged(state: Int) {
                    when (state) {
                        Player.STATE_BUFFERING -> progress.visibility = View.VISIBLE
                        Player.STATE_READY,
                        Player.STATE_ENDED -> progress.visibility = View.GONE
                    }
                }

                override fun onPlayerError(error: PlaybackException) {
                    progress.visibility = View.GONE
                    Log.e(TAG, "Playback error: ${error.errorCodeName}", error)

                    if (!hasRetriedOnce) {
                        hasRetriedOnce = true
                        Toast.makeText(
                            this@PlayerActivity,
                            "Playback error. Retrying…",
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

            exo.setMediaSource(mediaSource)
            exo.prepare()
            exo.playWhenReady = true
        }
    }

    private fun retryPlayback() {
        player?.apply {
            stop()
            clearMediaItems()

            val retryItem = MediaItem.Builder()
                .setUri(Uri.parse(streamUrl))
                .setMimeType(MimeTypes.VIDEO_MP4)
                .build()

            val retrySource = ProgressiveMediaSource
                .Factory(
                    DefaultHttpDataSource.Factory()
                        .setAllowCrossProtocolRedirects(true)
                        .setDefaultRequestProperties(emptyMap())
                )
                .createMediaSource(retryItem)

            setMediaSource(retrySource)
            prepare()
            playWhenReady = true
        }

        progress.visibility = View.VISIBLE
    }

    private fun releasePlayer() {
        playerView.player = null
        player?.release()
        player = null
    }
}