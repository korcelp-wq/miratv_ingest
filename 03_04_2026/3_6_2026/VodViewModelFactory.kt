package com.miratv.app.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import com.miratv.app.xtream.VodRepository

class VodViewModelFactory(
    private val repo: VodRepository
) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(cls: Class<T>): T {
        if (cls.isAssignableFrom(VodViewModel::class.java)) {
            return VodViewModel(repo) as T
        }
        throw IllegalArgumentException("Unknown ViewModel: $cls")
    }
}
