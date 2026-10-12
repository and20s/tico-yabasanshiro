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
package org.uoyabause.android.backup.model

import com.google.firebase.firestore.DocumentSnapshot

/**
 * One page of shared backups plus the cursor needed to ask for the next.
 *
 * @property items the documents this page carried, already parsed.
 * @property cursor opaque cursor for the next call; null when the walk has
 *   reached the end of the collection.
 */
data class SharedBackupPage(
    val items: List<SharedBackupItem>,
    val cursor: DocumentSnapshot?,
) {
    val hasMore: Boolean
        get() = cursor != null

    companion object {
        val EMPTY = SharedBackupPage(emptyList(), null)
    }
}
