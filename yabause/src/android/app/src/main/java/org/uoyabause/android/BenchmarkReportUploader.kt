package org.uoyabause.android

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.annotation.VisibleForTesting
import androidx.preference.PreferenceManager
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import java.io.File
import java.util.UUID

/**
 * Sends a completed benchmark sweep to the shared report collection.
 *
 * The report is parked in a file before anything touches the network, which is
 * what makes the send unable to cost the user their measurement: by the time
 * this is called the profile is already saved and the settings already applied,
 * and a send that fails - or an activity that is destroyed mid-send, which is
 * the normal case, since the benchmark finishes by closing itself - leaves the
 * file behind for the next launch to pick up.
 *
 * That retry matters more than it looks. The devices this benchmark exists for
 * are retro handhelds, which are often not on a network at all while they are
 * being measured. Firestore's own offline persistence does not cover them:
 * signing in anonymously needs the network, so with no session there is no
 * write to queue in the first place.
 */
object BenchmarkReportUploader {
    private const val TAG = "BenchmarkReportUploader"
    private const val PENDING_NAME = "benchmark_report_pending.json"
    private const val INSTALL_PREFS = "benchmark_prefs"
    private const val INSTALL_ID_KEY = "install_id"

    const val COLLECTION = "benchmark_reports"

    /**
     * The answer, written only by [setConsent] from the consent dialog.
     *
     * There is deliberately no second "has the user answered yet" flag. The
     * confirm dialog is shown before every run, so the checkbox is always in
     * front of the user and its current value is always the answer - nothing
     * needs to distinguish "not asked" from "asked and declined".
     */
    const val PREF_UPLOAD_OPT_IN = "pref_benchmark_upload"

    /**
     * What consent is before anyone has answered.
     *
     * True, because every path that can produce a report shows the checkbox
     * first - see BenchmarkConfirmDialog - so this default is only ever read for
     * a device that has no measurement to send.
     */
    const val DEFAULT_CONSENT = true

    /** The one thing that talks to Firestore, so the rest of this can be tested. */
    fun interface Writer {
        suspend fun write(
            documentId: String,
            fields: Map<String, Any?>,
        )
    }

    @VisibleForTesting
    @Volatile
    var writer: Writer = FirestoreWriter

    /** Restores the production writer. For tests. */
    fun resetWriter() {
        writer = FirestoreWriter
    }

    /**
     * Process-lifetime, not tied to the activity: the benchmark finishes by
     * closing itself, so a send started on the activity's scope would be
     * cancelled almost immediately.
     */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    fun hasConsent(context: Context): Boolean = defaultPrefs(context).getBoolean(PREF_UPLOAD_OPT_IN, DEFAULT_CONSENT)

    fun setConsent(
        context: Context,
        granted: Boolean,
    ) {
        defaultPrefs(context).edit().putBoolean(PREF_UPLOAD_OPT_IN, granted).apply()
    }

    /**
     * A random id for this installation, created on first use.
     *
     * Not the Android id, not the advertising id, and not tied to any account:
     * it exists only so that a device measuring itself twice counts once, and it
     * is gone on reinstall. That depends on [INSTALL_PREFS] being excluded from
     * Auto Backup and device-to-device transfer (res/xml/backup_rules.xml and
     * res/xml/data_extraction_rules.xml) - without that exclusion, Android would
     * restore this id (and the pending report file) onto a reinstall or a second
     * device, which is exactly what this id exists to prevent.
     */
    fun installId(context: Context): String {
        val prefs = installPrefs(context)
        prefs.getString(INSTALL_ID_KEY, null)?.let { return it }
        val created = UUID.randomUUID().toString()
        prefs.edit().putString(INSTALL_ID_KEY, created).apply()
        return created
    }

    /** Parks [report] for sending. Returns false when there is nothing to do. */
    fun enqueue(
        context: Context,
        report: BenchmarkReport,
    ): Boolean {
        if (!hasConsent(context)) {
            Log.i(TAG, "the benchmark report was not queued: the user did not opt in")
            return false
        }
        return try {
            pendingFile(context).writeText(report.toJson())
            true
        } catch (e: Exception) {
            Log.i(TAG, "the benchmark report could not be queued", e)
            false
        }
    }

    /** Sends the parked report if there is one. Returns true only when one was sent. */
    suspend fun flush(context: Context): Boolean {
        val file = pendingFile(context)
        if (!file.exists()) return false
        if (!hasConsent(context)) {
            // Consent can be withdrawn between measuring and the next launch.
            Log.i(TAG, "discarding the queued benchmark report: consent was withdrawn")
            file.delete()
            return false
        }
        val report = BenchmarkReport.fromJson(runCatching { file.readText() }.getOrNull())
        if (report == null) {
            // A truncated or half-written file would otherwise hold the slot for good.
            Log.i(TAG, "discarding the queued benchmark report: it could not be read back")
            file.delete()
            return false
        }
        return try {
            writer.write(report.documentId(), report.toFields())
            file.delete()
            Log.i(TAG, "benchmark report sent for ${report.gpuKey}")
            true
        } catch (e: Exception) {
            Log.i(TAG, "the benchmark report stays queued: it could not be sent", e)
            false
        }
    }

    /** Fire-and-forget [flush] on a scope that outlives the calling activity. */
    fun flushInBackground(context: Context) {
        val application = context.applicationContext
        scope.launch { flush(application) }
    }

    private fun defaultPrefs(context: Context): SharedPreferences = PreferenceManager.getDefaultSharedPreferences(context)

    private fun installPrefs(context: Context): SharedPreferences =
        context.getSharedPreferences(INSTALL_PREFS, Context.MODE_PRIVATE)

    private fun pendingFile(context: Context) = File(context.filesDir, PENDING_NAME)

    /**
     * Writes as whoever is already signed in, or as a throwaway anonymous user.
     *
     * The uid is never stored in the document - the session exists only to get
     * past the Firestore rules, and a report from a signed-in user must not be
     * distinguishable from anyone else's. The anonymous session is ended again
     * straight away, which is what the rest of the app assumes: FCM registration
     * and AuthState.realUser() both treat an anonymous session as signed out.
     */
    private object FirestoreWriter : Writer {
        override suspend fun write(
            documentId: String,
            fields: Map<String, Any?>,
        ) {
            val auth = FirebaseAuth.getInstance()
            val ephemeral = auth.currentUser == null
            if (ephemeral) auth.signInAnonymously().await()
            try {
                FirebaseFirestore
                    .getInstance()
                    .collection(COLLECTION)
                    .document(documentId)
                    .set(fields + ("createdAt" to FieldValue.serverTimestamp()))
                    .await()
            } finally {
                if (ephemeral) auth.signOut()
            }
        }
    }
}
