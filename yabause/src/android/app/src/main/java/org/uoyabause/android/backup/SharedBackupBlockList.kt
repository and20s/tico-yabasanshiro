/*
 * Copyright 2026 devMiyax
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
package org.uoyabause.android.backup

import android.content.Context

/**
 * The posters this user has chosen not to see.
 *
 * Kept on the device rather than in Firestore: hiding someone is this
 * reader's preference, not a claim about them, and it must work signed out
 * and take effect immediately. Reporting is the separate action that tells
 * us about a save (see SharedBackupReport).
 *
 * The preference key matches the iOS client's, but the two stores are not
 * shared: a block made on one device is local to it, by design.
 */
class SharedBackupBlockList(
    context: Context,
) {
    companion object {
        private const val PREFS_NAME = "backup_share"
        private const val KEY_BLOCKED_OWNER_IDS = "blocked_owner_ids"
    }

    private val prefs = context.applicationContext
        .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    val blockedIds: Set<String>
        get() = prefs.getStringSet(KEY_BLOCKED_OWNER_IDS, emptySet()) ?: emptySet()

    val count: Int
        get() = blockedIds.size

    fun isBlocked(ownerId: String): Boolean = ownerId.isNotEmpty() && blockedIds.contains(ownerId)

    fun block(ownerId: String) {
        if (ownerId.isEmpty()) return
        // getStringSet returns an instance that must not be mutated, so copy.
        prefs
            .edit()
            .putStringSet(KEY_BLOCKED_OWNER_IDS, blockedIds + ownerId)
            .apply()
    }

    /**
     * Unblocks everyone at once, since the only way back is the "show all"
     * row: there is no per-person list to pick from, and building one would
     * mean showing the names of people the user asked not to see.
     */
    fun unblockAll() {
        prefs.edit().remove(KEY_BLOCKED_OWNER_IDS).apply()
    }
}
