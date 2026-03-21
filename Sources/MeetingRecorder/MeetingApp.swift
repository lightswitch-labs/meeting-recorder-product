import Foundation

/// Known meeting applications and their process identifiers.
enum MeetingApp: String, CaseIterable {
    case zoom = "us.zoom.xos"
    case discord = "com.hnc.Discord"
    case teams = "com.microsoft.teams2"
    case slack = "com.tinyspeck.slackmacgap"
    case facetime = "com.apple.FaceTime"
    case webex = "com.cisco.webexmeetingsapp"

    /// Display name for UI and file naming
    var displayName: String {
        switch self {
        case .zoom: return "Zoom"
        case .discord: return "Discord"
        case .teams: return "Teams"
        case .slack: return "Slack"
        case .facetime: return "FaceTime"
        case .webex: return "Webex"
        }
    }

    /// Whether this app supports automatic call detection via process monitoring.
    /// Zoom spawns CptHost when joining a call and kills it when leaving.
    var supportsProcessBasedDetection: Bool {
        switch self {
        case .zoom: return true
        default: return false
        }
    }
}

/// Represents a detected active meeting
struct DetectedMeeting {
    let app: MeetingApp
    let pids: [pid_t]
    let detectedAt: Date
}
