/*  Copyright 2019 devMiyax(smiyaxdev@gmail.com)

    This file is part of YabaSanshiro.

    YabaSanshiro is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    YabaSanshiro is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with YabaSanshiro; if not, write to the Free Software
    Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA
*/
package org.uoyabause.android.phone

import android.Manifest
import android.app.UiModeManager
import android.content.DialogInterface
import android.content.Intent
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.view.KeyEvent
import android.view.MenuItem
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver.OnGlobalLayoutListener
import android.widget.FrameLayout
import android.widget.LinearLayout
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.lifecycle.lifecycleScope
import androidx.preference.PreferenceManager
import com.google.android.gms.ads.AdListener
import com.google.android.gms.ads.AdRequest
import com.google.android.gms.ads.AdSize
import com.google.android.gms.ads.AdView
import com.google.android.gms.ads.MobileAds
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.devmiyax.yabasanshiro.R
import org.uoyabause.android.BenchmarkActivity
import org.uoyabause.android.BenchmarkConfirmDialog
import org.uoyabause.android.DeviceCapabilities
import org.uoyabause.android.FCMTokenManager
import org.uoyabause.android.FirstLaunchOffer
import org.uoyabause.android.GpuProfileStore
import org.uoyabause.android.Notification
import org.uoyabause.android.RecommendedSettings
import org.uoyabause.android.RecommendedSettingsApplier
import org.uoyabause.android.RecommendedSettingsLabels
import org.uoyabause.android.ReportListActivity
import org.uoyabause.android.YabauseApplication
import org.uoyabause.android.YabauseStorage
import org.uoyabause.android.tv.Subscription
import org.uoyabause.android.tv.TvUtil
import java.net.URLDecoder

class GameSelectActivityPhone : AppCompatActivity() {
    lateinit var frg: GameSelectFragmentPhone2
    var adView: AdView? = null

    private val requestPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { isGranted: Boolean ->
            if (isGranted) {
                // 許可された場合、FCMトークンを登録
                lifecycleScope.launch {
                    FCMTokenManager(applicationContext).registerFcmToken()
                }
            } else {
                // 拒否された場合の処理
                android.util.Log.d("GameSelectActivityPhone", "Notification permission denied")
            }
        }

    private fun showInContextUI() {
        // 許可の必要性を説明するダイアログなどを表示
        val dialog = MaterialAlertDialogBuilder(this)
            .setTitle(getString(R.string.notification_permission_title))
            .setMessage(getString(R.string.notification_permission_message))
            .setPositiveButton(R.string.ok) { _, _ ->
                requestPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            }.setNegativeButton(R.string.cancel, null)
            .create()
        dialog.setOnShowListener {
            val positiveButton = dialog.getButton(android.content.DialogInterface.BUTTON_POSITIVE)
            positiveButton?.post {
                positiveButton.isFocusable = true
                positiveButton.isFocusableInTouchMode = true
                positiveButton.requestFocus()
            }
        }
        dialog.show()
    }

    /** True once the benchmark has been offered this launch; see [offerBenchmark]. */
    private var benchmarkOffered = false

