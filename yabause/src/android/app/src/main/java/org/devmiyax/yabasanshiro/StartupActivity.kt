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
package org.devmiyax.yabasanshiro

import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.method.LinkMovementMethod
import android.util.Log
import android.view.View
import android.widget.Button
import android.widget.TextView
import androidx.activity.enableEdgeToEdge
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.preference.PreferenceManager
import androidx.window.layout.WindowMetricsCalculator
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.tasks.Task
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.remoteconfig.FirebaseRemoteConfig
import org.uoyabause.android.BenchmarkReportUploader
import org.uoyabause.android.DeviceCapabilities
import org.uoyabause.android.DeviceInfo
import org.uoyabause.android.FirstLaunchOffer
import org.uoyabause.android.GpuProfileStore
import org.uoyabause.android.RecommendedSettings
import org.uoyabause.android.RecommendedSettingsApplier
import org.uoyabause.android.phone.GameSelectActivityPhone

class StartupActivity : AppCompatActivity() {
    val tag = "StartupActivity"

    private var mFirebaseRemoteConfig: FirebaseRemoteConfig? = null

    /** Completes once Remote Config has been fetched and activated, or has failed to. */
    private var remoteConfigReady: Task<Boolean>? = null
    private var remoteConfigStartedAt = 0L

    // Set in onCreate on the first launch. Nothing is offered on this screen: it
    // carries the terms of service and the privacy policy, and asking about
    // settings or a minutes-long measurement in front of them asks the user to
    // accept those before they have accepted anything. The offer is decided when
    // this screen is left and handed to the game list - see
    // GameSelectActivityPhone.
    private var firstLaunchCaps: DeviceCapabilities? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Enable edge-to-edge display for Android 15+ (API 35+)
        enableEdgeToEdge()

        setContentView(R.layout.activity_startup)

        // Setup edge-to-edge window insets handling
        setupEdgeToEdgeInsets()

        // First thing, so the fetch runs while the user reads the terms (or while
        // the splash is up) instead of after them: on a first launch the GPU
        // profile database from Remote Config is what decides the offer.
        startRemoteConfigFetch()

        val sharedPref = PreferenceManager.getDefaultSharedPreferences(this)

        val video = sharedPref.getString("pref_video", "-1")
        if (video == "-1") {
            val caps = DeviceCapabilities.forContext(this)
            // The safe side, without asking: the app needs settings before
            // anything else, and whether this GPU has a recommendation can only
            // be answered once Remote Config has arrived.
            RecommendedSettingsApplier.apply(sharedPref, RecommendedSettings.forDevice(caps, null))
            Log.d(tag, "safe-side settings applied on first launch (gpu=${caps.gpuKey})")
            firstLaunchCaps = caps
        }

        val aspectRateSetting = sharedPref.getString("pref_aspect_rate", "BAD")
        if (aspectRateSetting == "BAD") {
            val editor = sharedPref.edit()
            val windowMetrics = WindowMetricsCalculator.getOrCreate().computeCurrentWindowMetrics(this)
            val currentBounds = windowMetrics.bounds
            val width = currentBounds.width()
            val height = currentBounds.height()
            val arate = width.toDouble() / height.toDouble()
            if (arate >= 1.21 && arate <= 1.34) {
                editor.putString("pref_aspect_rate", "3")
            } else {
                editor.putString("pref_aspect_rate", "0")
            }
            editor.apply()
        }

        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        val googleAPI = GoogleApiAvailability.getInstance()
        val resultCode = googleAPI.isGooglePlayServicesAvailable(this)
        if (resultCode != ConnectionResult.SUCCESS) {
            Log.e(tag, "This device is not supported.")
        }
        // Log.d(tag, "InstanceID token: " + FirebaseInstanceId.getInstance().token)
        val auth = FirebaseAuth.getInstance()
        if (auth.currentUser != null) {
            // already signed in
        } else {
            // not signed in
        }

        val r = Runnable { whenFirstLaunchProfilesReady { startGameList() } }

        val prefs = getSharedPreferences("private", Context.MODE_PRIVATE)
        val agreed = prefs.getBoolean("agreed", false)

