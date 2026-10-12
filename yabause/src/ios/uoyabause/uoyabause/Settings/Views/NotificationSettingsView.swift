import SwiftUI
import UIKit
import UserNotifications

/// Per-category notification switches, plus the OS-level permission state.
struct NotificationSettingsView: View {
    /// Where this screen declares its focus scope. Optional so previews and
    /// tests can build the view without one.
    var focus: ControllerFocusCoordinator?
    /// Pops this screen. The push is driven by
    /// `navigationDestination(isPresented:)` in the settings tab, so only the
    /// tab can undo it.
    var onClose: (() -> Void)?

    @StateObject private var model = NotificationSettingsModel()
    @Environment(\.isControllerConnected) private var isControllerConnected

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section(String(localized: "Notification Permission",
                               comment: "Notification section")) {
                    HStack {
                        Text(String(localized: "Status", comment: "Permission status"))
                        Spacer()
                        Text(model.permissionDescription)
                            .foregroundStyle(.secondary)
                    }
                    if model.showsSystemSettingsLink {
                        row(model.systemSettingsRow) {
                            Button(String(localized: "Open Settings",
                                          comment: "Open the system settings app")) {
                                model.openSystemSettings()
                            }
                        }
                    }
                }

                Section(String(localized: "Notification Categories",
                               comment: "Notification section")) {
                    ForEach(Array(NotificationSettingsStore.Category.allCases.enumerated()),
                            id: \.element.id) { index, category in
                        row(model.categoryRow(index)) {
                            Toggle(category.title, isOn: model.binding(for: category))
                        }
                    }
                }
            }
            .followsControllerFocus(model.focusedRow, in: proxy) { $0 }
        }
        // Material 3 surfaces instead of the iOS grouped-list greys.
        .listRowBackground(Color.themeSurfaceContainerHigh)
        .scrollContentBackground(.hidden)
        .background(Color.themeBackground)
        .navigationTitle(String(localized: "Notification Settings",
                                comment: "Notification setting"))
        .navigationBarTitleDisplayMode(.inline)
        .controllerFocusScope(model, in: focus)
        .task { await model.refreshPermission() }
        .onAppear {
            model.onClose = onClose
            model.applyInitialFocus(controllerConnected: isControllerConnected)
        }
        .onChange(of: isControllerConnected) {
            model.applyInitialFocus(controllerConnected: $0)
        }
        .onChange(of: model.showsSystemSettingsLink) { _ in
            model.clampFocus()
        }
    }

    /// Applies the shared focus appearance and the scroll anchor to one row.
    private func row<V: View>(_ index: Int,
                              @ViewBuilder content: () -> V) -> some View {
        content()
            .controllerFocusRing(model.focusedRow == index, cornerRadius: 8)
            .id(index)
    }
}

@MainActor
final class NotificationSettingsModel: ObservableObject, ControllerFocusScope {
    @Published private(set) var permission: UNAuthorizationStatus = .notDetermined
    @Published private var enabled: [String: Bool] = [:]

    private let store: NotificationSettingsStore

    init(store: NotificationSettingsStore = NotificationSettingsStore()) {
        self.store = store
        for category in NotificationSettingsStore.Category.allCases {
            enabled[category.rawValue] = store.isEnabled(category)
        }
    }

    func binding(for category: NotificationSettingsStore.Category) -> Binding<Bool> {
        Binding(
            get: { self.enabled[category.rawValue] ?? false },
            set: { newValue in
                self.enabled[category.rawValue] = newValue
                self.store.setEnabled(newValue, for: category)
                self.applyTopicSubscription(newValue, for: category)
            })
    }

    func refreshPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        permission = settings.authorizationStatus
    }

    var permissionDescription: String {
        switch permission {
        case .authorized:
            return String(localized: "Allowed", comment: "Notification permission")
        case .denied:
            return String(localized: "Denied", comment: "Notification permission")
        case .provisional:
            return String(localized: "Provisional", comment: "Notification permission")
        case .ephemeral:
            return String(localized: "Temporary", comment: "Notification permission")
        case .notDetermined:
            return String(localized: "Not Requested", comment: "Notification permission")
        @unknown default:
            return String(localized: "Unknown", comment: "Notification permission")
        }
    }

    var showsSystemSettingsLink: Bool {
        permission == .denied || permission == .notDetermined
    }

    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Routes through MessagingManager exactly like the now-deleted UIKit
    /// notification settings screen did. The
    /// subscribe/unsubscribe calls themselves are private to MessagingManager,
    /// so this wrapper is the only way in. It also writes the same UserDefaults
    /// key the store just wrote, which is harmless because both use
    /// notification_{rawValue}_enabled.
    private func applyTopicSubscription(
        _ enabled: Bool, for category: NotificationSettingsStore.Category) {
        guard let legacyCategory = NotificationCategory(rawValue: category.rawValue) else {
            return
        }
        MessagingManager.shared.setNotificationCategoryEnabled(
            category: legacyCategory, enabled: enabled)
    }

    // MARK: - ControllerFocusScope

    @Published var focusedRow: Int?

    /// Set by the view: pops this screen back to the settings tab.
    var onClose: (() -> Void)?

    let scopeName = "notificationSettings"

    /// Modal: this screen is pushed over the settings tab and fills it, so
    /// L/R must not cycle the tab out from underneath it.
    let isModal = true

    /// The Status line is text, not a control, so it is not a row. Open
    /// Settings only exists while the permission is missing, which is why the
    /// category rows are numbered relative to it rather than from a constant.
    private var hasSystemSettingsRow: Bool { showsSystemSettingsLink }

    var systemSettingsRow: Int { 0 }

    func categoryRow(_ index: Int) -> Int {
        index + (hasSystemSettingsRow ? 1 : 0)
    }

    var itemCount: Int {
        NotificationSettingsStore.Category.allCases.count
            + (hasSystemSettingsRow ? 1 : 0)
    }

    var focusedIndex: Int? {
        get { focusedRow }
        set { focusedRow = newValue }
    }

    /// Focus the first row as soon as a controller is present (spec 4.1).
    func applyInitialFocus(controllerConnected: Bool) {
        guard controllerConnected, focusedRow == nil, itemCount > 0 else { return }
        focusedRow = 0
    }

    /// The permission can be granted while this screen is open, which removes
    /// the Open Settings row from under the selection.
    func clampFocus() {
        guard let row = focusedRow else { return }
        focusedRow = min(row, max(itemCount - 1, 0))
    }

    func activate() {
        guard let row = focusedRow else { return }
        if hasSystemSettingsRow {
            if row == systemSettingsRow {
                openSystemSettings()
                return
            }
        }
        let index = row - (hasSystemSettingsRow ? 1 : 0)
        let categories = NotificationSettingsStore.Category.allCases
        guard index >= 0, index < categories.count else { return }
        let category = categories[index]
        binding(for: category).wrappedValue.toggle()
    }

    /// B goes back to the settings list, which is the whole point of this
    /// screen having a scope: without one B would fall through to the tab
    /// underneath and do nothing.
    func close() -> Bool {
        guard let onClose = onClose else { return false }
        onClose()
        return true
    }
}
