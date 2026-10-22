import SwiftUI

/// TruongCam application entry point.
///
/// One scene, one window. This is deliberately not a document-based app: the
/// sandbox `Documents` directory is not the permanent library, and permanent
/// originals live in a user-selected local Files folder outside this container.
@main
struct TruongCamApp: App {
    @State private var environment: AppEnvironment
    @State private var coordinator: AppCoordinator

    init() {
        let environment = AppEnvironment.makeProduction()
        _environment = State(initialValue: environment)
        _coordinator = State(initialValue: AppCoordinator(environment: environment))
    }

    /// Production library storage. Returns nil when the storage stack cannot be
    /// constructed, which leaves the library honestly unavailable rather than
    /// falling back to the app container.
    nonisolated private static func makeLibraryStore() -> (any LibraryStoring)? {
        LibraryStoreFactory.makeDefaultStore()
    }

    nonisolated private static func makeLibraryIndex() -> (any LibraryIndexing)? {
        LibraryStoreFactory.makeDefaultIndex()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .task {
                    // Production wiring. When no library storage is available the
                    // app reports an unselected root honestly instead of
                    // inventing a folder.
                    // A single, observable, idempotent graph start (REVIEW.md S03).
                    switch coordinator.graphState {
                    case .starting, .ready: return
                    case .idle, .failed: break
                    }
                    let stores = await Task.detached(priority: .userInitiated) {
                        (Self.makeLibraryStore(), Self.makeLibraryIndex())
                    }.value
                    _ = await coordinator.startOnce(store: stores.0, index: stores.1)
                }

        }
    }
}
