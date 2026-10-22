import Foundation
import UIKit

/// Presents the system folder picker and returns the granted directory.
///
/// LIBRARY.md: use `UIDocumentPickerViewController(forOpeningContentTypes:
/// [.folder])`, do not import/copy the directory into the sandbox, and do not
/// invent an `allowsCloudFiles = false` switch. The picker can show several
/// locations, so the destination is validated afterwards (own container and
/// known cloud locations are rejected) rather than filtered in the UI.
@MainActor
final class SystemFolderPicker: NSObject, FolderPicking, UIDocumentPickerDelegate {
    private var continuation: CheckedContinuation<URL?, Never>?
    private weak var presentingViewController: UIViewController?

    override init() {
        super.init()
    }

    func pickLocalLibraryFolder() async -> URL? {
        guard continuation == nil else { return nil }
        guard let presenter = Self.topViewController() else { return nil }
        presentingViewController = presenter
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            self.continuation = continuation
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            picker.delegate = self
            picker.allowsMultipleSelection = false
            picker.shouldShowFileExtensions = true
            presenter.present(picker, animated: true)
        }
    }

    /// Asks for an explicit decision about THIS folder.
    ///
    /// REVIEW.md F05: the old `Bool` could not distinguish a dismissal from a
    /// refusal, and a false answer still led to selection. Cancel and "not
    /// confirmed" are now separate outcomes, and only an explicit affirmation
    /// authorizes selection.
    func localDestinationDecision(for url: URL) async -> LocalDestinationDecision {
        guard let presenter = Self.topViewController() else { return .cancelled }
        return await withCheckedContinuation { (continuation: CheckedContinuation<LocalDestinationDecision, Never>) in
            let alert = UIAlertController(
                title: "Keep originals in this folder?",
                message: "TruongCam will store permanent photo originals in \"\(url.lastPathComponent)\" and nowhere else. The folder must be local storage on this iPhone - not iCloud Drive and not another cloud provider - because a cloud library can move or evict your originals. TruongCam cannot verify retention for every provider; if this folder is not local On My iPhone storage, choose Cancel and pick one that is.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Use this local folder", style: .default) { _ in
                continuation.resume(returning: .confirmedLocalDestination)
            })
            // Dismissing the alert is NOT a refusal to select; it is a withdrawal.
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                continuation.resume(returning: .cancelled)
            })
            presenter.present(alert, animated: true)
        }
    }

    nonisolated func documentPicker(_ controller: UIDocumentPickerViewController,
                                    didPickDocumentsAt urls: [URL]) {
        let first = urls.first
        Task { @MainActor in
            self.finishPick(first, controller: controller)
        }
    }

    nonisolated func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        Task { @MainActor in
            self.finishPick(nil, controller: controller)
        }
    }

    private func finishPick(_ url: URL?, controller: UIDocumentPickerViewController) {
        guard let pending = continuation else { return }
        continuation = nil
        // The next step presents a confirmation alert. Deliver only after the
        // picker has disappeared, so that alert is not attached to a dismissing
        // system scene with an animating keyboard.
        controller.dismiss(animated: true) { pending.resume(returning: url) }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}
