import Combine
import Foundation
import GameController

/// Translates GCController input into high-level home-screen events.
/// IMPORTANT (see ios/CLAUDE.md): handlers are global per controller, so
/// this manager must deactivate when a legacy screen (settings/account/
/// emulator) takes over, and reactivate when the home UI is frontmost.
@MainActor
final class HomeGamePadManager: ObservableObject {
    /// Hashable so a held direction can be tracked by which one it is: a roll
    /// from Down to Up must not have the release of one stop the other.
    enum Event: Hashable {
        case up, down, left, right
        case select      // A button
        case back        // B button
        case nextTab     // R shoulder / trigger
        case prevTab     // L shoulder / trigger
    }

    /// Posted when a non-home screen takes over the controller (the
    /// emulator). The manager deactivates so it cannot clobber the
    /// handlers that screen installs for itself.
    static let shouldYieldNotification =
        Notification.Name("HomeGamePadManagerShouldYield")

    /// The counterpart of `shouldYieldNotification`: posted when that screen
    /// goes away and the home UI is frontmost again. Without it `deactivate()`
    /// is a one-way switch, and since L/R is the only way to change tab with
    /// a controller, the tab-change reactivation can never fire to recover.
    static let didResumeNotification =
        Notification.Name("HomeGamePadManagerDidResume")

    /// The only publication channel. A single-slot `onEvent` closure used to
    /// exist alongside it and had the same last-writer-wins hazard as the raw
    /// handlers, one level up. Stored (not rebuilt per access) so `onReceive`
    /// keeps one subscription.
    private(set) lazy var events: AnyPublisher<Event, Never> =
        eventSubject.eraseToAnyPublisher()

    /// Whether a controller is attached. Drives the focus rings: touch users
    /// are shown no selection at all.
    @Published private(set) var isControllerConnected = false

    private let eventSubject = PassthroughSubject<Event, Never>()

    private var controller: GCController?
    private var isActive = false

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(controllerDidConnect),
            name: .GCControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(controllerDidDisconnect),
            name: .GCControllerDidDisconnect, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(shouldYield),
            name: Self.shouldYieldNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(didResume),
            name: Self.didResumeNotification, object: nil)
        if let connected = GCController.controllers().first {
            controller = connected
            isControllerConnected = true
        }
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
    }

    /// Install input handlers. Call when the home UI becomes frontmost.
    func activate() {
        isActive = true
        guard let controller = controller else { return }
        installHandlers(on: controller)
        // A legacy screen we are replacing may clear its own handlers
        // during the same transition, after this call. Re-install once
        // on the next main-queue turn so the home UI wins that race.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isActive,
                  let current = self.controller else { return }
            self.installHandlers(on: current)
        }
    }

    /// Remove input handlers. Call when a legacy screen takes over.
    func deactivate() {
        isActive = false
        clearHandlers()
    }

    @objc private func controllerDidConnect(_ notification: Notification) {
        guard let connected = notification.object as? GCController else { return }
        controller = connected
        isControllerConnected = true
        if isActive {
            installHandlers(on: connected)
        }
    }

    @objc private func controllerDidDisconnect(_ notification: Notification) {
        guard let disconnected = notification.object as? GCController,
              disconnected == controller else { return }
        // controllers() can still list the one being removed at this point,
        // so filter it out rather than trusting the count.
        controller = GCController.controllers().first { $0 != disconnected }
        isControllerConnected = controller != nil
        // A direction held as the pad went away never gets its release, so
        // without this the repeat keeps firing forever with no controller
        // attached and nothing left that could stop it.
        stopAllRepeats()
        if isActive, let next = controller {
            installHandlers(on: next)
        }
    }

    @objc private func shouldYield(_ notification: Notification) {
        deactivate()
    }

    @objc private func didResume(_ notification: Notification) {
        activate()
    }

    // MARK: - Key repeat

    /// How long a direction is held before it starts repeating. Long enough
    /// that a normal press is one step, short enough not to feel stuck.
    static let repeatDelay: Duration = .milliseconds(400)

    /// The gap between repeats once they start. Roughly six rows a second,
    /// which walks a long list quickly while staying readable.
    static let repeatInterval: Duration = .milliseconds(160)

    /// The running repeat, keyed by direction so releasing one does not stop
    /// the other -- a roll from Down to Up would otherwise leave Up dead.
    private var repeatTasks: [Event: Task<Void, Never>] = [:]

    /// Which directions are physically held. Written from the controller's
    /// own queue and read on the main actor, so it lives outside the actor
    /// behind its own lock rather than being hopped onto it -- the hop is
    /// exactly what loses the ordering this exists to preserve.
    private final class HeldButtons: @unchecked Sendable {
        private var events: Set<Event> = []
        private let lock = NSLock()

        func set(_ event: Event, _ held: Bool) {
            lock.lock()
            defer { lock.unlock() }
            if held {
                events.insert(event)
            } else {
                events.remove(event)
            }
        }

        func contains(_ event: Event) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return events.contains(event)
        }

        func removeAll() {
            lock.lock()
            defer { lock.unlock() }
            events.removeAll()
        }
    }

    private nonisolated let held = HeldButtons()

    private nonisolated func setHeld(_ event: Event, _ isHeld: Bool) {
        held.set(event, isHeld)
    }

    private nonisolated func isHeld(_ event: Event) -> Bool {
        held.contains(event)
    }

