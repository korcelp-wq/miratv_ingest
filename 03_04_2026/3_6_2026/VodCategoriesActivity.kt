package com.miratv.app.ui.vod

import android.content.Intent
import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.LinearLayoutManager
import com.miratv.app.databinding.ActivityListBinding
import com.miratv.app.mapping.ModelMapper
import com.miratv.app.ui.ActivationActivity
import com.miratv.app.ui.vod.adapters.VodCategoriesAdapter
import com.miratv.app.util.SessionManager
import com.miratv.app.xtream.XtreamService
import kotlinx.coroutines.launch
import retrofit2.Retrofit
import retrofit2.converter.gson.GsonConverterFactory
import android.util.Log

class VodCategoriesActivity : AppCompatActivity() {

    private lateinit var binding: ActivityListBinding
    private lateinit var service: XtreamService

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        binding = ActivityListBinding.inflate(layoutInflater)
        setContentView(binding.root)

        title = "VOD · Categories"

        val session = SessionManager(this)
        val base = session.getGatewayUrl()

        // Defensive gate
        if (base.isNullOrBlank()) {
            startActivity(Intent(this, ActivationActivity::class.java))
            finish()
            return
        }

        // ...existing code...
            service = Retrofit.Builder()
            .baseUrl(base)
            .addConverterFactory(GsonConverterFactory.create())
            .build()
            .create(XtreamService::class.java)

        val adapter = VodCategoriesAdapter { cat ->
            val i = Intent(this, VodListActivity::class.java)
            i.putExtra("catId", cat.id)
            startActivity(i)
        }

        binding.recycler.layoutManager = LinearLayoutManager(this)
        binding.recycler.adapter = adapter

        lifecycleScope.launch {
            val raw = service.getVodCategories(
                username = session.getUsername().orEmpty(),
                password = session.getPassword().orEmpty()
            )

            Log.e("VOD_DEBUG", "categories=${raw.size}")

            adapter.submitList(raw.map { ModelMapper.toVodCategory(it) })
        }
    }
}
