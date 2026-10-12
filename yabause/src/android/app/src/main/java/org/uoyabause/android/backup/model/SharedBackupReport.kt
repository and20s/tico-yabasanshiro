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

import androidx.annotation.StringRes
import org.devmiyax.yabasanshiro.R
import java.util.Date

/**
 * Why a shared backup was reported.
 *
 * A fixed list rather than free text: it needs no moderation of its own, it
 * is the same in every language, and it is what a reviewer can act on. The
 * raw values match the iOS client so both write the same documents.
 */
enum class SharedBackupReportReason(
    val rawValue: String,
    @StringRes val labelRes: Int,
) {
    INAPPROPRIATE("inappropriate", R.string.report_reason_inappropriate),
    SPAM("spam", R.string.report_reason_spam),
    OTHER("other", R.string.report_reason_other),
}

/**
 * One report, written to `shared_backup_reports/{autoId}`.
 *
 * The owner is copied in rather than looked up later: by the time anyone
 * reads the report the save may already be gone, and a report that cannot
 * say who posted it is not actionable.
 *
 * Reports are create-only from the client. A reporter must not be able to
 * read, edit or withdraw any report, including their own.
 */
data class SharedBackupReport(
    val backupId: String,
    val ownerId: String,
    val reporterId: String,
    val reason: SharedBackupReportReason,
) {
    fun toMap(createdAt: Date = Date()): Map<String, Any> = mapOf(
        "backupId" to backupId,
        "ownerId" to ownerId,
        "reporterId" to reporterId,
        "reason" to reason.rawValue,
        "createdAt" to createdAt,
    )
}
