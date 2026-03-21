import AppKit
import Foundation

/// First-launch onboarding wizard. Collects:
/// 1. Where to save recordings (WAV files)
/// 2. Where to save transcripts/summaries (markdown files)
/// 3. AssemblyAI API key (stored in Keychain)
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

            // Step 3: AssemblyAI API key
            let apiKey = promptForAPIKey()

            // Build config
            let recordingsPath = (recordingsDir as NSString).appendingPathComponent("recordings")
            let transcriptsPath = (transcriptsDir as NSString).appendingPathComponent("transcripts")

            // Create directories
            try? FileManager.default.createDirectory(atPath: recordingsPath, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: transcriptsPath, withIntermediateDirectories: true)

            // Save API key to Keychain
            if let key = apiKey, !key.isEmpty {
                let saved = KeychainHelper.save(key: KeychainHelper.assemblyAIKey, value: key)
                if saved {
                    fputs("[onboarding] AssemblyAI API key saved to Keychain\n", stderr)
                } else {
                    fputs("[onboarding] WARNING: Failed to save API key to Keychain\n", stderr)
                }
            }

            let config = AppConfig(
                recordingsDir: recordingsPath,
                transcriptsDir: transcriptsPath,
                entities: [],
                onboardingComplete: true
            )
            config.save()

            fputs("[onboarding] Setup complete — recordings: \(recordingsPath), transcripts: \(transcriptsPath)\n", stderr)
            completion(.completed(config))
        }
    }

    private static func pickFolder(title: String, message: String, defaultPath: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "\(message)\n\nCurrent selection: \(defaultPath)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Use Default")
        alert.addButton(withTitle: "Choose Folder…")
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
            // User cancelled the folder picker — fall back to default
            return defaultPath
        } else {
            return nil
        }
    }

    private static func promptForAPIKey() -> String? {
        let alert = NSAlert()
        alert.messageText = "AssemblyAI API Key"
        alert.informativeText = "Paste your AssemblyAI API key for speech-to-text transcription.\nThis will be stored securely in your macOS Keychain.\n\nYou can skip this and add it later in Settings."
        alert.alertStyle = .informational

        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 350, height: 24))
        input.placeholderString = "Paste API key here"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        alert.addButton(withTitle: "Save Key")
        alert.addButton(withTitle: "Skip for Now")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            let key = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : key
        }
        return nil
    }
}
