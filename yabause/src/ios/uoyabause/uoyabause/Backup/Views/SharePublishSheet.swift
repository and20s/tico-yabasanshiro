import SwiftUI

/// Whether the user has agreed to publish saves publicly.
///
/// Asked once and remembered, as Android does: the warning matters the first
/// time and becomes noise afterwards.
enum SharePublishConsent {
    private static let key = "backup_share.public_share_consented"

    static var isGranted: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func grant() {
        UserDefaults.standard.set(true, forKey: key)
    }

#if DEBUG
    static func revokeForTesting() {
        UserDefaults.standard.removeObject(forKey: key)
    }
#endif
}

/// The form that describes a save before it is published.
///
/// The game title is required: the community list is browsed by game, so an
/// untitled record is one nobody finds.
struct SharePublishSheet: View {
    let save: BackupSave
    /// Reads the save's bytes and screenshot when the user commits.
    let loadPayload: () async -> (data: Data, screenshot: Data?)?
    var focus: ControllerFocusCoordinator?
    /// Called with the new document id once it is published.
    var onPublished: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.isControllerConnected) private var isControllerConnected

    @State private var details = SharedBackupDetails()
    /// Seeding happens in onAppear, which can fire again; without this a
    /// reappearing sheet would throw away what the user typed.
    @State private var didSeed = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @StateObject private var scope =
        ActionListFocusModel(scopeName: "sharePublish", isModal: true)
    /// Stateless, so a plain property rather than observed state.
    private let publisher = SharedBackupPublisher()

    /// Row order, which the focus scope mirrors.
    private enum Row: Int, CaseIterable {
        case gameTitle, productNumber, description, publish
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    field(.gameTitle,
                          title: String(localized: "Game title",
                                        comment: "Share form game title"),
                          text: $details.gameTitle)
                    field(.productNumber,
                          title: String(localized: "Product number",
                                        comment: "Share form product number"),
                          text: $details.productNumber)
                    field(.description,
                          title: String(localized: "Description",
                                        comment: "Share form description"),
                          text: $details.description)
                } header: {
                    Text(save.filename)
                } footer: {
                    Text(String(localized: "A game title is required so others can find this save.",
                                comment: "Share form title requirement"))
                }

                Section {
                    publishRow
                }
            }
            .listRowBackground(Color.themeSurfaceContainerHigh)
            .scrollContentBackground(.hidden)
            .background(Color.themeBackground)
            .navigationTitle(String(localized: "Share to Community",
                                    comment: "Share sheet title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(String(localized: "Cancel", comment: "Cancel")) { dismiss() }
                }
            }
            .overlay {
                if isWorking {
                    ProgressView(String(localized: "Sharing...",
                                        comment: "Share progress"))
                        .padding(24)
                        .background(Color.themeSurfaceContainerHigh,
                                    in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .controllerFocusScope(scope, in: focus)
        .onAppear {
            seedDetails()
            configureScope()
        }
        .onChange(of: isWorking) { _ in declareRows() }
        .alert(String(localized: "Error", comment: "Error alert title"),
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Prefill

    /// Fills the form from the game that wrote the save, as Android does.
    /// The Saturn save carries no title, so this comes from the metadata the
    /// emulator recorded at write time; it stays editable because that
    /// metadata is missing for saves made before it existed.
    private func seedDetails() {
        guard !didSeed else { return }
        didSeed = true
        details.gameTitle = save.gameTitle ?? ""
        details.productNumber = save.productNumber ?? ""
    }

    // MARK: - Controller focus

    private func configureScope() {
        scope.isBlocked = { isWorking || errorMessage != nil }
        scope.onConfirm = {
            guard errorMessage != nil else { return false }
            errorMessage = nil
            return true
        }
        scope.onClose = {
            if errorMessage != nil {
                errorMessage = nil
                return true
            }
            dismiss()
            return true
        }
        declareRows()
    }

    private func declareRows() {
        guard !isWorking else {
            scope.setActions([])
            return
        }
        // Text entry is out of scope for the controller (spec 1.2), so the
        // three fields do nothing on A; they stay in the list only so Down
        // walks past them to Share the way the screen reads.
        scope.setActions([{}, {}, {}, { Task { await publish() } }])
        scope.applyInitialFocus(controllerConnected: isControllerConnected)
    }

    // MARK: - Rows

    private func field(_ row: Row, title: String,
                       text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.themeOnSurfaceVariant)
            TextField(title, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .controllerFocusRing(scope.focused == row.rawValue, cornerRadius: 8)
        .id(row.rawValue)
    }

    private var publishRow: some View {
        Button {
            Task { await publish() }
        } label: {
            Text(String(localized: "Share", comment: "Publish button"))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .foregroundStyle(Color.themeOnPrimary)
        .disabled(!details.isValid || isWorking)
        .controllerFocusRing(scope.focused == Row.publish.rawValue,
                             cornerRadius: 8)
        .id(Row.publish.rawValue)
    }

    // MARK: - Publish

    private func publish() async {
        guard details.isValid else {
            errorMessage = String(localized: "A game title is required.",
                                  comment: "Share missing title error")
            return
        }
        isWorking = true
        defer { isWorking = false }

        guard let payload = await loadPayload() else {
            errorMessage = String(localized: "Could not read the save.",
                                  comment: "Share read error")
            return
        }
        do {
            let id = try await publisher.publish(save: save, data: payload.data,
                                                 screenshot: payload.screenshot,
                                                 details: details)
            onPublished(id)
            dismiss()
        } catch SharedBackupPublishError.signInRequired {
            errorMessage = String(localized: "Sign in to share saves.",
                                  comment: "Share sign-in required")
        } catch {
            errorMessage = String(localized: "Could not share the save.",
                                  comment: "Share failed")
            print("SharePublishSheet: publish failed: \(error)")
        }
    }
}
