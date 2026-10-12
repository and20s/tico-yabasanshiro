import UIKit
import SwiftUI
import FirebaseCore
import FirebaseMessaging
import FirebaseInAppMessaging
import GoogleSignIn
#if FREE_VERSION
import GoogleMobileAds
#endif
import FirebaseAuth
import UserNotifications

@UIApplicationMain  
class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate {

    var window: UIWindow?
    private let discordRedirectHandler = DiscordOAuthRedirectHandler()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // Appearance proxies are global, so they must be installed before the
        // first view controller is created.
        setupAppearance()

        var filePath: String?

        //#if DEBUG
        //filePath = Bundle.main.path(forResource: "GoogleService-Info-Debug", ofType: "plist")
        //#else
        filePath = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist")
        //#endif

        if let filePath = filePath, let options = FirebaseOptions(contentsOfFile: filePath) {
            FirebaseApp.configure(options: options)
        } else {
            fatalError("Couldn't find correct GoogleService-Info.plist file.")
        }

        // Initialize the Google Mobile Ads SDK.FirebaseCoreDiagnostics
#if FREE_VERSION
        GADMobileAds.sharedInstance().start(completionHandler: nil)
#endif
        
        // Configure Firebase Messaging
        configureFirebaseMessaging()
        
        // Auto-login to RetroAchievements on app startup
        RetroAchievementsAuthManager.shared.attemptAutoLogin { success, error in
            if success {
                NSLog("RetroAchievements: Auto-login successful on app startup")
            } else {
                NSLog("RetroAchievements: Auto-login failed on app startup: \(error ?? "Unknown error")")
            }
        }

        // SP1: the legacy home screen is gone, so Main.storyboard no longer
        // has an initial view controller and the window is created here.
        // Main.storyboard is still used to instantiate the emulator screen
        // (GameMainViewController) via GameLauncher.
        // Legacy cart/invalid.ram cleanup (see CartridgeFileMigration).
        CartridgeFileMigration().run()

        window = UIWindow(frame: UIScreen.main.bounds)
        applyWindowAppearance()
        window?.rootViewController = UIHostingController(rootView: MainTabView())
        window?.makeKeyAndVisible()

        // Begins the StoreKit work once, at launch: the transaction listener,
        // the product request, and the first read of both entitlement sources.
        ProEntitlementStore.shared.start()

