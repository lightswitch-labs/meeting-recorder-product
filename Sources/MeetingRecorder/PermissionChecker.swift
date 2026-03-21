import AVFoundation
import EventKit
import Foundation

/// Checks required macOS permissions on launch and alerts the user if any are missing.
/// All checks are passive — they read authorization status without activating any hardware.
struct PermissionChecker {

    struct PermissionStatus {
        let microphone: Bool
        let calendar: Bool

        var allGranted: Bool { microphone && calendar }

        var summary: String {
            var issues: [String] = []
            if !microphone { issues.append("Microphone") }
            if !calendar { issues.append("Calendar") }
            if issues.isEmpty { return "All permissions granted" }
            return "Missing permissions: \(issues.joined(separator: ", "))"
        }
    }

    /// Check permissions passively (no hardware activation)
    static func check(completion: @escaping (PermissionStatus) -> Void) {
        let status = PermissionStatus(
            microphone: checkMicrophone(),
            calendar: checkCalendar()
        )
        completion(status)
    }

    /// Show alert for missing permissions
    static func alertIfNeeded(_ status: PermissionStatus) {
        guard !status.allGranted else {
            fputs("[permissions] \(status.summary)\n", stderr)
            return
        }

        fputs("[permissions] WARNING: \(status.summary)\n", stderr)

        let script = """
        display notification "\(status.summary). Open System Settings > Privacy & Security to fix." with title "Meeting Recorder — Permissions Needed"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    // MARK: - Individual Checks

    private static func checkMicrophone() -> Bool {
        // Passive check — reads status without activating mic
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .authorized
    }

    private static func checkCalendar() -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        }
        return status == .authorized
    }

    // Note: Screen & System Audio Recording permission cannot be checked passively.
    // It will be validated when the first recording attempt is made. If permission
    // is missing, the AudioTapManager will throw an error and the user will be notified.
}
