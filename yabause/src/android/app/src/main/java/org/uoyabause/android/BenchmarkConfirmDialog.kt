package org.uoyabause.android

import android.app.Activity
import android.content.DialogInterface
import android.widget.TextView
import com.google.android.material.checkbox.MaterialCheckBox
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import org.devmiyax.yabasanshiro.R

/**
 * The one place the benchmark is confirmed.
 *
 * Three screens can start a sweep, and the checkbox that decides whether its
 * result is shared has to be in front of the user on every one of them: a copy
 * of this dialog per caller is a copy that can be updated without the others,
 * which for a consent prompt means a path where the user was never told what is
 * sent.
 */
object BenchmarkConfirmDialog {
    fun show(
        activity: Activity,
        titleId: Int,
        messageId: Int,
        negativeId: Int,
        onRun: () -> Unit,
    ) {
        val view = activity.layoutInflater.inflate(R.layout.dialog_benchmark_confirm, null)
        view.findViewById<TextView>(R.id.benchmark_confirm_message).setText(messageId)
        val upload = view.findViewById<MaterialCheckBox>(R.id.benchmark_confirm_upload)
        upload.isChecked = BenchmarkReportUploader.hasConsent(activity)

        val dialog =
            MaterialAlertDialogBuilder(activity)
                .setTitle(titleId)
                .setView(view)
                .setPositiveButton(R.string.benchmark_confirm_run) { _, _ ->
                    BenchmarkReportUploader.setConsent(activity, upload.isChecked)
                    onRun()
                }.setNegativeButton(negativeId, null)
                .create()
        // Running the benchmark is not destructive, so the default D-pad focus
        // goes to the positive button.
        dialog.setOnShowListener {
            val button = dialog.getButton(DialogInterface.BUTTON_POSITIVE)
            button?.post {
                button.isFocusable = true
                button.isFocusableInTouchMode = true
                button.requestFocus()
            }
        }
        dialog.show()
    }
}
