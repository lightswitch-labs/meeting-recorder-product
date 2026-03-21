import EventKit
import Foundation

/// Monitors the calendar for upcoming meetings with video call URLs.
/// Triggers recording before meetings start and provides entity detection via email domain.
final class CalendarTrigger {
    private let eventStore = EKEventStore()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.meetingrecorder.calendartrigger")
    private let pollInterval: TimeInterval
    private let leadTime: TimeInterval // how far ahead to trigger (seconds)
    private var onUpcomingMeeting: ((CalendarMeeting) -> Void)?
    private var onMeetingEnded: ((CalendarMeeting) -> Void)?
    private var activeMeetings: [String: CalendarMeeting] = [:] // keyed by event ID
    private var triggeredEventIDs: Set<String> = [] // prevent duplicate triggers

    /// Known meeting URL patterns
    private static let meetingURLPatterns = [
        "zoom.us/j/",
        "zoom.us/my/",
        "meet.google.com/",
        "teams.microsoft.com/l/meetup-join",
        "teams.live.com/meet/",
        "webex.com/meet/",
        "whereby.com/",
    ]

    init(pollInterval: TimeInterval = 30.0, leadTime: TimeInterval = 120.0) {
        self.pollInterval = pollInterval
        self.leadTime = leadTime
    }

    func start(
        onUpcoming: @escaping (CalendarMeeting) -> Void,
        onEnded: @escaping (CalendarMeeting) -> Void
    ) {
        self.onUpcomingMeeting = onUpcoming
        self.onMeetingEnded = onEnded

        requestAccess { [weak self] granted in
            guard let self = self, granted else {
                fputs("[calendar] Access denied — calendar triggers disabled\n", stderr)
                return
            }

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: self.pollInterval)
            timer.setEventHandler { [weak self] in
                self?.poll()
            }
            timer.resume()
            self.timer = timer
            fputs("[calendar] Started (polling every \(Int(self.pollInterval))s, lead time \(Int(self.leadTime))s)\n", stderr)
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        activeMeetings.removeAll()
        fputs("[calendar] Stopped\n", stderr)
    }

    private func requestAccess(completion: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { granted, error in
                if let error = error {
                    fputs("[calendar] Access error: \(error.localizedDescription)\n", stderr)
                }
                completion(granted)
            }
        } else {
            eventStore.requestAccess(to: .event) { granted, error in
                if let error = error {
                    fputs("[calendar] Access error: \(error.localizedDescription)\n", stderr)
                }
                completion(granted)
            }
        }
    }

    private func poll() {
        let now = Date()
        let windowEnd = now.addingTimeInterval(leadTime)
        let windowStart = now.addingTimeInterval(-3600 * 2) // include meetings started up to 2hrs ago

        let calendars = eventStore.calendars(for: .event)
        let predicate = eventStore.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: calendars)
        let events = eventStore.events(matching: predicate)

        for event in events {
            guard let eventID = event.calendarItemIdentifier as String? else { continue }

            // Skip already-triggered events
            if triggeredEventIDs.contains(eventID) { continue }

            // Check if this event has a meeting URL
            let meetingURL = extractMeetingURL(from: event)
            guard meetingURL != nil || isMeetingEvent(event) else { continue }

            // Check timing: is the event starting within our lead time window, or already in progress?
            let startTime = event.startDate ?? now
            let endTime = event.endDate ?? now.addingTimeInterval(3600)
            let timeUntilStart = startTime.timeIntervalSince(now)

            if timeUntilStart <= leadTime && now < endTime {
                // Meeting is upcoming or in progress
                let meeting = CalendarMeeting(
                    eventID: eventID,
                    title: event.title ?? "Untitled Meeting",
                    startTime: startTime,
                    endTime: endTime,
                    meetingURL: meetingURL,
                    calendarEmail: event.calendar.source?.title,
                    attendees: extractAttendees(from: event),
                    isBrowserBased: isBrowserMeeting(meetingURL)
                )

                triggeredEventIDs.insert(eventID)
                activeMeetings[eventID] = meeting
                fputs("[calendar] Upcoming: \"\(meeting.title)\" starts in \(Int(timeUntilStart))s\n", stderr)

                DispatchQueue.main.async { [weak self] in
                    self?.onUpcomingMeeting?(meeting)
                }
            }
        }

        // Check for ended meetings
        for (eventID, meeting) in activeMeetings {
            let buffer: TimeInterval = 300 // 5 minute buffer after end time
            if now > meeting.endTime.addingTimeInterval(buffer) {
                fputs("[calendar] Ended: \"\(meeting.title)\"\n", stderr)
                activeMeetings.removeValue(forKey: eventID)
                DispatchQueue.main.async { [weak self] in
                    self?.onMeetingEnded?(meeting)
                }
            }
        }

        // Clean up old triggered IDs (older than 24 hours)
        // This prevents the set from growing indefinitely
        if triggeredEventIDs.count > 100 {
            triggeredEventIDs.removeAll()
        }
    }

    private func extractMeetingURL(from event: EKEvent) -> String? {
        // Check URL field
        if let url = event.url?.absoluteString,
           Self.meetingURLPatterns.contains(where: { url.contains($0) }) {
            return url
        }

        // Check notes/description
        if let notes = event.notes {
            for pattern in Self.meetingURLPatterns {
                if let range = notes.range(of: pattern) {
                    // Extract the full URL around this match
                    let searchStart = notes.index(range.lowerBound, offsetBy: -30, limitedBy: notes.startIndex) ?? notes.startIndex
                    let searchEnd = notes.index(range.upperBound, offsetBy: 100, limitedBy: notes.endIndex) ?? notes.endIndex
                    let substring = String(notes[searchStart..<searchEnd])

                    // Find URL in substring
                    if let urlMatch = substring.range(of: "https?://[^\\s<>\"]+", options: .regularExpression) {
                        return String(substring[urlMatch])
                    }
                }
            }
        }

        // Check location field
        if let location = event.location {
            for pattern in Self.meetingURLPatterns {
                if location.contains(pattern) {
                    if let urlMatch = location.range(of: "https?://[^\\s<>\"]+", options: .regularExpression) {
                        return String(location[urlMatch])
                    }
                }
            }
        }

        return nil
    }

    private func isMeetingEvent(_ event: EKEvent) -> Bool {
        // Heuristic: events with attendees (other than organizer) are likely meetings
        guard let attendees = event.attendees else { return false }
        return attendees.count > 0
    }

    private func isBrowserMeeting(_ url: String?) -> Bool {
        guard let url = url else { return false }
        return url.contains("meet.google.com")
    }

    private func extractAttendees(from event: EKEvent) -> [String] {
        guard let attendees = event.attendees else { return [] }
        return attendees.compactMap { participant in
            participant.name ?? participant.url.absoluteString
        }
    }
}

/// Represents a meeting detected from the calendar
struct CalendarMeeting {
    let eventID: String
    let title: String
    let startTime: Date
    let endTime: Date
    let meetingURL: String?
    let calendarEmail: String?  // email domain → entity mapping
    let attendees: [String]
    let isBrowserBased: Bool    // true for Google Meet → capture all Chrome audio
}
