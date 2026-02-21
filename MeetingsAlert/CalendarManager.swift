import Foundation
import EventKit

struct Meeting {
    let title: String
    let startDate: Date
    let endDate: Date
    let url: URL?
    let notes: String?
    let attendees: [String]

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
        print("📅 Calendar database changed - events updated externally")
        onCalendarChanged?()
    }

    func requestAccess(completion: @escaping (Bool) -> Void) {
        if #available(macOS 14.0, *) {
            let status = EKEventStore.authorizationStatus(for: .event)
            print("📋 Current authorization status: \(status.rawValue)")

            switch status {
            case .fullAccess:
                print("✅ Already have full access")
                self.hasAccess = true
                completion(true)
            case .writeOnly:
                print("⚠️ Have write-only access (cannot read events)")
                self.hasAccess = false
                completion(false)
            case .notDetermined:
                print("❓ Permission not determined, requesting full access...")
                eventStore.requestFullAccessToEvents { granted, error in
                    print("📆 Permission granted: \(granted)")
                    self.hasAccess = granted
                    if let error = error {
                        print("❌ Calendar access error: \(error.localizedDescription)")
                    }
                    completion(granted)
                }
            case .denied:
                print("🚫 Permission denied by user")
                self.hasAccess = false
                completion(false)
            case .restricted:
                print("🔒 Permission restricted by system policy")
                self.hasAccess = false
                completion(false)
            @unknown default:
                print("❓ Unknown authorization status")
                self.hasAccess = false
                completion(false)
            }
        } else {
            eventStore.requestAccess(to: .event) { granted, error in
                self.hasAccess = granted
                if let error = error {
                    print("Calendar access error: \(error.localizedDescription)")
                }
                completion(granted)
            }
        }
    }

    func getUpcomingMeetings() -> [Meeting] {
        guard hasAccess else {
            print("❌ No calendar access")
            return []
        }

        let now = Date()

        // Refresh cache every time to ensure we get the latest meetings
        let startOfDay = Calendar.current.startOfDay(for: now)
        let endOfTomorrow = Calendar.current.date(byAdding: .day, value: 2, to: startOfDay) ?? now

        print("🔍 Searching for events from \(startOfDay) to \(endOfTomorrow)")

        // Get all available calendars
        let calendars = eventStore.calendars(for: .event)
        print("📚 Available calendars: \(calendars.count)")
        for cal in calendars {
            print("  Calendar: \(cal.title) - Type: \(cal.type.rawValue)")
        }

        let predicate = eventStore.predicateForEvents(withStart: startOfDay, end: endOfTomorrow, calendars: nil)
        let events = eventStore.events(matching: predicate)

        print("📅 Found \(events.count) total events in calendar")
        for event in events {
            print("  Event: \(event.title ?? "Untitled") - Start: \(event.startDate ?? Date()) - End: \(event.endDate ?? Date()) - AllDay: \(event.isAllDay) - Calendar: \(event.calendar?.title ?? "Unknown")")
        }

        let meetings = events.compactMap { event -> Meeting? in
            guard !event.isAllDay, let start = event.startDate, let end = event.endDate else {
                return nil
            }

            // Only include meetings that haven't ended yet
            guard end > now else {
                print("⏭️ Skipping ended meeting: \(event.title ?? "Untitled") (ended at \(end))")
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

            return Meeting(title: event.title ?? "Untitled", startDate: start, endDate: end, url: videoURL, notes: event.notes, attendees: attendeeNames)
        }

        let sortedMeetings = meetings.sorted { $0.startDate < $1.startDate }

        print("📊 Returning \(sortedMeetings.count) valid meetings")

        return sortedMeetings
    }
}