    private val benchmarkLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
            // Nothing to do with the result: BenchmarkActivity saves the profile
            // and applies the settings itself, precisely because the screen that
            // launched it is not guaranteed to survive a multi-minute sweep.
        }

    /**
     * Makes the first-launch offer StartupActivity decided on, once, on the
     * screen after the startup one.
     *
     * StartupActivity is where the terms of service and the privacy policy are
     * presented, so it is the wrong place to ask about settings or a measurement
     * - the offer is handed here instead. Declining either is a normal outcome:
     * the safe-side settings StartupActivity already wrote stay in effect.
     */
    private fun makeFirstLaunchOffer(offer: FirstLaunchOffer) {
        if (benchmarkOffered) return
        val gpuKey = intent.getStringExtra(EXTRA_BENCHMARK_GPU_KEY)
        if (gpuKey == null) {
            Log.d(TAG, "first launch offer skipped: no gpu key in the intent")
            return
        }
        // Asked once per launch. The flag is what actually enforces that - the
        // intent's extras come back on a recreation, so clearing them is not
        // enough on its own.
        benchmarkOffered = true
        intent.removeExtra(EXTRA_FIRST_LAUNCH_OFFER)
        when (offer) {
            FirstLaunchOffer.RECOMMENDED_SETTINGS -> offerRecommendedSettings(gpuKey)
            FirstLaunchOffer.BENCHMARK -> offerBenchmark(gpuKey)
            FirstLaunchOffer.NONE -> Unit
        }
    }

    /**
     * Asks whether to apply the settings the profile database recommends for this
     * GPU. Lists every recommended setting, the same way the benchmark result
     * does, so the answer is an informed one. The settings screen's note about
     * games with their own saved settings is left out: this is the first launch,
     * so no game has any yet.
     */
    private fun offerRecommendedSettings(gpuKey: String) {
        val caps = DeviceCapabilities.forContext(this)
        val profile = GpuProfileStore.find(this, gpuKey)
        if (profile == null) {
            // StartupActivity saw a profile a moment ago, so this should not
            // happen; if it does, measuring is the way to get one.
            offerBenchmark(gpuKey)
            return
        }
        val recommended = RecommendedSettings.forDevice(caps, profile)
        val prefs = PreferenceManager.getDefaultSharedPreferences(this)
        val changes = RecommendedSettingsApplier.diff(prefs, recommended)
        Log.d(TAG, "offering recommended settings for $gpuKey (${changes.size} changes)")
        if (changes.isEmpty()) return

        val message =
            getString(R.string.recommended_settings_offer_message) + "\n\n" +
                RecommendedSettingsApplier
                    .values(recommended)
                    .joinToString("\n") { RecommendedSettingsLabels.describe(this, it) }
        val dialog =
            MaterialAlertDialogBuilder(this)
                .setTitle(R.string.apply_recommended_settings)
                .setMessage(message)
                .setPositiveButton(R.string.recommended_settings_apply) { _, _ ->
                    RecommendedSettingsApplier.apply(prefs, recommended)
                }.setNegativeButton(android.R.string.cancel, null)
                .create()
        // Applying settings is a data change, so default D-pad focus goes to Cancel.
        dialog.setOnShowListener {
            val button = dialog.getButton(DialogInterface.BUTTON_NEGATIVE)
            button?.post {
                button.isFocusable = true
                button.isFocusableInTouchMode = true
                button.requestFocus()
            }
        }
        dialog.show()
    }

    /** Offers the GPU benchmark for a GPU the profile database does not know. */
    private fun offerBenchmark(gpuKey: String) {
        val gpuName = intent.getStringExtra(EXTRA_BENCHMARK_GPU_NAME).orEmpty().ifBlank { gpuKey }
        Log.d(TAG, "offering the benchmark for $gpuKey")

        BenchmarkConfirmDialog.show(
            activity = this,
            titleId = R.string.benchmark_confirm_title,
            messageId = R.string.benchmark_confirm_message,
            negativeId = R.string.benchmark_confirm_skip,
        ) {
            benchmarkLauncher.launch(BenchmarkActivity.intent(this, gpuKey, gpuName))
        }
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(STATE_BENCHMARK_OFFERED, benchmarkOffered)
    }

    public override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // ステータスバーをダークモードに設定
        WindowCompat.getInsetsController(window, window.decorView)?.apply {
            isAppearanceLightStatusBars = false // ダークモード: 白いアイコン
        }

        val frame = FrameLayout(this)
        frame.id = CONTENT_VIEW_ID
        setContentView(
            frame,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )

        // Setup edge-to-edge window insets handling
        setupEdgeToEdgeInsets(frame)
        if (savedInstanceState == null) {
            frg = GameSelectFragmentPhone2()

            val ft = supportFragmentManager.beginTransaction()
            ft.add(CONTENT_VIEW_ID, frg).commit()
        } else {
            frg =
                supportFragmentManager.findFragmentById(CONTENT_VIEW_ID) as GameSelectFragmentPhone2
        }

        benchmarkOffered = savedInstanceState?.getBoolean(STATE_BENCHMARK_OFFERED, false) ?: false
        Log.d(
            TAG,
            "first launch offer: extra=${intent.getStringExtra(EXTRA_FIRST_LAUNCH_OFFER)} " +
                "alreadyOffered=$benchmarkOffered gpuKey=${intent.getStringExtra(EXTRA_BENCHMARK_GPU_KEY)}",
        )
        val firstLaunchOffer =
            intent.getStringExtra(EXTRA_FIRST_LAUNCH_OFFER)?.let { name ->
                FirstLaunchOffer.entries.firstOrNull { it.name == name }
            }
        if (!benchmarkOffered && firstLaunchOffer != null && firstLaunchOffer != FirstLaunchOffer.NONE) {
            // Posted rather than shown inline so the game list is actually on
            // screen behind the dialog.
            frame.post { makeFirstLaunchOffer(firstLaunchOffer) }
        }

        // Register back press callback for predictive back gesture support
        onBackPressedDispatcher.addCallback(
            this,
            object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    if (supportFragmentManager.backStackEntryCount > 0) {
                        supportFragmentManager.popBackStack()
                    } else if (::frg.isInitialized) {
                        // ext_fragment にフラグメントがあれば Games 画面に戻る
                        val extFragment = supportFragmentManager.findFragmentById(R.id.ext_fragment)
                        if (extFragment != null) {
                            frg.navigateToGames()
                        } else {
                            // Games 画面で戻る → 終了確認ダイアログ
                            val dialog = MaterialAlertDialogBuilder(this@GameSelectActivityPhone)
                                .setTitle(R.string.exit)
                                .setMessage(R.string.confirm_exit)
                                .setPositiveButton(R.string.exit) { _, _ ->
                                    finish()
                                }.setNegativeButton(R.string.cancel, null)
                                .create()
                            dialog.setOnShowListener {
                                val positiveButton = dialog.getButton(android.content.DialogInterface.BUTTON_POSITIVE)
                                positiveButton?.post {
                                    positiveButton.isFocusable = true
                                    positiveButton.isFocusableInTouchMode = true // タッチ操作以外のフォーカスを許可
                                    positiveButton.requestFocus()
                                }
                            }
                            dialog.show()
                        }
                    }
                }
            },
        )

        // ext_fragmentにフラグメントが表示されている間、CoordinatorLayoutを非表示にして
        // D-padフォーカスが裏のGameSelectFragmentPhoneのビューに漏れるのを防ぐ
        supportFragmentManager.addOnBackStackChangedListener {
            val coordinatorLayout = frg.view?.findViewById<View>(R.id.coordinator)
            if (supportFragmentManager.backStackEntryCount > 0) {
                coordinatorLayout?.visibility = View.GONE
            } else {
                coordinatorLayout?.visibility = View.VISIBLE
            }
        }

        // Admin権限がある場合のみ通知権限をリクエスト（Android 13+）
        lifecycleScope.launch {
            val fcmTokenManager = FCMTokenManager(applicationContext)
            if (fcmTokenManager.shouldRequestNotificationPermission()) {
                // Admin権限があり、通知権限が必要な場合のみリクエスト
                when {
                    ActivityCompat.shouldShowRequestPermissionRationale(
                        this@GameSelectActivityPhone,
                        Manifest.permission.POST_NOTIFICATIONS,
                    ) -> {
                        // 許可が必要であることを説明するUIを表示
                        showInContextUI()
                    }
                    else -> {
                        // 許可をリクエストする
                        requestPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                    }
                }
            }
        }

        if (!YabauseApplication.isPro()) {
            try {
                MobileAds.initialize(this)
                adView = AdView(this)
                adView!!.adUnitId = this.getString(R.string.banner_ad_unit_id)
                adView!!.setAdSize(AdSize.BANNER)
                val adRequest = AdRequest.Builder().build()

                val params =
                    FrameLayout.LayoutParams(
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                        LinearLayout.LayoutParams.WRAP_CONTENT,
                    )
                params.gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
                frame.addView(adView, params)
                adView!!.isFocusable = false
                adView!!.isFocusableInTouchMode = false
                adView!!.descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
                adView!!.bringToFront()
                adView!!.invalidate()
                ViewCompat.setTranslationZ(adView!!, 90f)
                adView!!.loadAd(adRequest)

                adView!!.adListener =
                    object : AdListener() {
                        override fun onAdLoaded() {
                            // mAdView.getHeight() returns 0 since the ad UI didn't load
                            adView!!.viewTreeObserver.addOnGlobalLayoutListener(
                                object :
                                    OnGlobalLayoutListener {
                                    override fun onGlobalLayout() {
                                        adView!!.viewTreeObserver.removeOnGlobalLayoutListener(this)
                                        frg.onAdViewIsShown(adView!!.getHeight())
                                    }
                                },
                            )
                        }
                    }
            } catch (e: Exception) {
            }
        }

        // TV home screen channel sync
        syncTvChannels()

        // Handle deep link from Android TV RECENT channel
        handleDeepLink(savedInstanceState)

        // Check if this activity was started from a notification to open ReportListActivity
        handleNotificationIntent()
    }

    /**
     * Handle intent from notification to open ReportListActivity
     * Supports two launch modes:
     * 1. Foreground: Intent with extras (onMessageReceived)
     * 2. Background/Killed: Intent with action (FCM automatic notification)
     */
    private fun handleNotificationIntent() {
        // Check if started from foreground notification (Intent extras)
        val hasExtras = intent.getBooleanExtra(Notification.EXTRA_OPEN_REPORT_LIST, false)

        // Check if started from background/killed notification (Intent action)
        val hasAction = intent.action == "OPEN_REPORT_LIST"

        if (!hasExtras && !hasAction) {
            return
        }

        android.util.Log.d("GameSelectActivityPhone", "Notification intent detected: hasExtras=$hasExtras, hasAction=$hasAction")

        // Extract notification data
        // Foreground: Direct extras (EXTRA_PRODUCT_NUMBER)
        // Background: FCM data payload with "gcm.notification." prefix or direct data keys
        val productNumber =
            intent.getStringExtra(Notification.EXTRA_PRODUCT_NUMBER)
                ?: intent.getStringExtra("product_number")
                ?: intent.getStringExtra("gcm.notification.product_number")

        val gameId =
            intent.getStringExtra(Notification.EXTRA_GAME_ID)
                ?: intent.getStringExtra("game_id")
                ?: intent.getStringExtra("gcm.notification.game_id")

        val gameTitle =
            intent.getStringExtra(Notification.EXTRA_GAME_TITLE)
                ?: intent.getStringExtra("title")
                ?: intent.getStringExtra("gcm.notification.title")

        android.util.Log.d("GameSelectActivityPhone", "Extracted data: productNumber=$productNumber, gameTitle=$gameTitle")

        if (productNumber.isNullOrEmpty()) {
            android.util.Log.e("GameSelectActivityPhone", "Product number is missing from notification intent")
            return
        }

        // Find game info from database using product_number
        lifecycleScope.launch {
            try {
                val gameInfo =
                    withContext(Dispatchers.IO) {
                        // Try to find game by product_number
                        // Note: device_infomation might vary, so we'll get all games and find the first match
                        YabauseStorage.dao.getAll().firstOrNull { it.product_number == productNumber }
                    }

                if (gameInfo != null) {
                    android.util.Log.d("GameSelectActivityPhone", "Found game: ${gameInfo.game_title} (${gameInfo.product_number})")

                    // Open ReportListActivity with the found game info
                    val reportIntent =
                        Intent(this@GameSelectActivityPhone, ReportListActivity::class.java).apply {
                            putExtra(ReportListActivity.EXTRA_PRODUCT_NUMBER, productNumber)
                            putExtra(ReportListActivity.EXTRA_GAME_TITLE, gameInfo.game_title)
                            putExtra(ReportListActivity.EXTRA_FILE_PATH, gameInfo.file_path)
                            putExtra(ReportListActivity.EXTRA_ISO_FILE_PATH, gameInfo.iso_file_path)
                        }
                    startActivity(reportIntent)
                } else {
                    android.util.Log.w("GameSelectActivityPhone", "Game not found in local database: $productNumber")
                    // Even if game is not found locally, we can still open ReportListActivity without file paths
                    // The user won't be able to start the game from reports, but can still view reports
                    val reportIntent =
                        Intent(this@GameSelectActivityPhone, ReportListActivity::class.java).apply {
                            putExtra(ReportListActivity.EXTRA_PRODUCT_NUMBER, productNumber)
                            putExtra(ReportListActivity.EXTRA_GAME_TITLE, gameTitle ?: "Unknown Game")
                            putExtra(ReportListActivity.EXTRA_FILE_PATH, "")
                            putExtra(ReportListActivity.EXTRA_ISO_FILE_PATH, "")
                        }
                    startActivity(reportIntent)
                }
            } catch (e: Exception) {
                android.util.Log.e("GameSelectActivityPhone", "Error opening ReportListActivity from notification", e)
            }
        }
    }

    /**
     * Sync TV home screen channels if running on Android TV.
     */
    private fun syncTvChannels() {
        val uiModeManager = getSystemService(UI_MODE_SERVICE) as UiModeManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            uiModeManager.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
        ) {
            Thread {
                val subscription =
                    Subscription.createSubscription(
                        "RECENT",
                        "recent played games",
                        "saturngame://yabasanshiro/",
                        R.mipmap.ic_launcher,
                    )
                val channelId = TvUtil.createChannel(this@GameSelectActivityPhone, subscription)
                TvUtil.syncPrograms(this@GameSelectActivityPhone, channelId)
            }.start()
        }
    }

    /**
     * Handle deep link from Android TV RECENT channel.
     * URI format: saturngame://yabasanshiro/play/<encoded_file_path>
     *
     * @param savedInstanceState non-null if this is a recreation after process death;
     *        in that case the deep link was already handled in the previous instance.
     */
    private fun handleDeepLink(savedInstanceState: Bundle?) {
        // Skip if this is a recreation (e.g. after killProcess in Yabause);
        // the deep link was already handled in the original onCreate.
        if (savedInstanceState != null) {
            Log.d(TAG, "Skipping deep link: activity recreated from saved state")
            return
        }

        val uri = intent?.data ?: return

        val backupId = org.uoyabause.android.backup.BackupShareLink
            .parseId(uri.toString())
        if (backupId != null) {
            Log.d(TAG, "Deep link backup import: $backupId")
            org.uoyabause.android.backup.ui.SharedBackupImportSheet
                .newInstance(backupId)
                .show(supportFragmentManager, "shared_backup_import")
            return
        }

        val pathSegments = uri.pathSegments
        if (pathSegments.size < 2) return

        val action = pathSegments[0]
        if (action != TvUtil.PLAY) return

        try {
            val filename = URLDecoder.decode(pathSegments[1], "UTF-8")
            Log.d(TAG, "Deep link game: $filename")
            lifecycleScope.launch(Dispatchers.IO) {
                val game = YabauseStorage.dao.findByFilePath(filename)
                if (game != null) {
                    withContext(Dispatchers.Main) {
                        frg.launchGameFromDeepLink(game)
                    }
                } else {
                    Log.w(TAG, "Game not found in database: $filename")
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to handle deep link", e)
        }
    }

    override fun onStop() {
        super.onStop()
        syncTvChannels()
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        frg.onConfigurationChanged(newConfig)
    }

    @Deprecated("Deprecated in Java")
    @Suppress("DEPRECATION")
    override fun onOptionsItemSelected(item: MenuItem): Boolean { // Pass the event to ActionBarDrawerToggle, if it returns
        val rtn = frg.onOptionsItemSelected(item)
        if (rtn == true) {
            return true
        }
        return super.onOptionsItemSelected(item)
    }

    /**
     * ext_fragment に子フラグメントが表示中かどうかを返す。
     * Backup Manager / Settings / Account Manager はバックスタックに積まずに
     * ext_fragment に replace されるため、backStackEntryCount では判定できない。
     */
    private fun isExtFragmentActive(): Boolean = supportFragmentManager.findFragmentById(R.id.ext_fragment) != null

    override fun onKeyDown(
        keyCode: Int,
        event: KeyEvent?,
    ): Boolean {
        val repeatCount = event?.repeatCount ?: 0
        android.util.Log.d("GameSelectActivity", "Activity onKeyDown: keyCode=$keyCode, repeatCount=$repeatCount")

        // バックスタックまたは ext_fragment にフラグメントがある場合はそちらに任せる
        if (supportFragmentManager.backStackEntryCount > 0 || isExtFragmentActive()) {
            return super.onKeyDown(keyCode, event)
        }

        // D-pad navigation events をFragmentに委譲 (UP/DOWNはネイティブフォーカスに任せる)
        if (keyCode == KeyEvent.KEYCODE_DPAD_LEFT ||
            keyCode == KeyEvent.KEYCODE_DPAD_RIGHT ||
            keyCode == KeyEvent.KEYCODE_DPAD_CENTER ||
            keyCode == KeyEvent.KEYCODE_ENTER
        ) {
            if (::frg.isInitialized && frg.onKeyDown(keyCode, event)) {
                android.util.Log.d("GameSelectActivity", "Key event handled by fragment")
                return true
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyMultiple(
        keyCode: Int,
        repeatCount: Int,
        event: KeyEvent?,
    ): Boolean {
        android.util.Log.d("GameSelectActivity", "Activity onKeyMultiple: keyCode=$keyCode, repeatCount=$repeatCount")

        // バックスタックまたは ext_fragment にフラグメントがある場合はそちらに任せる
        if (supportFragmentManager.backStackEntryCount > 0 || isExtFragmentActive()) {
            return super.onKeyMultiple(keyCode, repeatCount, event)
        }

        // D-pad navigation events をFragmentに委譲 (UP/DOWNはネイティブフォーカスに任せる)
        if (keyCode == KeyEvent.KEYCODE_DPAD_LEFT ||
            keyCode == KeyEvent.KEYCODE_DPAD_RIGHT ||
            keyCode == KeyEvent.KEYCODE_DPAD_CENTER ||
            keyCode == KeyEvent.KEYCODE_ENTER
        ) {
            if (::frg.isInitialized && frg.onKeyMultiple(keyCode, repeatCount, event)) {
                android.util.Log.d("GameSelectActivity", "Key multiple event handled by fragment")
                return true
            }
        }
        return super.onKeyMultiple(keyCode, repeatCount, event)
    }

    fun removeAdView() {
        adView?.let { ad ->
            (ad.parent as? android.view.ViewGroup)?.removeView(ad)
            ad.destroy()
        }
        adView = null
    }

    fun showAdViewIfNeeded() {
        if (adView != null) return
        if (YabauseApplication.isPro()) return

        try {
            val frame = findViewById<FrameLayout>(CONTENT_VIEW_ID) ?: return
            MobileAds.initialize(this)
            adView = AdView(this)
            adView!!.adUnitId = getString(R.string.banner_ad_unit_id)
            adView!!.setAdSize(AdSize.BANNER)
            val adRequest = AdRequest.Builder().build()

            val params = FrameLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            )
            params.gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
            frame.addView(adView, params)
            adView!!.isFocusable = false
            adView!!.isFocusableInTouchMode = false
            adView!!.descendantFocusability = ViewGroup.FOCUS_BLOCK_DESCENDANTS
            adView!!.bringToFront()
            adView!!.invalidate()
            ViewCompat.setTranslationZ(adView!!, 90f)
            adView!!.loadAd(adRequest)

            adView!!.adListener = object : AdListener() {
                override fun onAdLoaded() {
                    adView!!.viewTreeObserver.addOnGlobalLayoutListener(
                        object : OnGlobalLayoutListener {
                            override fun onGlobalLayout() {
                                adView!!.viewTreeObserver.removeOnGlobalLayoutListener(this)
                                frg.onAdViewIsShown(adView!!.height)
                            }
                        },
                    )
                }
            }
        } catch (_: Exception) {
        }
    }

    override fun onPause() {
        super.onPause()
        adView?.pause()
    }

    override fun onResume() {
        super.onResume()
        adView?.resume()
        // Update TV home screen channel with latest recently played games
        syncTvChannels()
    }

    override fun onDestroy() {
        super.onDestroy()
        adView?.destroy()
    }

    /**
     * Setup edge-to-edge window insets handling for Android 15+ (API 35+)
     */
    private fun setupEdgeToEdgeInsets(rootView: FrameLayout) {
        ViewCompat.setOnApplyWindowInsetsListener(rootView) { view, windowInsets ->
            val insets = windowInsets.getInsets(WindowInsetsCompat.Type.systemBars())

            // Apply top padding to avoid status bar overlap
            view.setPadding(
                view.paddingLeft,
                insets.top,
                view.paddingRight,
                view.paddingBottom,
            )

            // Return the insets unchanged for other views
            windowInsets
        }
    }

    companion object {
        private const val TAG = "GameSelectActivityPhone"
        const val CONTENT_VIEW_ID = 10101010

        /**
         * Set by StartupActivity on a first launch: the name of the
         * [FirstLaunchOffer] this screen should make.
         */
        const val EXTRA_FIRST_LAUNCH_OFFER = "org.uoyabause.android.FirstLaunchOffer"
        const val EXTRA_BENCHMARK_GPU_KEY = "org.uoyabause.android.OfferBenchmarkGpuKey"
        const val EXTRA_BENCHMARK_GPU_NAME = "org.uoyabause.android.OfferBenchmarkGpuName"
        private const val STATE_BENCHMARK_OFFERED = "benchmarkOffered"
    }
}
