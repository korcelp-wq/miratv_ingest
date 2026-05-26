package com.miratv.app.viewmodel

import androidx.lifecycle.*
import com.miratv.app.models.AppModels.VodCategory
import com.miratv.app.models.AppModels.VodItem
import com.miratv.app.xtream.VodRepository
import kotlinx.coroutines.launch

class VodViewModel(private val repo: VodRepository) : ViewModel() {

    private val _categories = MutableLiveData<List<VodCategory>>(emptyList())
    val categories: LiveData<List<VodCategory>> = _categories

    private val _items = MutableLiveData<List<VodItem>>(emptyList())
    val items: LiveData<List<VodItem>> = _items

    private val _loading = MutableLiveData(false)
    val loading: LiveData<Boolean> = _loading

    private val _error = MutableLiveData<String?>(null)
    val error: LiveData<String?> = _error

    fun loadCategories() {
        _loading.value = true
        _error.value = null
        viewModelScope.launch {
            runCatching { repo.getCategories() }
                .onSuccess { _categories.value = it }
                .onFailure { _error.value = it.message }
            _loading.value = false
        }
    }

    fun loadVodList() {
        _loading.value = true
        _error.value = null
        viewModelScope.launch {
            runCatching { repo.getVodList() }
                .onSuccess { _items.value = it }
                .onFailure { _error.value = it.message }
            _loading.value = false
        }
    }
}
