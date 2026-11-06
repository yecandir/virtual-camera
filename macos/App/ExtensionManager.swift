import AppKit
import SystemExtensions

/// Installs / removes the bundled camera system extension.
final class ExtensionManager: NSObject, OSSystemExtensionRequestDelegate {
    static let identifier = "com.yecandir.virtualcamera.extension"

    var onStatus: ((String) -> Void)?
    var onActivated: (() -> Void)?
    /// The extension was newly installed or replaced (not a no-op re-activation).
    private var changed = false

    func install() {
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        onStatus?(String(localized: "Installing…"))
    }

    func uninstall() {
        let request = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        onStatus?(String(localized: "Removing…"))
    }

    // MARK: OSSystemExtensionRequestDelegate

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        // Replacing restarts the extension process (and drops every app's camera feed),
        // so only do it when the bundled build is actually different.
        if existing.bundleVersion == ext.bundleVersion && existing.bundleShortVersion == ext.bundleShortVersion {
            return .cancel
        }
        changed = true
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        changed = true
        // macOS 15 moved extension approval to its own pane; macOS 14 shows an "Allow"
        // button under Privacy & Security instead.
        if #available(macOS 15, *) {
            onStatus?(String(localized: "Approve it in System Settings → General → Login Items & Extensions"))
        } else {
            onStatus?(String(localized: "Click Allow in System Settings → Privacy & Security"))
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            onStatus?(String(localized: "Camera extension ready"))
            if changed && Self.relaunchAfterExtensionChange() { return }
            onActivated?()
        case .willCompleteAfterReboot:
            onStatus?(String(localized: "Restart your Mac to finish"))
        @unknown default:
            onStatus?("\(result)")
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let nsError = error as NSError
        NSLog("[vcam] system extension request failed: \(nsError)")
        if nsError.domain == OSSystemExtensionErrorDomain,
           nsError.code == OSSystemExtensionError.requestCanceled.rawValue {
            // We cancelled because the same version is already installed.
            onStatus?(String(localized: "Camera extension ready"))
        } else if nsError.domain == OSSystemExtensionErrorDomain,
           nsError.code == OSSystemExtensionError.unsupportedParentBundleLocation.rawValue {
            onStatus?(String(localized: "Move the app to /Applications first"))
        } else {
            onStatus?(String(localized: "Error: \(error.localizedDescription)"))
        }
    }

    /// CoreMediaIO's in-process device list doesn't pick up a newly installed/replaced camera
    /// extension until the app restarts (same as OBS/Camo). Relaunch once; returns true if so.
    private static func relaunchAfterExtensionChange() -> Bool {
        let key = "lastExtensionRelaunch"
        let last = UserDefaults.standard.double(forKey: key)
        let now = Date().timeIntervalSince1970
        guard now - last > 30 else { return false } // never loop
        UserDefaults.standard.set(now, forKey: key)
        let path = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open '\(path)'"]
        try? task.run()
        NSApp.terminate(nil)
        return true
    }
}
