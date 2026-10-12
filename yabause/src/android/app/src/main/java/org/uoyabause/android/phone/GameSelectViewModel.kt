package org.uoyabause.android.phone

import android.app.Application
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.activity.result.ActivityResultLauncher
import androidx.fragment.app.Fragment
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.auth.FirebaseAuth
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.devmiyax.yabasanshiro.R
import org.uoyabause.android.CloudGameInfo
import org.uoyabause.android.FreeGameSlots
import org.uoyabause.android.GameInfo
import org.uoyabause.android.GameSelectPresenter
import org.uoyabause.android.YabauseStorage
import org.uoyabause.android.backup.GameBackupManager
import java.util.Locale

class GameSelectViewModel(
    application: Application,
) : AndroidViewModel(application) {
    private val _screenState = MutableStateFlow(GameSelectScreenState())
    val screenState: StateFlow<GameSelectScreenState> = _screenState.asStateFlow()

    private val _uiEvents = Channel<GameSelectUiEvent>(Channel.BUFFERED)
    val uiEvents = _uiEvents.receiveAsFlow()

    private var allGames: List<GameInfo> = emptyList()
    private var updateJob: Job? = null

    var presenter: GameSelectPresenter? = null
        private set

    fun initPresenter(
        fragment: Fragment,
        launcher: ActivityResultLauncher<Intent>,
        listener: GameSelectPresenter.GameSelectPresenterListener,
    ) {
        if (presenter == null) {
            presenter = GameSelectPresenter(fragment, launcher, listener)
        } else {
            presenter?.updateReferences(fragment, launcher, listener)
        }
    }

    fun setSubscribed(subscribed: Boolean) {
        _screenState.update { it.copy(isSubscribed = subscribed) }
        presenter?.isOnSubscription = subscribed
        if (allGames.isNotEmpty()) {
            reapplyFilter()
        }
    }

    fun loadGames() {
        viewModelScope.launch {
            _screenState.update { it.copy(listState = GameListUiState.Loading) }
            try {
                val localGames = withContext(Dispatchers.IO) {
                    YabauseStorage.dao.getAll()
                }
                val cloudGames = fetchCloudOnlyGames()
                val combined = localGames + cloudGames
                allGames = combined

                if (combined.isEmpty()) {
                    _screenState.update {
                        it.copy(
                            listState = GameListUiState.Empty,
                            gameCount = 0,
                            selectedGame = null,
                            unlockedPaths = null,
                            lockedCount = 0,
                        )
                    }
                } else {
                    val sorted = applySortAndFilter(combined, _screenState.value.sortMode, _screenState.value.searchQuery)
                    val unlocked = freeSlots()
                    _screenState.update {
                        it.copy(
                            listState = GameListUiState.Success(sorted),
                            gameCount = combined.size,
                            selectedGame = sorted.firstOrNull(),
                            unlockedPaths = unlocked,
                            lockedCount = FreeGameSlots.lockedCount(combined, unlocked),
                        )
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error loading games", e)
                _screenState.update {
                    it.copy(listState = GameListUiState.Error(e.localizedMessage ?: "Unknown error"))
                }
            }
        }
    }

    fun updateGameDatabase(refreshLevel: Int = 0) {
        val p = presenter ?: return
        updateJob?.cancel()
        updateJob = viewModelScope.launch {
            _screenState.update { it.copy(isRefreshing = true, listState = GameListUiState.Loading) }
            try {
                if (!p.prepareStorage()) {
                    _screenState.update { it.copy(isRefreshing = false) }
                    return@launch
                }
                p.updateGameDatabase(refreshLevel) { message ->
                    viewModelScope.launch {
                        _uiEvents.send(GameSelectUiEvent.UpdateProgress(message))
                    }
                }
                loadGames()
            } catch (e: Exception) {
                Log.e(TAG, "Error updating game database", e)
                _uiEvents.send(GameSelectUiEvent.ShowSnackbar(e.localizedMessage ?: "Update failed"))
            } finally {
                _screenState.update { it.copy(isRefreshing = false) }
            }
        }
    }

    fun setSortMode(mode: GameSortMode) {
        _screenState.update { it.copy(sortMode = mode) }
        saveSortMode(mode)
        reapplyFilter()
    }

    fun setSearchQuery(query: String) {
        _screenState.update { it.copy(searchQuery = query) }
        reapplyFilter()
    }

    fun selectGame(game: GameInfo?) {
        _screenState.update { it.copy(selectedGame = game) }
    }

    fun startGame(
        item: GameInfo,
        launcher: ActivityResultLauncher<Intent>,
    ) {
        if (item.isCloudOnly && item.cloudBackupInfo != null) {
            downloadCloudGame(item.cloudBackupInfo!!)
        } else {
            // Asked again here rather than trusted from the caller: the
            // landscape pane holds its selection across a rescan, so the game
            // it is showing can become locked while the pane is still open.
            if (!allowOpen(item)) return
            presenter?.startGame(item, launcher)
        }
    }

    fun requestDeleteGame(game: GameInfo) {
        viewModelScope.launch {
            _uiEvents.send(GameSelectUiEvent.ShowConfirmDelete(game))
        }
    }

    fun confirmDeleteGame(game: GameInfo) {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                game.removeInstance(null)
                withContext(Dispatchers.Main) {
                    loadGames()
                    _uiEvents.send(
                        GameSelectUiEvent.ShowSnackbar("${game.game_title} deleted"),
                    )
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error deleting game", e)
                withContext(Dispatchers.Main) {
                    _uiEvents.send(
                        GameSelectUiEvent.ShowSnackbar("Delete failed: ${e.localizedMessage}"),
                    )
                }
            }
        }
    }

    fun onFileSelected(uri: android.net.Uri) {
        presenter?.onSelectFile(uri)
    }

    private fun reapplyFilter() {
        val state = _screenState.value
        val sorted = applySortAndFilter(allGames, state.sortMode, state.searchQuery)
        if (sorted.isEmpty() && allGames.isEmpty()) {
            _screenState.update {
                it.copy(listState = GameListUiState.Empty, unlockedPaths = null, lockedCount = 0)
            }
        } else {
            // Computed from the whole library, not from `sorted`: the free slots
            // must not follow the sort or the search box.
            val unlocked = freeSlots()
            _screenState.update {
                it.copy(
                    listState = GameListUiState.Success(sorted),
                    selectedGame = if (it.selectedGame != null && sorted.contains(it.selectedGame)) {
                        it.selectedGame
                    } else {
                        sorted.firstOrNull()
                    },
                    unlockedPaths = unlocked,
                    lockedCount = FreeGameSlots.lockedCount(allGames, unlocked),
                )
            }
        }
    }

    /** The current free allowance over the whole library, or null when unlimited. */
    private fun freeSlots(): Set<String>? =
        FreeGameSlots.unlockedPaths(allGames, _screenState.value.isSubscribed, getApplication())

    /**
     * Whether this game may be opened. A locked one asks for the subscription
     * instead, and returns false so the caller shows nothing else.
     *
     * Every route into a game goes through here - tapping a card, the gamepad A
     * button, and the play button in the detail sheet and the landscape pane.
     */
    fun allowOpen(item: GameInfo): Boolean {
        if (!FreeGameSlots.isLocked(item, _screenState.value.unlockedPaths)) {
            return true
        }
        presentProGate(R.string.game_locked_pro_gate_message)
        return false
    }

    /** Opens the subscription gate, from the banner or from a locked game. */
    fun presentProGate(messageResId: Int? = null) {
        viewModelScope.launch {
            _uiEvents.send(GameSelectUiEvent.ShowProGate(messageResId))
        }
    }

    private fun applySortAndFilter(
        games: List<GameInfo>,
        sortMode: GameSortMode,
        query: String,
    ): List<GameInfo> {
        val filtered = if (query.isBlank()) {
            games
        } else {
            games.filter {
                it.game_title.lowercase(Locale.getDefault()).contains(query.lowercase(Locale.getDefault()))
            }
        }
        return when (sortMode) {
            GameSortMode.NAME -> filtered.sortedWith(compareBy({ it.game_title.lowercase(Locale.getDefault()) }, { it.device_infomation }))
            GameSortMode.DATE -> filtered.sortedBy { it.release_date }
            GameSortMode.RECENTLY_PLAYED -> filtered.sortedByDescending { it.lastplay_date }
        }
    }

    private suspend fun fetchCloudOnlyGames(): List<GameInfo> {
        val auth = FirebaseAuth.getInstance()
        if (auth.currentUser == null) return emptyList()
        return try {
            withContext(Dispatchers.IO) {
                val gameBackupManager = GameBackupManager(getApplication())
                val backedUpGames = gameBackupManager.getBackedUpGames()
                if (backedUpGames.isEmpty()) return@withContext emptyList()

                val localGames = YabauseStorage.dao.getAll()
                val localProductNumbers = localGames.map { it.product_number }
                backedUpGames
                    .filter { !localProductNumbers.contains(it.productNumber) }
                    .map { CloudGameInfo(it).toGameInfo() }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error fetching cloud games: ${e.message}")
            emptyList()
        }
    }

    private fun downloadCloudGame(backupGameInfo: GameBackupManager.BackupGameInfo) {
        viewModelScope.launch {
            _uiEvents.send(GameSelectUiEvent.ShowProgress("Downloading game..."))
            try {
                val gameBackupManager = GameBackupManager(getApplication())
                val result = gameBackupManager.restoreGame(backupGameInfo)
                _uiEvents.send(GameSelectUiEvent.DismissProgress)
                if (result.success) {
                    _uiEvents.send(GameSelectUiEvent.ShowSnackbar("Download complete"))
                    updateGameDatabase()
                } else {
                    _uiEvents.send(GameSelectUiEvent.ShowSnackbar("Download failed: ${result.message}"))
                }
            } catch (e: Exception) {
                _uiEvents.send(GameSelectUiEvent.DismissProgress)
                _uiEvents.send(GameSelectUiEvent.ShowSnackbar("Download failed: ${e.localizedMessage}"))
            }
        }
    }

    private fun saveSortMode(mode: GameSortMode) {
        getApplication<Application>()
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_SORT_MODE, mode.name)
            .apply()
    }

    fun loadSortMode(): GameSortMode {
        val prefs = getApplication<Application>()
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val saved = prefs.getString(KEY_SORT_MODE, GameSortMode.NAME.name)
        return try {
            GameSortMode.valueOf(saved ?: GameSortMode.NAME.name)
        } catch (e: IllegalArgumentException) {
            GameSortMode.NAME
        }
    }

    companion object {
        private const val TAG = "GameSelectViewModel"
        private const val PREFS_NAME = "game_select_prefs"
        private const val KEY_SORT_MODE = "sort_mode"
    }
}
