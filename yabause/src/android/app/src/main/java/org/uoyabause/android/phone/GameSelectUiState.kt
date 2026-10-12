package org.uoyabause.android.phone

import org.uoyabause.android.GameInfo

enum class GameSortMode {
    NAME,
    DATE,
    RECENTLY_PLAYED,
}

sealed class GameListUiState {
    data object Initial : GameListUiState()

    data object Loading : GameListUiState()

    data class Success(
        val games: List<GameInfo>,
    ) : GameListUiState()

    data class Error(
        val message: String,
    ) : GameListUiState()

    data object Empty : GameListUiState()
}

data class GameSelectScreenState(
    val listState: GameListUiState = GameListUiState.Initial,
    val sortMode: GameSortMode = GameSortMode.NAME,
    val searchQuery: String = "",
    val selectedGame: GameInfo? = null,
    val isRefreshing: Boolean = false,
    val isSubscribed: Boolean = false,
    val gameCount: Int = 0,
    // The paths the free version may play, or null when there is no limit. Held
    // per game rather than per row so that sorting and searching the list cannot
    // change which games are locked (FreeGameSlots).
    val unlockedPaths: Set<String>? = null,
    // How many games in the whole library the limit is keeping out of reach. The
    // subscribe banner shows only once this is above zero.
    val lockedCount: Int = 0,
)

sealed class GameSelectUiEvent {
    data class ShowSnackbar(
        val message: String,
    ) : GameSelectUiEvent()

    data class ShowSnackbarRes(
        val stringResId: Int,
    ) : GameSelectUiEvent()

    data class NavigateToGame(
        val gameInfo: GameInfo,
    ) : GameSelectUiEvent()

    data class ShowConfirmDelete(
        val gameInfo: GameInfo,
    ) : GameSelectUiEvent()

    data object LaunchFilePicker : GameSelectUiEvent()

    data object OpenSettings : GameSelectUiEvent()

    data object OpenBackupManager : GameSelectUiEvent()

    data object OpenAccountManager : GameSelectUiEvent()

    data class ShowProgress(
        val message: String,
    ) : GameSelectUiEvent()

    data class UpdateProgress(
        val message: String,
    ) : GameSelectUiEvent()

    data object DismissProgress : GameSelectUiEvent()

    data object SignedOut : GameSelectUiEvent()

    /**
     * The subscription gate was asked for. Running the billing flow needs an
     * Activity, so the fragment opens it rather than the view model.
     *
     * The message says why this particular game will not start; it is null when
     * the offer came from the banner, which is about the library rather than
     * about anything the user just chose.
     */
    data class ShowProGate(
        val messageResId: Int?,
    ) : GameSelectUiEvent()
}
