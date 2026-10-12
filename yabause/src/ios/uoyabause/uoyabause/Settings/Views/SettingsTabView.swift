import SwiftUI

/// The settings tab. Sections follow the Android categories so both apps
/// group the same things the same way.
struct SettingsTabView: View {
    /// Where this screen declares its focus scope. Optional so previews and
    /// tests can build the view without one.
    var focus: ControllerFocusCoordinator?

    /// Owned by MainTabView: the sidebar rebuilds this view on every tab
    /// change, which would otherwise reset the focused row each time.
    @ObservedObject var model: SettingsTabModel
    @Environment(\.isControllerConnected) private var isControllerConnected

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    generalSection
                    displaySection
                    soundSection
                    inputSection
                    notificationSection
                }
                // Material 3 surfaces instead of the iOS grouped-list greys.
                .listRowBackground(Color.themeSurfaceContainerHigh)
                .scrollContentBackground(.hidden)
                .background(Color.themeBackground)
                .navigationTitle(String(localized: "Settings", comment: "Settings tab"))
                .navigationDestination(isPresented: $model.showNotificationSettings) {
                    NotificationSettingsView(
                        focus: focus,
                        onClose: { model.showNotificationSettings = false })
                }
                .followsControllerFocus(model.focusedRow, in: proxy) { $0 }
            }
        }
        .controllerFocusScope(model, in: focus)
        .onAppear {
            model.applyInitialFocus(controllerConnected: isControllerConnected)
        }
        .onChange(of: isControllerConnected) {
            model.applyInitialFocus(controllerConnected: $0)
        }
    }

    /// Applies the shared focus appearance and the scroll anchor to one row.
    private func row<V: View>(_ item: SettingsTabModel.Row,
                              @ViewBuilder content: () -> V) -> some View {
        content()
            .controllerFocusRing(model.focusedRow == item.rawValue,
                                 cornerRadius: 8)
            .id(item.rawValue)
    }

    private var generalSection: some View {
        Section {
            row(.cartridge) {
                Picker(String(localized: "Cartridge", comment: "Cartridge setting"),
                       selection: $model.cartridge) {
                    ForEach(SettingsTabModel.cartridgeOptions) { option in
                        Text(option.title).tag(option.value)
                    }
                }
            }
        } header: {
            Text(String(localized: "General", comment: "Settings section"))
        } footer: {
            Text(String(localized: "Changes apply the next time a game starts.",
                        comment: "Settings apply timing note"))
        }
    }

    private var displaySection: some View {
        Section(String(localized: "Display", comment: "Settings section")) {
            row(.renderingResolution) {
                Picker(String(localized: "Rendering Resolution",
                              comment: "Resolution setting"),
                       selection: $model.renderingResolution) {
                    ForEach(SettingsTabModel.resolutionOptions) { option in
                        Text(option.title).tag(option.value)
                    }
                }
            }
            row(.showFPS) {
                Toggle(String(localized: "Show FPS", comment: "Display setting"),
                       isOn: $model.showFPS)
            }
            row(.frameSkip) {
                Toggle(String(localized: "Frame Skip", comment: "Display setting"),
                       isOn: $model.frameSkip)
            }
            row(.keepAspectRatio) {
                Toggle(String(localized: "Keep Aspect Ratio", comment: "Display setting"),
                       isOn: $model.keepAspectRatio)
            }
            row(.rotateScreen) {
                Toggle(String(localized: "Rotate Screen", comment: "Display setting"),
                       isOn: $model.rotateScreen)
            }
            row(.landscape) {
                Toggle(String(localized: "Landscape Mode", comment: "Display setting"),
                       isOn: $model.landscape)
            }
        }
    }

    private var soundSection: some View {
        Section(String(localized: "Sound", comment: "Settings section")) {
            row(.soundEngine) {
                Picker(String(localized: "Sound Quality", comment: "Sound setting"),
                       selection: $model.soundEngine) {
                    ForEach(SettingsTabModel.soundOptions) { option in
                        Text(option.title).tag(option.value)
                    }
                }
            }
        }
    }

    private var inputSection: some View {
        Section(String(localized: "Input", comment: "Settings section")) {
            row(.analogAsDPad) {
                Toggle(String(localized: "Analog as D-Pad", comment: "Input setting"),
                       isOn: $model.analogAsDPad)
            }
            // Deliberately not a focusable row. The pad-layout editor is out of
            // scope for controller navigation (spec section 1.2), so entering
            // it with A would strand a controller user in a screen with no way
            // back. It stays reachable by touch.
            NavigationLink(String(localized: "Pad Settings", comment: "Input setting")) {
                PadSettingsBridge()
                    .navigationTitle(String(localized: "Pad Settings",
                                            comment: "Input setting"))
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    /// A Button rather than a NavigationLink so touch and A take the same
    /// path: `navigationDestination(isPresented:)` is the only push the
    /// controller can drive, and two ways in would mean two destinations.
    private var notificationSection: some View {
        Section(String(localized: "Notifications", comment: "Settings section")) {
            row(.notificationSettings) {
                Button {
                    model.showNotificationSettings = true
                } label: {
                    HStack {
                        Text(String(localized: "Notification Settings",
                                    comment: "Notification setting"))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            // Decorative disclosure arrow. Left visible to
                            // VoiceOver it joins the button's label, which
                            // both reads badly and breaks exact-label lookups.
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Bridges the settings store to SwiftUI bindings, and is the settings tab's
/// controller focus scope.
@MainActor
final class SettingsTabModel: ObservableObject, ControllerFocusScope {
    /// The focusable rows, in the order they are drawn.
    ///
    /// A flat index, not one index per section. The D-pad here is
    /// one-dimensional by design (spec section 1.2 rules out tvOS-style
    /// all-direction focus), so a section-aware cursor would need a second
    /// axis that no button is assigned to; the sections are visual grouping
    /// and nothing more. It also means "Show FPS is the third row" stays true
    /// however the sections are later rearranged, which is what makes the
    /// five-input target measurable.
    ///
    /// Pad Settings is absent on purpose - see `inputSection`.
    enum Row: Int, CaseIterable {
        case cartridge
        case renderingResolution
        case showFPS
        case frameSkip
        case keepAspectRatio
        case rotateScreen
        case landscape
        case soundEngine
        case analogAsDPad
        case notificationSettings
    }

    struct Option: Identifiable {
        let value: Int
        let title: String
        var id: Int { value }
    }

    /// Same labels and values as the legacy screen.
    static let cartridgeOptions: [Option] = [
        Option(value: 0, title: String(localized: "None", comment: "Cartridge")),
        Option(value: 2, title: String(localized: "4Mbit BackupRam", comment: "Cartridge")),
        Option(value: 3, title: String(localized: "8Mbit BackupRam", comment: "Cartridge")),
        Option(value: 4, title: String(localized: "16Mbit BackupRam", comment: "Cartridge")),
        Option(value: 5, title: String(localized: "32Mbit BackupRam", comment: "Cartridge")),
        Option(value: 6, title: String(localized: "8Mbit DRAM", comment: "Cartridge")),
        Option(value: 7, title: String(localized: "32Mbit DRAM", comment: "Cartridge")),
    ]

    static let resolutionOptions: [Option] = [
        Option(value: 0, title: String(localized: "Native", comment: "Resolution")),
        Option(value: 1, title: String(localized: "4x", comment: "Resolution")),
        Option(value: 2, title: String(localized: "2x", comment: "Resolution")),
        Option(value: 3, title: String(localized: "Original", comment: "Resolution")),
    ]

    static let soundOptions: [Option] = [
        Option(value: 1, title: String(localized: "High Quality but slow",
                                       comment: "Sound quality")),
        Option(value: 0, title: String(localized: "Low Quality but fast",
                                       comment: "Sound quality")),
    ]

    private let store: EmulatorSettingsStore

    @Published var cartridge: Int { didSet { store.cartridge = cartridge } }
    @Published var renderingResolution: Int {
        didSet { store.renderingResolution = renderingResolution }
    }
    @Published var soundEngine: Int { didSet { store.soundEngine = soundEngine } }
    @Published var showFPS: Bool { didSet { store.showFPS = showFPS } }
    @Published var frameSkip: Bool { didSet { store.frameSkip = frameSkip } }
    @Published var keepAspectRatio: Bool {
        didSet { store.keepAspectRatio = keepAspectRatio }
    }
    @Published var rotateScreen: Bool { didSet { store.rotateScreen = rotateScreen } }
    @Published var analogAsDPad: Bool { didSet { store.analogAsDPad = analogAsDPad } }
    @Published var landscape: Bool { didSet { store.landscape = landscape } }

    init(store: EmulatorSettingsStore = EmulatorSettingsStore()) {
        self.store = store
        cartridge = store.cartridge
        renderingResolution = store.renderingResolution
        soundEngine = store.soundEngine
        showFPS = store.showFPS
        frameSkip = store.frameSkip
        keepAspectRatio = store.keepAspectRatio
        rotateScreen = store.rotateScreen
        analogAsDPad = store.analogAsDPad
        landscape = store.landscape
    }

    // MARK: - ControllerFocusScope

    @Published var focusedRow: Int?
    /// Drives `navigationDestination(isPresented:)`, which is the only push a
    /// controller can trigger.
    @Published var showNotificationSettings = false

    let scopeName = "settings"

    /// A tab's own column. It has no detail pane, so D-pad Right does nothing
    /// here, but Left still reaches the sidebar the way it does from Games.
    let pane: ControllerPane? = .content

    var itemCount: Int { Row.allCases.count }

    var focusedIndex: Int? {
        get { focusedRow }
        set { focusedRow = newValue }
    }

    /// Focus the first row as soon as a controller is present (spec 4.1).
    func applyInitialFocus(controllerConnected: Bool) {
        guard controllerConnected, focusedRow == nil else { return }
        focusedRow = 0
    }

    /// A toggles a switch, advances a picker to its next option, or follows a
    /// row that leads somewhere.
    ///
    /// A picker cycles rather than opening its menu: a SwiftUI `Picker` in a
    /// Form renders as a system menu whose highlighted item the app cannot
    /// move, so opening one with A would leave the user inside something the
    /// controller cannot drive. Cycling keeps every option reachable with the
    /// button that is already bound to "act on this row".
    func activate() {
        switch Row(rawValue: focusedRow ?? -1) {
        case .cartridge:
            cartridge = Self.nextOption(after: cartridge, in: Self.cartridgeOptions)
        case .renderingResolution:
            renderingResolution = Self.nextOption(after: renderingResolution,
                                                  in: Self.resolutionOptions)
        case .soundEngine:
            soundEngine = Self.nextOption(after: soundEngine, in: Self.soundOptions)
        case .showFPS:
            showFPS.toggle()
        case .frameSkip:
            frameSkip.toggle()
        case .keepAspectRatio:
            keepAspectRatio.toggle()
        case .rotateScreen:
            rotateScreen.toggle()
        case .landscape:
            landscape.toggle()
        case .analogAsDPad:
            analogAsDPad.toggle()
        case .notificationSettings:
            showNotificationSettings = true
        case nil:
            break
        }
    }

    /// The settings tab is a root: with nothing pushed there is nothing here
    /// for B to close. The pushed notification screen owns its own B.
    func close() -> Bool { false }

    /// Wraps, because a picker with no wrap would need a second button to go
    /// back and the D-pad's own movement is what does not wrap (spec 2).
    private static func nextOption(after value: Int, in options: [Option]) -> Int {
        guard !options.isEmpty else { return value }
        let index = options.firstIndex { $0.value == value } ?? -1
        return options[(index + 1) % options.count].value
    }
}
