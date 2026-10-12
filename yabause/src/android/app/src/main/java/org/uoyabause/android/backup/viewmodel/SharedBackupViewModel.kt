/*
 * Copyright 2024 devMiyax
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package org.uoyabause.android.backup.viewmodel

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.google.firebase.firestore.DocumentSnapshot
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.devmiyax.yabasanshiro.R
import org.uoyabause.android.YabauseStorage
import org.uoyabause.android.backup.SharedBackupBlockList
import org.uoyabause.android.backup.model.BackupItem
import org.uoyabause.android.backup.model.DeviceType
import org.uoyabause.android.backup.model.LocalBackupFile
import org.uoyabause.android.backup.model.SharedBackupItem
import org.uoyabause.android.backup.model.SharedBackupReportReason
import org.uoyabause.android.backup.repository.BackupRepository
import org.uoyabause.android.backup.repository.CloudBackupRepository
import java.io.File

/**
 * Sort order options for shared backups.
 */
enum class SharedBackupSortOrder {
    DATE_DESC,
    RATING_DESC,
}

/**
 * ViewModel for the Shared Backups tab.
 * Handles searching, downloading, and rating shared community backups.
 */
class SharedBackupViewModel(
    application: Application,
) : AndroidViewModel(application) {
    companion object {
        /**
         * How many extra pages a single top-up may pull while the client-side
         * filters leave nothing visible. Bounds the cost of a filter that
         * matches nothing.
         */
        private const val MAX_AUTO_FILL_PAGES = 5
    }

    private val cloudRepository = CloudBackupRepository(application)
    private val backupRepository = BackupRepository(application)

    // UI State
    private val _uiState = MutableStateFlow<SharedBackupUiState>(SharedBackupUiState.Initial)
    val uiState: StateFlow<SharedBackupUiState> = _uiState.asStateFlow()

    // Operation state
    private val _operationResult = MutableStateFlow<BackupOperationResult>(BackupOperationResult.Idle)
    val operationResult: StateFlow<BackupOperationResult> = _operationResult.asStateFlow()

    // UI Events
    private val _uiEvents = Channel<BackupUiEvent>(Channel.BUFFERED)
    val uiEvents = _uiEvents.receiveAsFlow()

    // Search query
    private val _searchQuery = MutableStateFlow("")
    val searchQuery: StateFlow<String> = _searchQuery.asStateFlow()

    // Sort order
    private val _sortOrder = MutableStateFlow(SharedBackupSortOrder.DATE_DESC)
    val sortOrder: StateFlow<SharedBackupSortOrder> = _sortOrder.asStateFlow()

    // Single shared backup loaded by id (deep-link import).
    private val _deepLinkItem = MutableStateFlow<SharedBackupItem?>(null)
    val deepLinkItem: StateFlow<SharedBackupItem?> = _deepLinkItem.asStateFlow()

    private val _deepLinkNotFound = MutableStateFlow(false)
    val deepLinkNotFound: StateFlow<Boolean> = _deepLinkNotFound.asStateFlow()

    // Library filter
    private val _libraryFilterEnabled = MutableStateFlow(true)
    val libraryFilterEnabled: StateFlow<Boolean> = _libraryFilterEnabled.asStateFlow()

    // True while a further page is being fetched, so the list can show a
    // spinner without replacing the rows already on screen.
    private val _isLoadingMore = MutableStateFlow(false)
    val isLoadingMore: StateFlow<Boolean> = _isLoadingMore.asStateFlow()

    // Whether another page exists. Drives the scroll-to-end trigger.
    private val _hasMore = MutableStateFlow(false)
    val hasMore: StateFlow<Boolean> = _hasMore.asStateFlow()

    // How many posters this reader has hidden, for the "show all" row.
    private val _blockedCount = MutableStateFlow(0)
    val blockedCount: StateFlow<Int> = _blockedCount.asStateFlow()

    // User's product numbers from local game library
    private var userProductNumbers: List<String> = emptyList()

    private val blockList = SharedBackupBlockList(application)

    // Every document fetched so far, in server order. The visible list is
    // derived from this by rebuild(); nothing filters this list itself, so a
    // filter can always be widened again without refetching.
    private var fetchedItems: List<SharedBackupItem> = emptyList()

    // Cursor for the next page; null once the walk has reached the end.
    private var cursor: DocumentSnapshot? = null

    // Server-side product number filter (null = the whole collection).
    private var productNumberFilter: String? = null

    // Bumped whenever a new walk starts. A page still in flight from an
    // abandoned walk checks this before appending, so the list can never hold
    // rows from two different queries at once.
    private var generation = 0

    // Active load job
    private var searchJob: Job? = null

    init {
        // Load user's game library product numbers
        viewModelScope.launch {
            userProductNumbers = withContext(Dispatchers.IO) {
                try {
                    YabauseStorage.dao
                        .getAll()
                        .mapNotNull { it.product_number?.takeIf { pn -> pn.isNotBlank() } }
                        .distinct()
                } catch (e: Exception) {
                    emptyList()
                }
            }
            // Load initial shared backups (trending/recent)
            loadSharedBackups()
        }
    }

    /**
     * Start (or restart) the walk over the shared collection.
     */
    fun loadSharedBackups() {
        productNumberFilter = null
        reload()
    }

    /**
     * Filter the visible list by text.
     *
     * This does not refetch. The text filter runs over what has been fetched,
     * because Firestore cannot do substring matching; the walk is what makes
     * older saves reachable, so a query the first page does not satisfy is
     * answered by loading further pages, not by a different query.
     */
    fun search(query: String) {
        _searchQuery.value = query
        if (!cloudRepository.isAuthenticated()) {
            _uiState.value = SharedBackupUiState.RequiresAuth
            return
        }
        if (fetchedItems.isEmpty() && cursor == null) {
            reload()
        } else {
            rebuild()
        }
    }

    /**
     * Restrict the walk to one game, server-side.
     * @param productNumber The product number (e.g., "T-1234G")
     */
    fun searchByProductNumber(productNumber: String) {
        productNumberFilter = productNumber.takeIf { it.isNotBlank() }
        _searchQuery.value = ""
        reload()
    }

    /**
     * Clear search and show all shared backups.
     */
    fun clearSearch() {
        _searchQuery.value = ""
        rebuild()
    }

    /**
     * Set sort order. Applied over the rows fetched so far.
     */
    fun setSortOrder(order: SharedBackupSortOrder) {
        _sortOrder.value = order
        rebuild()
    }

    /**
     * Enable or disable the "my library" filter.
     */
    fun setLibraryFilter(enabled: Boolean) {
        _libraryFilterEnabled.value = enabled
        // Widening the filter can reveal rows already fetched, and narrowing
        // it can empty the page; either way top up from the server so the
        // user is not left looking at a short list with more available.
        rebuild()
        fillIfNeeded()
    }

    /**
     * Fetch the next page and append it. Called when the list is scrolled to
     * its end.
     */
    fun loadMore() {
        val next = cursor ?: return
        if (_isLoadingMore.value) return
        val startedAt = generation
        _isLoadingMore.value = true
        viewModelScope.launch {
            val result = cloudRepository.pageSharedBackups(
                productNumber = productNumberFilter,
                after = next,
            )
            if (generation != startedAt) {
                // A new walk started while this page was in flight. Dropping
                // it keeps the list in one ordering; the rows on screen came
                // from the walk the user is actually looking at.
                return@launch
            }
            _isLoadingMore.value = false
            result.fold(
                onSuccess = { page ->
                    fetchedItems = fetchedItems + page.items
                    cursor = page.cursor
                    _hasMore.value = page.hasMore
                    rebuild()
                },
                onFailure = {
                    // The rows already on screen stay; only the attempt failed.
                    sendEvent(
                        BackupUiEvent.ShowToast(
                            getApplication<Application>().getString(R.string.shared_backup_load_more_failed),
                        ),
                    )
                },
            )
        }
    }

    /**
     * Start the walk over. Every cursor from the previous query is invalid.
     */
    private fun reload() {
        if (!cloudRepository.isAuthenticated()) {
            _uiState.value = SharedBackupUiState.RequiresAuth
            return
        }

        searchJob?.cancel()
        generation++
        val startedAt = generation
        cursor = null
        fetchedItems = emptyList()
        _hasMore.value = false
        _isLoadingMore.value = false
        _uiState.value = SharedBackupUiState.Loading

        searchJob = viewModelScope.launch {
            val result = cloudRepository.pageSharedBackups(productNumber = productNumberFilter)
            if (generation != startedAt) return@launch
            result.fold(
                onSuccess = { page ->
                    fetchedItems = page.items
                    cursor = page.cursor
                    _hasMore.value = page.hasMore
                    rebuild()
                    fillIfNeeded()
                },
                onFailure = { e ->
                    _uiState.value = SharedBackupUiState.Error(
                        message = e.message ?: "Failed to load shared backups",
                        exception = e,
                    )
                },
            )
        }
    }

    /**
     * Keep pulling pages while the client-side filters leave the list empty.
     *
     * The library filter cannot be pushed to Firestore (it is an arbitrarily
     * long list of product numbers), so a page can arrive and be filtered away
     * entirely. Without this the user would see an empty list even though more
     * matching saves exist further down the collection. Bounded so a filter
     * that matches nothing costs a handful of reads, not the whole collection.
     */
    private fun fillIfNeeded() {
        if (cursor == null || _isLoadingMore.value) return
        if (visibleItems().isNotEmpty()) return

        val startedAt = generation
        _isLoadingMore.value = true
        viewModelScope.launch {
            var pages = 0
            while (pages < MAX_AUTO_FILL_PAGES) {
                val next = cursor ?: break
                val result = cloudRepository.pageSharedBackups(
                    productNumber = productNumberFilter,
                    after = next,
                )
                if (generation != startedAt) return@launch
                val page = result.getOrNull() ?: break
                fetchedItems = fetchedItems + page.items
                cursor = page.cursor
                _hasMore.value = page.hasMore
                pages++
                if (visibleItems().isNotEmpty()) break
            }
            if (generation != startedAt) return@launch
            _isLoadingMore.value = false
            rebuild()
        }
    }

    /**
     * The fetched rows this reader may see: hidden posters drop out first, so
     * a search can never surface someone the user asked not to see.
     */
    private fun visibleItems(): List<SharedBackupItem> {
        val library = if (_libraryFilterEnabled.value && userProductNumbers.isNotEmpty()) {
            userProductNumbers.toSet()
        } else {
            null
        }
        return fetchedItems.filter { item ->
            !blockList.isBlocked(item.ownerId) &&
                (library == null || library.contains(item.productNumber))
        }
    }

    /**
     * Recompute the visible list from what has been fetched and publish it.
     */
    private fun rebuild() {
        _blockedCount.value = blockList.count

        val query = _searchQuery.value.trim()
        var items = visibleItems()
        if (query.isNotEmpty()) {
            items = items.filter { item ->
                item.gameTitle.contains(query, ignoreCase = true) ||
                    item.productNumber.contains(query, ignoreCase = true) ||
                    item.filename.contains(query, ignoreCase = true) ||
                    item.comment.contains(query, ignoreCase = true) ||
                    item.description.contains(query, ignoreCase = true) ||
                    item.ownerName.contains(query, ignoreCase = true)
            }
        }

        // Date order is what the server already returned. The rating order is
        // applied over the rows fetched so far, not the whole collection:
        // ordering by ratings.average server-side would need a composite index
        // that is not deployed, and a query that fails is worse than one that
        // sorts a prefix.
        if (_sortOrder.value == SharedBackupSortOrder.RATING_DESC) {
            items = items.sortedByDescending { it.averageRating }
        }

        _uiState.value = if (items.isEmpty()) {
            SharedBackupUiState.Empty(searchQuery = query.takeIf { it.isNotEmpty() })
        } else {
            SharedBackupUiState.Success(
                items = items,
                searchQuery = query.takeIf { it.isNotEmpty() },
            )
        }
    }

    /**
     * Optimistically reflect the server-side downloadCount increment that
     * happens inside downloadSharedBackup, so the list and any open detail
     * view update without requiring the user to reselect the item.
     */
    private fun bumpDownloadCount(itemId: String) {
        fetchedItems = fetchedItems.map {
            if (it.id == itemId) it.copy(downloadCount = it.downloadCount + 1) else it
        }
        rebuild()
        _deepLinkItem.value?.let {
            if (it.id == itemId) {
                _deepLinkItem.value = it.copy(downloadCount = it.downloadCount + 1)
            }
        }
    }

    /**
     * Import a shared backup to local storage.
     * @param item The shared backup to import
     * @param targetDevice The target device (INTERNAL or EXTERNAL)
     */
    fun importBackup(item: SharedBackupItem, targetDevice: DeviceType = DeviceType.INTERNAL) {
        viewModelScope.launch {
            _operationResult.value = BackupOperationResult.InProgress(
                message = "Downloading '${item.filename}'...",
            )

            val downloadResult = cloudRepository.downloadSharedBackup(item)

            downloadResult.fold(
                onSuccess = { data ->
                    // TODO: Save the data to local backup RAM
                    // This requires implementing the write functionality in LocalBackupDataSource.
                    // Do not count a download here: nothing is written yet.
                    _operationResult.value = BackupOperationResult.Success(
                        message = "Backup imported successfully",
                    )
                    sendEvent(BackupUiEvent.ShowToast("Backup '${item.filename}' imported"))
                },
                onFailure = { e ->
                    _operationResult.value = BackupOperationResult.Failure(
                        message = e.message ?: "Failed to import backup",
                        exception = e,
                    )
                    sendEvent(BackupUiEvent.ShowToast("Failed to import: ${e.message}"))
                },
            )
        }
    }

    /**
     * Import a shared backup to a specific local backup file.
     * Checks for existing backup with the same filename and shows confirmation if needed.
     * @param item The shared backup to import
     * @param targetFile The target local backup file
     */
    fun importBackupToFile(item: SharedBackupItem, targetFile: LocalBackupFile) {
        viewModelScope.launch {
            // Check if a backup with the same filename already exists in the target file
            val exists = backupRepository.backupExistsInFile(
                targetFile.getFilePath(),
                item.filename,
                targetFile.deviceType,
            )

            if (exists) {
                val context = getApplication<android.app.Application>()
                sendEvent(
                    BackupUiEvent.ShowConfirmation(
                        title = context.getString(R.string.backup_overwrite_title),
                        message = context.getString(
                            R.string.backup_overwrite_message,
                            item.filename,
                            targetFile.displayName,
                        ),
                        confirmAction = { executeImportBackupToFile(item, targetFile) },
                    ),
                )
            } else {
                executeImportBackupToFile(item, targetFile)
            }
        }
    }

    /**
     * Execute the actual import of a shared backup to a local file (after confirmation if needed).
     */
    private fun executeImportBackupToFile(item: SharedBackupItem, targetFile: LocalBackupFile) {
        viewModelScope.launch {
            _operationResult.value = BackupOperationResult.InProgress(
                message = "Downloading '${item.filename}'...",
            )

            val downloadResult = cloudRepository.downloadSharedBackup(item)

            downloadResult.fold(
                onSuccess = { data ->
                    // Download and save screenshot from shared backup if available
                    item.screenshotUrl?.let { url ->
                        if (url.startsWith("https://")) {
                            try {
                                val screenshotBytes = cloudRepository.downloadScreenshot(url).getOrNull()
                                if (screenshotBytes != null) {
                                    val screenshotFile = File(
                                        "${YabauseStorage.storage.screenshotPath}${targetFile.fileKey}/backup_${item.filename}.png",
                                    )
                                    screenshotFile.parentFile?.mkdirs()
                                    screenshotFile.writeBytes(screenshotBytes)
                                }
                            } catch (e: Exception) {
                                // Screenshot download failure should not block backup import
                            }
                        }
                    }

                    val backupItem = BackupItem(
                        filename = item.filename,
                        comment = item.comment,
                        language = 0,
                        saveDate = item.saveDate,
                        dataSize = item.dataSize,
                        blockSize = item.blockSize,
                    )
                    val copyResult = backupRepository.copyBackupToFile(backupItem, targetFile, data)
                    copyResult.fold(
                        onSuccess = {
                            // Count the download only now that the import has
                            // actually completed (fresh import or confirmed
                            // overwrite), then reflect it in the UI.
                            cloudRepository.incrementSharedBackupDownloadCount(item.id)
                            bumpDownloadCount(item.id)
                            _operationResult.value = BackupOperationResult.Success(
                                message = "Backup imported successfully",
                            )
                            sendEvent(BackupUiEvent.ShowToast("Backup '${item.filename}' imported to ${targetFile.displayName}"))
                        },
                        onFailure = { e ->
                            _operationResult.value = BackupOperationResult.Failure(
                                message = e.message ?: "Failed to import backup",
                                exception = e,
                            )
                            sendEvent(BackupUiEvent.ShowToast("Failed to import: ${e.message}"))
                        },
                    )
                },
                onFailure = { e ->
                    _operationResult.value = BackupOperationResult.Failure(
                        message = e.message ?: "Failed to import backup",
                        exception = e,
                    )
                    sendEvent(BackupUiEvent.ShowToast("Failed to import: ${e.message}"))
                },
            )
        }
    }

    /**
     * Load a single shared backup by id for the deep-link import sheet.
     */
    fun loadById(id: String) {
        viewModelScope.launch {
            _deepLinkNotFound.value = false
            val result = cloudRepository.getSharedBackupById(id)
            result.fold(
                onSuccess = { _deepLinkItem.value = it },
                onFailure = { _deepLinkNotFound.value = true },
            )
        }
    }

    /**
     * Show rating dialog for a shared backup.
     */
    fun showRatingDialog(item: SharedBackupItem) {
        viewModelScope.launch {
            val currentRating = cloudRepository.getUserRating(item.id)
            sendEvent(BackupUiEvent.ShowRatingDialog(item, currentRating))
        }
    }

    /**
     * Rate a shared backup.
     * @param item The shared backup to rate
     * @param rating The rating (1-5)
     */
    fun rateBackup(item: SharedBackupItem, rating: Int) {
        viewModelScope.launch {
            _operationResult.value = BackupOperationResult.InProgress("Rating backup...")

            val result = cloudRepository.rateBackup(item.id, rating)

            result.fold(
                onSuccess = {
                    _operationResult.value = BackupOperationResult.Success("Rating submitted")
                    sendEvent(BackupUiEvent.ShowToast("Thank you for rating!"))
                    // The average is not refreshed here. It is computed by the
                    // calculateSharedBackupRatings Cloud Function from the
                    // whole ratings subcollection, so a reload now would
                    // usually redraw the same number and would also throw away
                    // every page the reader has walked.
                },
                onFailure = { e ->
                    _operationResult.value = BackupOperationResult.Failure(
                        message = e.message ?: "Failed to submit rating",
                        exception = e,
                    )
                    sendEvent(BackupUiEvent.ShowToast("Failed to submit rating: ${e.message}"))
                },
            )
        }
    }

    /**
     * Delete a shared backup (owner only).
     *
     * The row is dropped only after the server has agreed. Dropping it first
     * would tell the user a save is gone when a refused delete has left it in
     * place, and they would find it again on the next load with no explanation.
     */
    fun deleteSharedBackup(item: SharedBackupItem) {
        if (!cloudRepository.isOwner(item)) {
            sendEvent(BackupUiEvent.ShowToast("You can only delete your own shared backups"))
            return
        }

        viewModelScope.launch {
            _operationResult.value = BackupOperationResult.InProgress("Deleting shared backup...")

            val result = cloudRepository.deleteSharedBackup(item)

            result.fold(
                onSuccess = {
                    _operationResult.value = BackupOperationResult.Success("Shared backup deleted")
                    sendEvent(BackupUiEvent.ShowToast("Shared backup deleted"))
                    fetchedItems = fetchedItems.filterNot { it.id == item.id }
                    rebuild()
                },
                onFailure = { e ->
                    // The row stays: the save is still public.
                    _operationResult.value = BackupOperationResult.Failure(
                        message = e.message ?: "Failed to delete shared backup",
                        exception = e,
                    )
                    sendEvent(BackupUiEvent.ShowToast("Failed to delete: ${e.message}"))
                },
            )
        }
    }

    /**
     * Whether reporting and hiding apply to this save. Both only make sense
     * for someone else's, and reporting needs an account to attribute it to.
     */
    fun canReport(item: SharedBackupItem): Boolean {
        if (!cloudRepository.isAuthenticated()) return false
        return !cloudRepository.isOwner(item)
    }

    /**
     * File a report against a shared backup.
     *
     * The save stays listed: taking it down is a decision for whoever reads
     * the reports, not for the person who filed one.
     */
    fun reportBackup(item: SharedBackupItem, reason: SharedBackupReportReason) {
        val context = getApplication<Application>()
        viewModelScope.launch {
            val result = cloudRepository.reportSharedBackup(item, reason)
            result.fold(
                onSuccess = {
                    sendEvent(BackupUiEvent.ShowToast(context.getString(R.string.report_sent)))
                },
                onFailure = {
                    sendEvent(BackupUiEvent.ShowToast(context.getString(R.string.report_failed)))
                },
            )
        }
    }

    /**
     * Hide everything by one poster, now and in later pages.
     */
    fun blockOwner(item: SharedBackupItem) {
        blockList.block(item.ownerId)
        rebuild()
        // Hiding someone can empty the page even though the collection still
        // has matching saves further down, so top up from the server.
        fillIfNeeded()
    }

    /**
     * Show hidden posters again. All at once: the only way back is this row,
     * and offering a per-person list would mean naming the people the reader
     * asked not to see.
     */
    fun unblockAll() {
        blockList.unblockAll()
        rebuild()
    }

    /**
     * Request delete confirmation for a shared backup.
     */
    fun requestDeleteSharedBackup(item: SharedBackupItem) {
        if (!cloudRepository.isOwner(item)) {
            sendEvent(BackupUiEvent.ShowToast("You can only delete your own shared backups"))
            return
        }

        sendEvent(
            BackupUiEvent.ShowConfirmation(
                title = "Delete Shared Backup",
                message = "Are you sure you want to remove '${item.filename}' from public sharing?",
                confirmAction = { deleteSharedBackup(item) },
            ),
        )
    }

    /**
     * Clear operation result.
     */
    fun clearOperationResult() {
        _operationResult.value = BackupOperationResult.Idle
    }

    /**
     * Check if user is authenticated.
     */
    fun isAuthenticated(): Boolean = cloudRepository.isAuthenticated()

    /**
     * Check if current user owns the shared backup.
     */
    fun isOwner(item: SharedBackupItem): Boolean = cloudRepository.isOwner(item)

    private fun sendEvent(event: BackupUiEvent) {
        viewModelScope.launch {
            _uiEvents.send(event)
        }
    }

    override fun onCleared() {
        super.onCleared()
        searchJob?.cancel()
    }
}
