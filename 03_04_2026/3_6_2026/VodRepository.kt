package com.miratv.app.xtream

import com.miratv.app.mapping.ModelMapper
import com.miratv.app.models.AppModels.VodCategory
import com.miratv.app.models.AppModels.VodItem
import com.miratv.app.util.SessionManager

class VodRepository(
    private val api: XtreamService,
    private val session: SessionManager
) {

    suspend fun getCategories(): List<VodCategory> {
        val u = session.getUsername() ?: return emptyList()
        val p = session.getPassword() ?: return emptyList()

        val raw = api.getVodCategories(u, p)
        return raw.map { ModelMapper.toVodCategory(it) }
    }

    suspend fun getVodList(): List<VodItem> {
        val u = session.getUsername() ?: return emptyList()
        val p = session.getPassword() ?: return emptyList()

        val raw = api.getVodStreams(u, p)
        return raw.mapNotNull { ModelMapper.toVodItem(it) }
    }
}
