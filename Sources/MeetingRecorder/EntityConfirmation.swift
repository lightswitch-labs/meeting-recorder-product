import AppKit
import Foundation

/// Shows a native macOS dialog after recording ends to confirm or change
/// the entity and meeting title before transcription.
final class EntityConfirmation {

    /// Show confirmation dialog for entity and meeting title.
    /// Entities are loaded dynamically from AppConfig.
    static func confirm(
        detectedEntity: String,
        meetingTitle: String,
        completion: @escaping (ConfirmationResult) -> Void
    ) {
        DispatchQueue.main.async {
            let config = AppConfig.load() ?? AppConfig.makeDefault()
            let entities = config.entities

            let alert = NSAlert()
            alert.messageText = "Meeting Recorded"
            alert.informativeText = "Confirm the meeting details below before transcription."
            alert.alertStyle = .informational

            // Build accessory view with title field + entity dropdown
            let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 110))

            // Meeting title field
            let titleLabel = NSTextField(labelWithString: "Meeting title:")
            titleLabel.frame = NSRect(x: 0, y: 88, width: 350, height: 16)
            titleLabel.font = NSFont.systemFont(ofSize: 11)
            titleLabel.textColor = .secondaryLabelColor
            accessoryView.addSubview(titleLabel)

            let titleField = NSTextField(frame: NSRect(x: 0, y: 62, width: 350, height: 24))
            titleField.stringValue = meetingTitle
            titleField.placeholderString = "Enter meeting title"
            titleField.font = NSFont.systemFont(ofSize: 13)
            accessoryView.addSubview(titleField)

            // Entity dropdown
            let entityLabel = NSTextField(labelWithString: "Entity:")
            entityLabel.frame = NSRect(x: 0, y: 38, width: 350, height: 16)
            entityLabel.font = NSFont.systemFont(ofSize: 11)
            entityLabel.textColor = .secondaryLabelColor
            accessoryView.addSubview(entityLabel)

            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 10, width: 350, height: 25))

            if entities.isEmpty {
                popup.addItem(withTitle: "No entities yet — add one below")
                popup.lastItem?.representedObject = "__none__"
                popup.lastItem?.isEnabled = false
            } else {
                for entity in entities {
                    popup.addItem(withTitle: entity.name)
                    popup.lastItem?.representedObject = entity.id
                }
            }
            popup.menu?.addItem(NSMenuItem.separator())
            popup.addItem(withTitle: "Add New Entity...")
            popup.lastItem?.representedObject = "__new__"

            // Pre-select the detected entity
            if let index = entities.firstIndex(where: { $0.id == detectedEntity }) {
                popup.selectItem(at: index)
            }
            accessoryView.addSubview(popup)

            alert.accessoryView = accessoryView

            alert.addButton(withTitle: "Transcribe")
            alert.addButton(withTitle: "Skip Transcription")

            // Bring app to front for the dialog
            NSApp.activate(ignoringOtherApps: true)

            // Make the title field the first responder so it's easy to edit
            alert.window.initialFirstResponder = titleField

            let response = alert.runModal()

            if response == .alertFirstButtonReturn {
                let selectedObject = popup.selectedItem?.representedObject as? String
                let confirmedTitle = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let finalTitle = confirmedTitle.isEmpty ? meetingTitle : confirmedTitle

                if selectedObject == "__new__" || selectedObject == "__none__" {
                    promptForNewEntity(meetingTitle: finalTitle, completion: completion)
                } else {
                    let entity = selectedObject ?? "general"
                    completion(.confirmed(entity: entity, meetingTitle: finalTitle))
                }
            } else {
                completion(.skipped)
            }
        }
    }

    private static func promptForNewEntity(
        meetingTitle: String,
        completion: @escaping (ConfirmationResult) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Add New Entity"
        alert.informativeText = "Enter a name for this entity (team, client, or project).\nA folder will be created for its meeting transcripts."
        alert.alertStyle = .informational

        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))

        let nameLabel = NSTextField(labelWithString: "Display name:")
        nameLabel.frame = NSRect(x: 0, y: 34, width: 300, height: 16)
        nameLabel.font = NSFont.systemFont(ofSize: 11)
        nameLabel.textColor = .secondaryLabelColor
        accessoryView.addSubview(nameLabel)

        let input = NSTextField(frame: NSRect(x: 0, y: 8, width: 300, height: 24))
        input.placeholderString = "e.g., Acme Corp"
        accessoryView.addSubview(input)

        alert.accessoryView = accessoryView
        alert.window.initialFirstResponder = input

        alert.addButton(withTitle: "Create & Transcribe")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                // Generate slug from name
                let id = name
                    .lowercased()
                    .components(separatedBy: CharacterSet.alphanumerics.inverted)
                    .filter { !$0.isEmpty }
                    .joined(separator: "-")

                // Persist the new entity
                if var config = AppConfig.load() {
                    config.addEntity(id: id, name: name)
                }

                completion(.confirmed(entity: id, meetingTitle: meetingTitle))
            } else {
                completion(.skipped)
            }
        } else {
            completion(.skipped)
        }
    }

    enum ConfirmationResult {
        case confirmed(entity: String, meetingTitle: String)
        case skipped
    }
}
