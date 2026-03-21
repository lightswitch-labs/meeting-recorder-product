import Foundation

/// Attempts to match meetings to user-configured entities.
/// In the product version, entities are fully user-managed via AppConfig.
/// This detector tries to match calendar meeting titles against known entity names.
struct EntityDetector {

    static let defaultEntity = "general"

    /// Detect entity from a calendar meeting by matching title keywords
    /// against the user's configured entity list.
    static func detect(from meeting: CalendarMeeting) -> String {
        guard let config = AppConfig.load() else { return defaultEntity }
        let titleLower = meeting.title.lowercased()

        for entity in config.entities {
            // Match against entity name or id
            if titleLower.contains(entity.name.lowercased()) ||
               titleLower.contains(entity.id.lowercased()) {
                return entity.id
            }
        }

        return defaultEntity
    }
}
