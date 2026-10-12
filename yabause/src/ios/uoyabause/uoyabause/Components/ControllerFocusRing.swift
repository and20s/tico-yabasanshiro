import SwiftUI

private struct ControllerConnectedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while a game controller is attached. Set once, at the root of the
    /// home UI, from HomeGamePadManager.
    var isControllerConnected: Bool {
        get { self[ControllerConnectedKey.self] }
        set { self[ControllerConnectedKey.self] = newValue }
    }
}

private struct ActiveControllerPaneKey: EnvironmentKey {
    static let defaultValue: ControllerPane? = nil
}

private struct ControllerPaneIdentityKey: EnvironmentKey {
    static let defaultValue: ControllerPane? = nil
}

extension EnvironmentValues {
    /// Which column currently receives controller input. Set once, by
    /// MainTabView, and only in the regular-width layout: nil means there is
    /// one pane, so every ring is drawn at full strength.
    var activeControllerPane: ControllerPane? {
        get { self[ActiveControllerPaneKey.self] }
        set { self[ActiveControllerPaneKey.self] = newValue }
    }

    /// Which column the enclosing subtree draws in. Set by each pane's root.
    var controllerPaneIdentity: ControllerPane? {
        get { self[ControllerPaneIdentityKey.self] }
        set { self[ControllerPaneIdentityKey.self] = newValue }
    }
}

extension View {
    /// Marks a subtree as one column of the two-pane layout, so the rings
    /// inside it can tell whether their column is the live one.
    func controllerPaneIdentity(_ pane: ControllerPane) -> some View {
        environment(\.controllerPaneIdentity, pane)
    }
}

/// The one focus appearance shared by every controller-navigable surface:
/// a 3pt themePrimary border over a themeSurfaceContainerHighest fill,
/// following what GameCardView already did.
///
/// Drawn only while a controller is connected, per Material 3's focus state
/// and so touch users never see a selection they did not make.
struct ControllerFocusRing: ViewModifier {
    @Environment(\.isControllerConnected) private var isControllerConnected
    @Environment(\.activeControllerPane) private var activeControllerPane
    @Environment(\.controllerPaneIdentity) private var paneIdentity

    let isFocused: Bool
    let cornerRadius: CGFloat
    /// Background used when the item is not focused, so a surface that has
    /// its own fill can hand it over instead of stacking two backgrounds.
    let base: Color

    private var isActive: Bool { isFocused && isControllerConnected }

    /// True unless this ring is in a column that is not the live one. Both
    /// values are nil at compact width and in anything presented over the
    /// layout, where "which pane" does not apply.
    private var isInActivePane: Bool {
        guard let active = activeControllerPane, let identity = paneIdentity else {
            return true
        }
        return active == identity
    }

    /// Every pane keeps a visible mark of where its selection is, or the user
    /// cannot tell what Left/Right would bring them back to (spec section
    /// 4.5). Only one of them is the live one though, so the others show a
    /// plain outline and drop the highlight fill.
    private var strokeColor: Color {
        guard isActive else { return .clear }
        return isInActivePane ? Color.themePrimary : Color.themeOutline
    }

    private var fill: Color {
        isActive && isInActivePane ? Color.themeSurfaceContainerHighest : base
    }

    func body(content: Content) -> some View {
        content
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(strokeColor, lineWidth: isInActivePane ? 3 : 2))
            .animation(.easeOut(duration: 0.15), value: isActive)
            .animation(.easeOut(duration: 0.15), value: isInActivePane)
    }
}

extension View {
    /// Applies the shared controller focus appearance.
    func controllerFocusRing(_ isFocused: Bool,
                             cornerRadius: CGFloat = 12,
                             base: Color = .clear) -> some View {
        modifier(ControllerFocusRing(isFocused: isFocused,
                                     cornerRadius: cornerRadius,
                                     base: base))
    }

    /// Declares this view's focus scope: pushed while the view is on screen,
    /// popped when it leaves. Screens never install GCController handlers of
    /// their own (ios/CLAUDE.md CRITICAL); this is the whole of their
    /// participation in controller input.
    func controllerFocusScope(_ scope: ControllerFocusScope,
                              in coordinator: ControllerFocusCoordinator?) -> some View {
        onAppear { coordinator?.push(scope) }
            .onDisappear { coordinator?.pop(scope) }
    }

    /// Declares a presentation the controller cannot drive: nothing to focus,
    /// B closes it, and the screen underneath stops receiving input while it
    /// is up. See ModalBlockerScope.
    func modalControllerBlocker(named name: String,
                                in coordinator: ControllerFocusCoordinator?,
                                onClose: @escaping () -> Void) -> some View {
        modifier(ModalControllerBlocker(name: name, coordinator: coordinator,
                                        onClose: onClose))
    }

    /// The same block, but for a presentation this view puts up rather than is
    /// part of -- a system picker, say, whose content we never build. The
    /// scope follows `isPresented` instead of this view's lifetime, which
    /// would otherwise be the whole session.
    func modalControllerBlocker(named name: String,
                                in coordinator: ControllerFocusCoordinator?,
                                onClose: @escaping () -> Void,
                                isPresented: Bool) -> some View {
        modifier(PresentedModalControllerBlocker(name: name,
                                                 coordinator: coordinator,
                                                 onClose: onClose,
                                                 isPresented: isPresented))
    }
}

private struct PresentedModalControllerBlocker: ViewModifier {
    let name: String
    let coordinator: ControllerFocusCoordinator?
    let onClose: () -> Void
    let isPresented: Bool

    @StateObject private var scope = ModalBlockerScope()

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { presented in
                scope.scopeName = name
                scope.onClose = onClose
                if presented {
                    coordinator?.push(scope)
                } else {
                    coordinator?.pop(scope)
                }
            }
            .onDisappear { coordinator?.pop(scope) }
    }
}

private struct ModalControllerBlocker: ViewModifier {
    let name: String
    let coordinator: ControllerFocusCoordinator?
    let onClose: () -> Void

    @StateObject private var scope = ModalBlockerScope()

    func body(content: Content) -> some View {
        content
            .controllerFocusScope(scope, in: coordinator)
            .onAppear {
                scope.scopeName = name
                scope.onClose = onClose
            }
    }
}
