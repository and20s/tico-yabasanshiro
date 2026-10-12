import SwiftUI

extension View {
    /// Keeps the controller's focused row on screen.
    ///
    /// The D-pad moves a focus *index*; the scroll position is a separate
    /// thing that has to be told to follow. Wiring that by hand was forgotten
    /// on five screens in a row, in two different ways -- the `onChange` while
    /// moving, and the `onAppear` that puts the row back after a rebuild threw
    /// the scroll position away. This does both, so a screen cannot get half
    /// of it.
    ///
    /// Apply inside a `ScrollViewReader`, and give each row
    /// `.id(anchor(forIndex))` with the same value this returns.
    ///
    /// - Parameters:
    ///   - focused: the scope's focused index.
    ///   - proxy: the enclosing reader's proxy.
    ///   - anchor: the id of the row at an index, or nil when there is none.
    func followsControllerFocus<ID: Hashable>(
        _ focused: Int?,
        in proxy: ScrollViewProxy,
        anchor: @escaping (Int) -> ID?
    ) -> some View {
        modifier(ControllerFocusScroll(focused: focused, proxy: proxy,
                                       anchor: anchor))
    }
}

private struct ControllerFocusScroll<ID: Hashable>: ViewModifier {
    let focused: Int?
    let proxy: ScrollViewProxy
    let anchor: (Int) -> ID?

    func body(content: Content) -> some View {
        content
            // Not animated on appearance: the row was already there as far as
            // the user is concerned, and animating it looks like a jump.
            .onAppear { scroll(animated: false) }
            .onChange(of: focused) { _ in scroll(animated: true) }
    }

    private func scroll(animated: Bool) {
        guard let focused, let id = anchor(focused) else { return }
        if animated {
            withAnimation { proxy.scrollTo(id, anchor: .center) }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}
