import SwiftUI

/// A search field that stays hidden until the user asks for it, mirroring the
/// Android toolbar search on the game select screen (GameSelectFragmentPhone2
/// showSearchBar / hideSearchBar). Closing it clears the query, so a hidden
/// field never leaves a stale filter applied.
///
/// Plain reusable view: the owner holds the text and the visibility flag.
struct SearchField: View {
    @Binding var text: String
    let prompt: String
    /// Called when the user dismisses the field. The caller hides it; the
    /// text has already been cleared by the time this runs.
    let onDismiss: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.themeOnSurfaceVariant)
                    .accessibilityHidden(true)

                TextField("", text: $text,
                          prompt: Text(prompt)
                            .foregroundColor(Color.themeOnSurfaceVariant))
                    .focused($isFocused)
                    .foregroundStyle(Color.themeOnSurface)
                    .tint(Color.themePrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .accessibilityLabel(prompt)

                if !text.isEmpty {
                    Button {
                        text = ""
                        isFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.themeOnSurfaceVariant)
                    }
                    .accessibilityLabel(String(localized: "Clear search",
                                               comment: "Clear the search field"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.themeSurfaceContainerHigh)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button(String(localized: "Cancel", comment: "Close the search field")) {
                dismiss()
            }
            .foregroundStyle(Color.themePrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear {
            // Raise the keyboard the moment the field appears, as the
            // Android showSearchBar does with requestFocus + showSoftInput.
            isFocused = true
        }
    }

    /// Android hideSearchBar semantics: clear the query so the filter resets.
    private func dismiss() {
        text = ""
        isFocused = false
        onDismiss()
    }
}

extension SearchField {
    /// How the field slides in and out. Reduce Motion gets a plain fade.
    static func transition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }

    /// Animation used when toggling the field, honoring Reduce Motion.
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0.15) : .easeInOut(duration: 0.2)
    }
}

/// A toolbar button that reveals the search field. Shared by the tabs so the
/// icon, the accessibility label and the toggle animation stay identical.
struct SearchToolbarButton: View {
    @Binding var isActive: Bool
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(SearchField.animation(reduceMotion: reduceMotion)) {
                if isActive {
                    onClose()
                    isActive = false
                } else {
                    isActive = true
                }
            }
        } label: {
            Image(systemName: "magnifyingglass")
        }
        .accessibilityLabel(String(localized: "Search", comment: "Search button"))
    }
}