        val v = findViewById<View>(R.id.agree)
        if (agreed) {
            v.visibility = View.GONE
            Handler(Looper.getMainLooper()).postDelayed(r, 2000)
        } else {
            val t2 = findViewById<TextView>(R.id.agree_text)
            t2.movementMethod = LinkMovementMethod.getInstance()

            val b = findViewById<Button>(R.id.agree_and_start)
            b.requestFocus()
            b.setOnClickListener {
                prefs.edit().apply {
                    putBoolean("agreed", true)
                    commit()
                }
                v.visibility = View.GONE
                Handler(Looper.getMainLooper()).postDelayed(r, 1)
            }
            v.visibility = View.VISIBLE
        }
    }

    private fun startRemoteConfigFetch() {
        val config = FirebaseRemoteConfig.getInstance()
        mFirebaseRemoteConfig = config
        remoteConfigStartedAt = SystemClock.elapsedRealtime()
        val cacheExpiration: Long = 3600 // 1 hour in seconds.
        remoteConfigReady =
            config
                .setDefaultsAsync(R.xml.config)
                .continueWithTask { config.fetch(cacheExpiration) }
                .onSuccessTask { config.activate() }
    }

    /**
     * Runs [block] once the first launch can see Remote Config, without holding
     * the user up for long.
     *
     * Only a first launch waits - it is the one whose offer depends on the
     * profile database. The fetch started in onCreate, so by the time the terms
     * are accepted or the splash is over it has usually finished and nothing is
     * waited for at all. When it has not, the wait is capped at
     * [PROFILE_WAIT_MS] from the start of the fetch; past that the decision is
     * made from the bundled database, which a slow or absent network would give
     * anyway.
     */
    private fun whenFirstLaunchProfilesReady(block: () -> Unit) {
        val ready = remoteConfigReady
        val remaining = PROFILE_WAIT_MS - (SystemClock.elapsedRealtime() - remoteConfigStartedAt)
        if (firstLaunchCaps == null || ready == null || ready.isComplete || remaining <= 0) {
            block()
            return
        }
        var ran = false
        val runOnce = {
            if (!ran && !isFinishing && !isDestroyed) {
                ran = true
                block()
            }
        }
        val handler = Handler(Looper.getMainLooper())
        handler.postDelayed({ runOnce() }, remaining)
        ready.addOnCompleteListener(this) {
            handler.removeCallbacksAndMessages(null)
            runOnce()
        }
    }

    private fun startGameList() {
        // A benchmark measured without a network leaves its report
        // parked on disk; this is the only thing that ever picks it up.
        BenchmarkReportUploader.flushInBackground(this@StartupActivity)

        val i = Intent(this@StartupActivity, GameSelectActivityPhone::class.java)
        Log.d(tag, "executing: GameSelectActivityPhone")

        val sargs = intent.dataString
        if (sargs != null) {
            Log.d(tag, "getDataString = $sargs")
            if (sargs.contains("//login")) {
                i.putExtra("showPin", true)
            }
        }
        val args = intent.data
        if (args != null && !args.pathSegments.isEmpty()) {
            Log.d(tag, "getData = $args")
            i.data = args
        }

        val caps = firstLaunchCaps
        // Only ever handed over once per launch.
        firstLaunchCaps = null
        if (caps != null) {
            val gpuKey = caps.gpuKey
            val offer = FirstLaunchOffer.decide(caps, GpuProfileStore.find(this, gpuKey))
            Log.d(tag, "first launch offer: $offer (gpu=$gpuKey)")
            if (offer != FirstLaunchOffer.NONE && gpuKey != null) {
                i.putExtra(GameSelectActivityPhone.EXTRA_FIRST_LAUNCH_OFFER, offer.name)
                i.putExtra(GameSelectActivityPhone.EXTRA_BENCHMARK_GPU_KEY, gpuKey)
                i.putExtra(
                    GameSelectActivityPhone.EXTRA_BENCHMARK_GPU_NAME,
                    DeviceInfo.gpuRenderer().ifBlank { gpuKey },
                )
            }
        }
        startActivity(i)
    }

    /**
     * Setup edge-to-edge window insets handling for Android 15+ (API 35+)
     */
    private fun setupEdgeToEdgeInsets() {
        val rootView = findViewById<androidx.coordinatorlayout.widget.CoordinatorLayout>(R.id.coordinator_layout)
        ViewCompat.setOnApplyWindowInsetsListener(rootView) { view, windowInsets ->
            val insets = windowInsets.getInsets(WindowInsetsCompat.Type.systemBars())

            // Apply padding to avoid status bar overlap
            view.setPadding(
                view.paddingLeft,
                insets.top,
                view.paddingRight,
                view.paddingBottom,
            )

            // Update agree LinearLayout to avoid navigation bar overlap
            val agreeLayout = findViewById<android.widget.LinearLayout>(R.id.agree)
            agreeLayout?.let { layout ->
                val layoutParams = layout.layoutParams as androidx.coordinatorlayout.widget.CoordinatorLayout.LayoutParams
                val originalMarginDp = 32
                val originalMarginPx = (originalMarginDp * resources.displayMetrics.density).toInt()
                layoutParams.bottomMargin = originalMarginPx + insets.bottom
                layout.layoutParams = layoutParams
            }

            windowInsets
        }
    }

    companion object {
        /**
         * The longest a first launch waits for Remote Config, counted from the
         * start of the fetch. Provisional; long enough for a fetch on a working
         * network, short enough that a user tapping through the terms at once
         * barely notices.
         */
        private const val PROFILE_WAIT_MS = 3000L
    }
}
