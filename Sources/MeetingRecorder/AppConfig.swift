import Foundation

/// Persistent configuration stored at ~/.meeting-recorder/config.json
/// Manages user preferences set during onboarding and entity list.
struct AppConfig: Codable {
    var recordingsDir: String
    var transcriptsDir: String
    var entities: [Entity]
    var onboardingComplete: Bool

    struct Entity: Codable, Equatable {
        let id: String
        let name: String
    }

    static let configDir = NSString("~/.meeting-recorder").expandingTildeInPath
    static let configPath = (configDir as NSString).appendingPathComponent("config.json")

    /// Load config from disk, or return nil if onboarding hasn't run yet
    static func load() -> AppConfig? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return nil
        }
        return config
    }

    /// Save config to disk
    func save() {
        do {
            try FileManager.default.createDirectory(
                atPath: AppConfig.configDir,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(self)
            try data.write(to: URL(fileURLWithPath: AppConfig.configPath))
        } catch {
            fputs("[config] Failed to save: \(error)\n", stderr)
        }
    }

    /// Default config for fresh installs
    static func makeDefault() -> AppConfig {
        return AppConfig(
            recordingsDir: NSString("~/meeting-recorder/recordings").expandingTildeInPath,
            transcriptsDir: NSString("~/meeting-recorder/transcripts").expandingTildeInPath,
            entities: [],
            onboardingComplete: false
        )
    }

    /// Add an entity and save
    mutating func addEntity(id: String, name: String) {
        let entity = Entity(id: id, name: name)
        if !entities.contains(entity) {
            entities.append(entity)
            save()
        }
    }
}
