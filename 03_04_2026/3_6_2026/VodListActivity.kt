package com.miratv.app.ui.vod

import android.content.Intent
import android.os.Bundle
import android.util.Log
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.LinearLayoutManager
import com.miratv.app.databinding.ActivityListBinding
import com.miratv.app.mapping.ModelMapper
import com.miratv.app.models.AppModels
import com.miratv.app.ui.PlayerActivity
import com.miratv.app.ui.vod.adapters.VodListAdapter
import com.miratv.app.util.SessionManager
import com.miratv.app.xtream.XtreamService
import kotlinx.coroutines.launch
import retrofit2.Retrofit
import retrofit2.converter.gson.GsonConverterFactory

class VodListActivity : AppCompatActivity() {

    private lateinit var binding: ActivityListBinding
    private lateinit var service: XtreamService
    private val TAG = "VodListActivity"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        binding = ActivityListBinding.inflate(layoutInflater)
        setContentView(binding.root)

        title = "VOD · Movies"

        val categoryId = intent.getIntExtra("catId", 0)
        if (categoryId == 0) {
            finish()
            return
        }

        val session = SessionManager(this)
        val base = session.getGatewayUrl()
        if (base == null) {
            finish()
            return
        }

        service = Retrofit.Builder()
            .baseUrl(base)
            .addConverterFactory(GsonConverterFactory.create())
            .build()
            .create(XtreamService::class.java)

        val adapter = VodListAdapter { vod: AppModels.VodItem ->
            val i = Intent(this, PlayerActivity::class.java)

            // Use provider URL for streaming
            val providerBase = session.getProviderUrl()
            val playUrl = providerBase.trimEnd('/') +
                    "/movie/${session.getUsername()}/${session.getPassword()}/${vod.id}.mp4"

            i.putExtra("streamUrl", playUrl)
            startActivity(i)
        }

        binding.recycler.layoutManager = LinearLayoutManager(this)
        binding.recycler.adapter = adapter

        lifecycleScope.launch {
            val raw = service.getVodStreams(
                username = session.getUsername() ?: "",
                password = session.getPassword() ?: ""
            )

            Log.d(TAG, "Filtering VOD streams. categoryId=$categoryId, type=${categoryId::class.simpleName}")

            val list = raw
                .filter {
                    val catId = it.categoryId?.toString()?.toIntOrNull()
                    Log.d(TAG, "Stream categoryId=${it.categoryId}, converted=$catId, match=${catId == categoryId}")
                    catId == categoryId
                }
                .map { ModelMapper.toVodItem(raw = it) }

            Log.d(TAG, "Filtered ${list.size} streams")
            adapter.submitList(list)
        }
    }
}