        return true
    }

    // Window level appearance. Must run after the window exists.
    private func applyWindowAppearance() {
        window?.tintColor = .themePrimary
        // The Material 3 theme ported from Android has no light variant, so the
        // app is dark only. Info.plist sets UIUserInterfaceStyle as well; this
        // covers windows created before the plist value is honoured.
        window?.overrideUserInterfaceStyle = .dark
    }

    // App wide appearance (global appearance proxies only).
    private func setupAppearance() {
        // Navigation bar: Material 3 puts the app bar on colorSurface with
        // on-surface text. The accent is reserved for controls, not titles.
        let navBarAppearance = UINavigationBarAppearance()
        navBarAppearance.configureWithOpaqueBackground()
        navBarAppearance.backgroundColor = UIColor.themeSurface
        navBarAppearance.shadowColor = UIColor.themeOutlineVariant
        navBarAppearance.titleTextAttributes = [.foregroundColor: UIColor.themeOnSurface]
        navBarAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor.themeOnSurface]

        UINavigationBar.appearance().standardAppearance = navBarAppearance
        UINavigationBar.appearance().compactAppearance = navBarAppearance
        // scrollEdgeAppearance is deliberately left at the system default.
        //
        // On iOS 26 an opaque scrollEdgeAppearance installed through the
        // UINavigationBar appearance proxy stops the large title from being
        // drawn whenever scrollable content sits directly under the bar: the
        // title is still set (it shows in the accessibility tree at its normal
        // frame) but the label never renders, leaving a blank bar with only the
        // toolbar items visible. It reproduced on an iPhone 16 Pro running
        // iOS 26.1 on the Games, Settings and Account tabs; Backup escaped it
        // only because a segmented picker sits between the bar and the list.
        //
        // Dropping it costs nothing visually: themeSurface and themeBackground
        // are the same colour (0x131315), so the default transparent scroll
        // edge paints exactly what the opaque appearance painted, and the
        // separator is meant to be hidden at the top anyway. Once the user
        // scrolls, standardAppearance above supplies the Material 3 surface.
        UINavigationBar.appearance().tintColor = UIColor.themePrimary

        // Tab bar: navigation bar surface one step up the elevation ladder,
        // primary for the selected item and on-surface-variant for the rest.
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithOpaqueBackground()
        tabBarAppearance.backgroundColor = UIColor.themeSurfaceContainer
        tabBarAppearance.shadowColor = UIColor.themeOutlineVariant
        for itemAppearance in [
            tabBarAppearance.stackedLayoutAppearance,
            tabBarAppearance.inlineLayoutAppearance,
            tabBarAppearance.compactInlineLayoutAppearance
        ] {
            itemAppearance.selected.iconColor = UIColor.themePrimary
            itemAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor.themePrimary]
            itemAppearance.normal.iconColor = UIColor.themeOnSurfaceVariant
            itemAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor.themeOnSurfaceVariant]
        }

        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance

        // Segmented controls otherwise keep the iOS system greys, which read
        // as a lighter, bluer surface than the Material 3 containers.
        let segmented = UISegmentedControl.appearance()
        segmented.backgroundColor = UIColor.themeSurfaceContainer
        segmented.selectedSegmentTintColor = UIColor.themeSecondaryContainer
        segmented.setTitleTextAttributes(
            [.foregroundColor: UIColor.themeOnSurfaceVariant], for: .normal)
        segmented.setTitleTextAttributes(
            [.foregroundColor: UIColor.themeOnSurface], for: .selected)

        UITableView.appearance().backgroundColor = UIColor.themeBackground
        UITableViewCell.appearance().backgroundColor = UIColor.themeBackground
        UICollectionView.appearance().backgroundColor = UIColor.themeBackground
    }

    func applicationWillResignActive(_ application: UIApplication) {
        // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
        // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
        // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        // Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
        //StoreReviewHelper.shared.incrementAppLaunchCount()
        //StoreReviewHelper.shared.requestReviewIfAppropriate()

        // Re-asks StoreKit about both entitlement sources. A launch read that
        // failed with nothing cached leaves the entitlement undecided, and
        // undecided keeps every gate permissive; coming back to the app with
        // connectivity is the moment that can be settled.
        ProEntitlementStore.shared.recheck()
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
    }

    // URL handling.
    func application(_ app: UIApplication,
                    open url: URL,
                    options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        // Google Sign-In URL handling.
        if GIDSignIn.sharedInstance.handle(url) {
            return true
        }

        // Discord OAuth redirect handling.
        if discordRedirectHandler.handleUrl(url) {
            return true
        }

        // Shared-save links, before the file fallback: yabasanshiro://backup/{id}
        // shares its scheme with the Discord callback, so this has to run
        // after that handler and before "treat the URL as a file".
        if SharedBackupLinkRouter.shared.handle(url: url) {
            return true
        }

        // Opening a file handed over by another app.
        openMainScreenController(withFileAt: url)
        return true
    }

    /// Universal Links arrive here rather than through `open url:`.
    ///
    /// Inert until the Associated Domains entitlement is provisioned and the
    /// apple-app-site-association file is served from www.yabasanshiro.com;
    /// until then the same links open Safari and the custom scheme is the
    /// only route in.
    func application(_ application: UIApplication,
                     continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        SharedBackupLinkRouter.shared.handle(userActivity: userActivity)
    }

    // Custom hook that would launch MainScreenController to handle the file.
    func openMainScreenController(withFileAt url: URL) {
    }
    
    // MARK: - Firebase Messaging Configuration
    private func configureFirebaseMessaging() {
        // Register default notification category values before any
        // subscribeToEnabledTopics() call (fired from token callbacks)
        MessagingManager.shared.registerDefaultCategorySettings()

        // Set messaging delegate
        Messaging.messaging().delegate = self
        
        // Set UNUserNotificationCenter delegate
        UNUserNotificationCenter.current().delegate = self
        
        // Request notification permissions
        requestNotificationPermissions()
        
        // Register for remote notifications
        UIApplication.shared.registerForRemoteNotifications()
        
        // FCM token will be retrieved after APNs token is set in didRegisterForRemoteNotificationsWithDeviceToken
        // This avoids the "APNS device token not set" error
        print("Waiting for APNs token before retrieving FCM token...")
    }
    
    private func requestNotificationPermissions() {
        let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
        UNUserNotificationCenter.current().requestAuthorization(
            options: authOptions,
            completionHandler: { granted, error in
                if let error = error {
                    print("Error requesting notification permissions: \(error)")
                } else {
                    print("Notification permissions granted: \(granted)")
                    // Store permission status in UserDefaults for settings screen
                    UserDefaults.standard.set(granted, forKey: "notificationPermissionGranted")
                }
            }
        )
    }
    
    private func saveFCMTokenToFirestore(token: String) {
        MessagingManager.shared.saveFCMTokenToFirestore(token: token)
    }
    
    // MARK: - MessagingDelegate
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        print("Firebase registration token: \(String(describing: fcmToken))")
        
        if let token = fcmToken {
            saveFCMTokenToFirestore(token: token)
        }
        
        // Subscribe to enabled notification topics
        MessagingManager.shared.subscribeToEnabledTopics()
        
        // Note: This callback is fired at each app startup and whenever a new token is generated.
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    // Handle notification when app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                              willPresent notification: UNNotification,
                              withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        
        // Print message ID if available
        if let messageID = userInfo["gcm.message_id"] {
            print("Message ID: \(messageID)")
        }
        
        // Show notification even when app is in foreground
        if #available(iOS 14.0, *) {
            completionHandler([[.alert, .sound, .badge, .list, .banner]])
        } else {
            completionHandler([[.alert, .sound, .badge]])
        }
    }
    
    // Handle notification tap
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                              didReceive response: UNNotificationResponse,
                              withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        
        // Print message ID if available
        if let messageID = userInfo["gcm.message_id"] {
            print("Message ID: \(messageID)")
        }
        
        // Handle notification tap actions
        handleNotificationTap(userInfo: userInfo)
        
        completionHandler()
    }
    
    private func handleNotificationTap(userInfo: [AnyHashable: Any]) {
        // TODO: Handle different notification types
        // - Achievement notifications -> open RetroAchievements
        // - Game updates -> open specific game
        // - System notifications -> open settings
        print("Notification tapped with userInfo: \(userInfo)")
        
        // Check for notification type
        if let notificationType = userInfo["type"] as? String {
            switch notificationType {
            case "achievement":
                // Open RetroAchievements section
                print("Would open RetroAchievements section")
                break
            case "game_update":
                // Open specific game if gameId is provided
                print("Would open game update section")
                break
            case "system":
                // Open settings or appropriate section
                print("Would open settings section")
                break
            default:
                break
            }
        }
    }
    
    // MARK: - Remote Notification Registration
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenParts = deviceToken.map { data in String(format: "%02.2hhx", data) }
        let token = tokenParts.joined()
        print("APNs device token (hex): \(token)")
        
        // Set APNs token for Firebase Messaging
        Messaging.messaging().apnsToken = deviceToken
        
        // Now retrieve FCM token after APNs token is set
        Messaging.messaging().token { fcmToken, error in
            if let error = error {
                print("Error fetching FCM registration token after APNs: \(error)")
            } else if let fcmToken = fcmToken {
                print("FCM registration token (after APNs): \(fcmToken)")
                self.saveFCMTokenToFirestore(token: fcmToken)
                
                // Subscribe to enabled topics
                MessagingManager.shared.subscribeToEnabledTopics()
            }
        }
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Failed to register for remote notifications: \(error)")
    }
}
