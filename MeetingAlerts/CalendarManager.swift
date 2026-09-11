import Foundation
import EventKit

/// A person invited to a meeting, with how they replied.
struct Participant {
    enum RSVP {
        case accepted, declined, tentative, pending
    }

    let name: String
    let rsvp: RSVP
    let isOrganizer: Bool

    /// Up to two letters for the avatar, taken from the name's word initials and
    /// falling back to the first characters of a single-word name or address.
    var initials: String {
        let words = name.split(separator: " ").filter { !$0.isEmpty }
        if words.count >= 2 {
            return (words[0].prefix(1) + words[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }
}

struct Meeting {
    let title: String
    let startDate: Date
    let endDate: Date
    let url: URL?
    let notes: String?
    let attendees: [String]
    let calendarTitle: String
    let location: String?
    let participants: [Participant]

    @inline(__always)
    var isActive: Bool {
        let now = Date()
        return now >= startDate && now < endDate
    }

    @inline(__always)
    var minutesUntilStart: Int {
        max(0, Int(startDate.timeIntervalSinceNow / 60))
    }

    @inline(__always)
    var durationInMinutes: Int {
        Int(endDate.timeIntervalSince(startDate) / 60)
    }

    @inline(__always)
    var minutesRemaining: Int {
        max(0, Int(endDate.timeIntervalSinceNow / 60))
    }

    func displayString(with formatter: DateFormatter) -> String {
        let duration = durationInMinutes >= 60 ? "\(durationInMinutes / 60)h \(durationInMinutes % 60)m" : "\(durationInMinutes)m"

        if isActive {
            let timeRemaining = minutesRemaining >= 60 ? "\(minutesRemaining / 60)h \(minutesRemaining % 60)m" : "\(minutesRemaining)m"
            return "\(formatter.string(from: startDate)) \(title) (\(timeRemaining) left)"
        } else {
            return "\(formatter.string(from: startDate)) \(title) (\(duration))"
        }
    }
}

class CalendarManager {
    private let eventStore = EKEventStore()
    private var hasAccess = false
    var onCalendarChanged: (() -> Void)?

    init() {
        // Register for calendar change notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(calendarChanged),
            name: .EKEventStoreChanged,
            object: eventStore
        )
    }

    @objc private func calendarChanged() {
        debugLog("📅 Calendar database changed - events updated externally")
        onCalendarChanged?()
    }

    func requestAccess(completion: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            let status = EKEventStore.authorizationStatus(for: .event)
            debugLog("📋 Current authorization status: \(status.rawValue)")

            switch status {
            case .fullAccess:
                debugLog("✅ Already have full access")
                self.hasAccess = true
                completion(true)
            case .writeOnly:
                debugLog("⚠️ Have write-only access (cannot read events)")
                self.hasAccess = false
                completion(false)
            case .notDetermined:
                debugLog("❓ Permission not determined, requesting full access...")
                eventStore.requestFullAccessToEvents { granted, error in
                    debugLog("📆 Permission granted: \(granted)")
                    self.hasAccess = granted
                    if let error = error {
                        debugLog("❌ Calendar access error: \(error.localizedDescription)")
                    }
                    completion(granted)
                }
            case .denied:
                debugLog("🚫 Permission denied by user")
                self.hasAccess = false
                completion(false)
            case .restricted:
                debugLog("🔒 Permission restricted by system policy")
                self.hasAccess = false
                completion(false)
            @unknown default:
                debugLog("❓ Unknown authorization status")
                self.hasAccess = false
                completion(false)
            }
        } else {
            eventStore.requestAccess(to: .event) { granted, error in
                self.hasAccess = granted
                if let error = error {
                    debugLog("Calendar access error: \(error.localizedDescription)")
                }
                completion(granted)
            }
        }
    }

    func getUpcomingMeetings() -> [Meeting] {
        guard hasAccess else {
            debugLog("❌ No calendar access")
            return []
        }

        let now = Date()

        // Refresh cache every time to ensure we get the latest meetings
        let startOfDay = Calendar.current.startOfDay(for: now)
        let endOfTomorrow = Calendar.current.date(byAdding: .day, value: 2, to: startOfDay) ?? now

        debugLog("🔍 Searching for events from \(startOfDay) to \(endOfTomorrow)")

        // Get all available calendars
        let calendars = eventStore.calendars(for: .event)
        debugLog("📚 Available calendars: \(calendars.count)")
        for cal in calendars {
            debugLog("  Calendar: \(cal.title) - Type: \(cal.type.rawValue)")
        }

        let predicate = eventStore.predicateForEvents(withStart: startOfDay, end: endOfTomorrow, calendars: nil)
        let events = eventStore.events(matching: predicate)

        debugLog("📅 Found \(events.count) total events in calendar")
        for event in events {
            debugLog("  Event: \(event.title ?? "Untitled") - Start: \(event.startDate ?? Date()) - End: \(event.endDate ?? Date()) - AllDay: \(event.isAllDay) - Calendar: \(event.calendar?.title ?? "Unknown")")
        }

        let meetings = events.compactMap { event -> Meeting? in
            guard !event.isAllDay, let start = event.startDate, let end = event.endDate else {
                return nil
            }

            // Only include meetings that haven't ended yet
            guard end > now else {
                debugLog("⏭️ Skipping ended meeting: \(event.title ?? "Untitled") (ended at \(end))")
                return nil
            }

            // Extract video conference URL from event
            var videoURL: URL? = nil

            // Check the event URL first
            if let eventURL = event.url {
                videoURL = eventURL
            }

            // Also check notes/description for common video conference links
            if videoURL == nil, let notes = event.notes {
                let patterns = [
                    "https://[\\w.-]*zoom\\.us/[^\\s]+",
                    "https://[\\w.-]*meet\\.google\\.com/[^\\s]+",
                    "https://teams\\.microsoft\\.com/[^\\s]+",
                    "https://[\\w.-]*webex\\.com/[^\\s]+"
                ]

                for pattern in patterns {
                    if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                       let match = regex.firstMatch(in: notes, range: NSRange(notes.startIndex..., in: notes)),
                       let range = Range(match.range, in: notes) {
                        if let url = URL(string: String(notes[range])) {
                            videoURL = url
                            break
                        }
                    }
                }
            }

            // Extract attendee names
            let attendeeNames = event.attendees?.compactMap { attendee -> String? in
                // Get the name or email
                if let name = attendee.name, !name.isEmpty {
                    return name
                } else {
                    let email = attendee.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                    return email.isEmpty ? nil : email
                }
            } ?? []

            let organizerName = event.organizer?.name
            let participants = event.attendees?.compactMap { attendee -> Participant? in
                let name: String
                if let attendeeName = attendee.name, !attendeeName.isEmpty {
                    name = attendeeName
                } else {
                    let email = attendee.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                    guard !email.isEmpty else { return nil }
                    name = email
                }

                let rsvp: Participant.RSVP
                switch attendee.participantStatus {
                case .accepted: rsvp = .accepted
                case .declined: rsvp = .declined
                case .tentative: rsvp = .tentative
                default: rsvp = .pending
                }

                return Participant(name: name, rsvp: rsvp,
                                   isOrganizer: organizerName != nil && name == organizerName)
            } ?? []

            let location = event.location.flatMap { $0.isEmpty ? nil : $0 }

            return Meeting(title: event.title ?? "Untitled", startDate: start, endDate: end,
                           url: videoURL, notes: event.notes, attendees: attendeeNames,
                           calendarTitle: event.calendar?.title ?? "", location: location,
                           participants: participants)
        }

        let sortedMeetings = meetings.sorted { $0.startDate < $1.startDate }

        debugLog("📊 Returning \(sortedMeetings.count) valid meetings")

        return sortedMeetings
    }
}
