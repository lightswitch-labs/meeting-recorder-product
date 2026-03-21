import AppKit
import Foundation

/// First-launch onboarding wizard. Collects:
/// 1. Where to save recordings (WAV files)
/// 2. Where to save transcripts/summaries (markdown files)
/// 3. Google sign-in for API access
final class OnboardingWizard {

    enum Result {
        case completed(AppConfig)
        case cancelled
    }

    static func run(completion: @escaping (Result) -> Void) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)

            // Step 1: Welcome + recordings folder
            guard let recordingsDir = pickFolder(
                title: "Welcome to Meeting Recorder",
                message: "Choose where to save recordings (WAV files).\nA \"recordings\" subfolder will be created here.",
                defaultPath: NSString("~/meeting-recorder").expandingTildeInPath
            ) else {
                completion(.cancelled)
                return
            }

            // Step 2: Transcripts folder
            guard let transcriptsDir = pickFolder(
                title: "Transcripts & Summaries",
                message: "Choose where to save meeting transcripts and AI summaries.\nFolders will be organized by entity (team/client).",
                defaultPath: recordingsDir
            ) else {
                completion(.cancelled)
                return
            }

            // Step 3: Google sign-in
            promptForGoogleSignIn { signedIn in
                // Build config (proceed even if sign-in was skipped)
                let recordingsPath = (recordingsDir as NSString).appendingPathComponent("recordings")
                let transcriptsPath = (transcriptsDir as NSString).appendingPathComponent("transcripts")

                // Create directories
                try? FileManager.default.createDirectory(atPath: recordingsPath, withIntermediateDirectories: true)
                try? FileManager.default.createDirectory(atPath: transcriptsPath, withIntermediateDirectories: true)

                let config = AppConfig(
                    recordingsDir: recordingsPath,
                    transcriptsDir: transcriptsPath,
                    entities: [],
                    onboardingComplete: true
                )
                config.save()

                fputs("[onboarding] Setup complete — recordings: \(recordingsPath), transcripts: \(transcriptsPath), signed in: \(signedIn)\n", stderr)
                DispatchQueue.main.async {
                    completion(.completed(config))
                }
            }
        }
    }

    private static func pickFolder(title: String, message: String, defaultPath: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "\(message)\n\nCurrent selection: \(defaultPath)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Use Default")
        alert.addButton(withTitle: "Choose Folder\u{2026}")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            return defaultPath
        } else if response == .alertSecondButtonReturn {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Select"
            panel.directoryURL = URL(fileURLWithPath: defaultPath)

            if panel.runModal() == .OK, let url = panel.url {
                return url.path
            }
            return defaultPath
        } else {
            return nil
        }
    }

    private static func promptForGoogleSignIn(completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Sign In"
        alert.informativeText = "Sign in with your Google account to enable automatic transcription.\n\nYour browser will open for Google sign-in."
        alert.alertStyle = .informational

        alert.addButton(withTitle: "Sign in with Google")
        alert.addButton(withTitle: "Skip for Now")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            GoogleAuth.signIn { tokens in
                guard let tokens = tokens else {
                    fputs("[onboarding] Google sign-in failed\n", stderr)
                    DispatchQueue.main.async {
                        let errorAlert = NSAlert()
                        errorAlert.messageText = "Sign-In Failed"
                        errorAlert.informativeText = "Could not complete Google sign-in. You can try again later from the menu bar."
                        errorAlert.alertStyle = .warning
                        errorAlert.addButton(withTitle: "Continue Without Sign-In")
                        errorAlert.runModal()
                    }
                    completion(false)
                    return
                }

                // Store refresh token in Keychain for silent re-auth
                if let refreshToken = tokens.refreshToken {
                    _ = KeychainHelper.save(key: KeychainHelper.googleRefreshToken, value: refreshToken)
                }

                fputs("[onboarding] Google sign-in successful\n", stderr)
                completion(true)
            }
        } else {
            completion(false)
        }
    }
}