#if DEBUG
    /// Publishes one event, so a test can check the press path without a
    /// controller to press.
    func sendForTesting(_ event: Event) {
        eventSubject.send(event)
    }
#endif

    private func startRepeating(_ event: Event) {
        repeatTasks[event]?.cancel()
        repeatTasks[event] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.repeatDelay)
                while !Task.isCancelled {
                    self?.eventSubject.send(event)
                    try await Task.sleep(for: Self.repeatInterval)
                }
            } catch {
                // Cancelled by the release, which is the normal way out.
            }
        }
    }

    private func stopRepeating(_ event: Event) {
        repeatTasks[event]?.cancel()
        repeatTasks[event] = nil
    }

    /// Stops every repeat. Called when the controller goes away or the
    /// manager deactivates, so a held direction cannot outlive either.
    private func stopAllRepeats() {
        repeatTasks.values.forEach { $0.cancel() }
        repeatTasks.removeAll()
        held.removeAll()
    }

    private func installHandlers(on controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        func emit(_ event: Event) -> (GCControllerButtonInput, Float, Bool) -> Void {
            { [weak self] _, _, pressed in
                if pressed {
                    Task { @MainActor in
                        self?.eventSubject.send(event)
                    }
                }
            }
        }
        /// Held Up or Down keeps stepping, so a long list can be walked
        /// without tapping once per row.
        ///
        /// Only the vertical pair repeats. Left and Right change column or
        /// walk the toolbar, where each press is a deliberate move and
        /// repeating would overshoot.
        func emitRepeating(_ event: Event) -> (GCControllerButtonInput, Float, Bool) -> Void {
            { [weak self] _, _, pressed in
                guard let self else { return }
                // Handlers arrive off the main actor and each hop is its own
                // task, so a quick tap's two tasks can run in either order.
                // Recording the state here, synchronously, means the task
                // acts on what the button is actually doing rather than on
                // whichever edge happened to get scheduled last -- otherwise
                // a release could be overtaken and leave a repeat armed with
                // nothing left to cancel it.
                self.setHeld(event, pressed)
                Task { @MainActor in
                    if self.isHeld(event) {
                        self.eventSubject.send(event)
                        self.startRepeating(event)
                    } else {
                        self.stopRepeating(event)
                    }
                }
            }
        }

        pad.buttonA.pressedChangedHandler = emit(.select)
        pad.buttonB.pressedChangedHandler = emit(.back)
        pad.dpad.up.pressedChangedHandler = emitRepeating(.up)
        pad.dpad.down.pressedChangedHandler = emitRepeating(.down)
        pad.dpad.left.pressedChangedHandler = emit(.left)
        pad.dpad.right.pressedChangedHandler = emit(.right)
        // Shoulders only. The triggers used to emit the same two events, and
        // an analog trigger crossing its threshold - or a natural L1+L2 grip -
        // would then step the tab twice for one perceived press. A clean L1
        // press measured as a single event on device, so this is insurance
        // rather than a measured fix, but it costs nothing.
        pad.leftShoulder.pressedChangedHandler = emit(.prevTab)
        pad.rightShoulder.pressedChangedHandler = emit(.nextTab)
    }

    private func clearHandlers() {
        // A held direction must not keep firing into a screen that has
        // stopped listening.
        stopAllRepeats()
        guard let pad = controller?.extendedGamepad else { return }
        pad.buttonA.pressedChangedHandler = nil
        pad.buttonB.pressedChangedHandler = nil
        pad.dpad.up.pressedChangedHandler = nil
        pad.dpad.down.pressedChangedHandler = nil
        pad.dpad.left.pressedChangedHandler = nil
        pad.dpad.right.pressedChangedHandler = nil
        pad.leftShoulder.pressedChangedHandler = nil
        pad.rightShoulder.pressedChangedHandler = nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

/// Pure tab-cycling arithmetic for the L/R shoulder navigation.
/// Extracted from the view so it can be unit tested.
enum HomeTabNavigator {
    /// Tab order used for L/R cycling. The Add tab is intentionally
    /// excluded: it is an action, not a destination.
    static let cycleOrder: [HomeTab] = [.games, .backup, .settings, .account]

    /// Returns the tab `delta` steps away from `tab`, wrapping around.
    /// Returns `tab` unchanged when it is not part of `order`.
    static func next(from tab: HomeTab, in order: [HomeTab] = cycleOrder,
                     delta: Int) -> HomeTab {
        guard !order.isEmpty, let index = order.firstIndex(of: tab) else { return tab }
        let count = order.count
        let shifted = ((index + delta) % count + count) % count
        return order[shifted]
    }
}
