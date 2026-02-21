import AppKit
import ServiceManagement

class MeetingAlertWindowDelegate: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return true
    }
}

@main
class MeetingsAlertApp: NSObject, NSApplicationDelegate {
    private var appDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = MeetingsAlertApp()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        appDelegate = AppDelegate()
        appDelegate?.applicationDidFinishLaunching(notification)
    }
}

class StatusBarButton: NSView {
    weak var appDelegate: AppDelegate?
    private var tooltipWindow: NSWindow?
    var tooltipText: String = ""

    override func mouseEntered(with event: NSEvent) {
        appDelegate?.handleMouseEntered()
        showInstantTooltip()
    }

    override func mouseExited(with event: NSEvent) {
        appDelegate?.handleMouseExited()
        hideInstantTooltip()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    private func showInstantTooltip() {
        guard !tooltipText.isEmpty else { return }

        let label = NSTextField(labelWithString: tooltipText)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .labelColor
        label.backgroundColor = .clear
        label.sizeToFit()

        let padding: CGFloat = 6
        let contentRect = NSRect(
            x: 0, y: 0,
            width: label.frame.width + padding * 2,
            height: label.frame.height + padding * 2
        )

        let window = NSWindow(
            contentRect: contentRect,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        window.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.95)
        window.isOpaque = false
        window.level = .statusBar
        window.hasShadow = true

        let contentView = NSView(frame: contentRect)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.95).cgColor
        contentView.layer?.cornerRadius = 4

        label.frame.origin = NSPoint(x: padding, y: padding)
        contentView.addSubview(label)

        window.contentView = contentView

        // Position below the status item
        if let button = appDelegate?.statusItem?.button,
           let buttonWindow = button.window {
            let buttonFrame = button.convert(button.bounds, to: nil)
            let screenFrame = buttonWindow.convertToScreen(buttonFrame)
            let tooltipX = screenFrame.midX - contentRect.width / 2
            let tooltipY = screenFrame.minY - contentRect.height - 8
            window.setFrameOrigin(NSPoint(x: tooltipX, y: tooltipY))
        }

        window.orderFront(nil)
        tooltipWindow = window
    }

    private func hideInstantTooltip() {
        guard let window = tooltipWindow else { return }
        window.orderOut(nil)
        DispatchQueue.main.async { [weak window] in
            window?.close()
        }
        tooltipWindow = nil
    }
}

enum DisplayFormat: Int {
    case titleOnly = 0
    case timeAndTitle = 1
    case upcomingTimeAndTitle = 2
    case upcomingTimeOnly = 3

    var description: String {
        switch self {
        case .titleOnly: return "Just the title"
        case .timeAndTitle: return "Time + Title"
        case .upcomingTimeAndTitle: return "Upcoming meeting time + Title"
        case .upcomingTimeOnly: return "Just the upcoming meeting time"
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var calendarManager: CalendarManager?
    var timer: Timer?
    var scrollTimer: Timer?
    var meetingAlertWindow: NSWindow?
    var lastAlertedMeeting: String?
    var customButton: StatusBarButton?
    var settingsWindow: NSWindow?

    // Reuse formatter to reduce allocations
    private lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    private var displayFormat: DisplayFormat {
        get {
            DisplayFormat(rawValue: UserDefaults.standard.integer(forKey: "displayFormat")) ?? .timeAndTitle
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "displayFormat")
            updateMeetingStatus()
        }
    }

    private var scrollingEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "scrollingEnabled") as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "scrollingEnabled")
        }
    }

    private lazy var mediumTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter
    }()

    private var launchAtLogin: Bool {
        get {
            UserDefaults.standard.bool(forKey: "launchAtLogin")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "launchAtLogin")
            updateLoginItem(enabled: newValue)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 MeetingsAlert: Application starting...")

        let fixedWidth: CGFloat = 80
        statusItem = NSStatusBar.system.statusItem(withLength: fixedWidth)
        print("📊 Status item created: \(statusItem != nil)")

        if let button = statusItem?.button {
            // Use SF Symbol for calendar icon
            if let calendarImage = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Calendar") {
                // Set fixed image size to prevent shaking
                let fixedImage = NSImage(size: NSSize(width: 16, height: 16))
                fixedImage.lockFocus()
                calendarImage.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
                fixedImage.unlockFocus()

                button.image = fixedImage
                button.imagePosition = .imageLeading
                button.imageHugsTitle = true
            }
            button.title = "Load..."
            button.cell?.truncatesLastVisibleLine = true
            button.cell?.lineBreakMode = .byTruncatingTail
            print("✅ Button title set to: \(button.title)")
        } else {
            print("❌ Failed to get status item button!")
        }

        // Register for wake from sleep notifications
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(receivedWakeNotification),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        calendarManager = CalendarManager()

        // Set up calendar change callback
        calendarManager?.onCalendarChanged = { [weak self] in
            print("🔄 Calendar changed - refreshing meetings")
            self?.updateMeetingStatus()
            self?.checkForMeetingAlerts()
        }

        calendarManager?.requestAccess { [weak self] granted in
            print("📆 Calendar access granted: \(granted)")
            if granted {
                self?.updateMeetingStatus()
                self?.checkForMeetingAlerts()
                self?.startTimer()
            } else {
                DispatchQueue.main.async {
                    self?.statusItem?.button?.title = "No Cal"
                }
            }
        }

        if let button = statusItem?.button {
            button.action = #selector(statusBarButtonClicked)
            button.target = self

            let customView = StatusBarButton(frame: button.frame)
            customView.appDelegate = self
            customButton = customView
            button.addSubview(customView)
        }
    }

    @objc func receivedWakeNotification() {
        print("💤 System woke from sleep - updating meetings immediately")
        updateMeetingStatus()
        checkForMeetingAlerts()
    }

    func handleMouseEntered() {
        if scrollingEnabled, let fullTitle = customButton?.tooltipText, !fullTitle.isEmpty {
            animateScrollingText(fullTitle)
        }
    }

    func handleMouseExited() {
        stopScrolling()
        updateMeetingStatus()
    }

    func stopScrolling() {
        if let button = statusItem?.button, let layer = button.layer {
            layer.removeAllAnimations()
        }
        scrollTimer?.invalidate()
        scrollTimer = nil
    }

    func animateScrollingText(_ text: String) {
        guard let button = statusItem?.button else { return }
        let displayWidth = 8

        if text.count <= displayWidth {
            button.title = text
            return
        }

        // Stop any existing animation
        stopScrolling()

        let extendedText = text + "     "
        let totalChars = extendedText.count

        // Use character-based scrolling with consistent timing
        let charsPerSecond: Double = 3.0 // Characters per second
        let intervalPerChar = 1.0 / charsPerSecond

        var currentPosition = 0

        scrollTimer = Timer.scheduledTimer(withTimeInterval: intervalPerChar, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            var displayText = ""
            for i in 0..<displayWidth {
                let charIndex = (currentPosition + i) % totalChars
                let index = extendedText.index(extendedText.startIndex, offsetBy: charIndex)
                displayText.append(extendedText[index])
            }

            // Use attributed string for more stable rendering
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.menuBarFont(ofSize: 0)
            ]
            let attrString = NSAttributedString(string: displayText, attributes: attributes)
            button.attributedTitle = attrString

            currentPosition = (currentPosition + 1) % totalChars
        }

        // Add to common run loop mode to prevent pausing during UI interactions
        if let timer = scrollTimer {
            RunLoop.current.add(timer, forMode: .common)
        }
    }

    @objc func statusBarButtonClicked() {
        let menu = NSMenu()

        let hasAccess = calendarManager != nil
        let accessItem = NSMenuItem(title: "Calendar Access", action: nil, keyEquivalent: "")
        if hasAccess {
            if let checkImage = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Access granted") {
                accessItem.image = checkImage
            }
        } else {
            if let xImage = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: "No access") {
                accessItem.image = xImage
            }
        }
        menu.addItem(accessItem)

        menu.addItem(NSMenuItem.separator())

        if let meetings = calendarManager?.getUpcomingMeetings() {
            if meetings.isEmpty {
                menu.addItem(NSMenuItem(title: "No upcoming meetings", action: nil, keyEquivalent: ""))
            } else {
                let headerItem = NSMenuItem(title: "Next 3 Meetings:", action: nil, keyEquivalent: "")
                if let calendarImage = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Calendar") {
                    headerItem.image = calendarImage
                }
                menu.addItem(headerItem)

                for meeting in meetings.prefix(3) {
                    let title = meeting.displayString(with: timeFormatter)
                    let meetingItem = NSMenuItem(title: title, action: #selector(openMeetingFromMenu(_:)), keyEquivalent: "")
                    meetingItem.target = self
                    meetingItem.representedObject = meeting

                    // Add icon if there's a URL
                    if meeting.url != nil {
                        if let linkImage = NSImage(systemSymbolName: "link", accessibilityDescription: "Video Link") {
                            meetingItem.image = linkImage
                        }
                    }

                    menu.addItem(meetingItem)
                }
            }
        } else {
            menu.addItem(NSMenuItem(title: "Loading...", action: nil, keyEquivalent: ""))
        }

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = launchAtLogin ? .on : .off
        menu.addItem(launchItem)

        let refreshItem = NSMenuItem(title: "Refresh", action: #selector(updateMeetingStatus), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc func updateMeetingStatus() {
        guard let meetings = calendarManager?.getUpcomingMeetings() else {
            print("⚠️ Could not get meetings")
            // Show debug alert
            let alert = NSAlert()
            alert.messageText = "Debug: Could not get meetings"
            alert.informativeText = "Calendar access may not be granted"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        print("📋 Found \(meetings.count) meetings")

        // Show debug alert with meeting count
        let alert = NSAlert()
        alert.messageText = "Debug: Found \(meetings.count) meetings"
        if meetings.isEmpty {
            alert.informativeText = "No meetings found in the calendar"
        } else {
            var details = ""
            for (i, m) in meetings.prefix(3).enumerated() {
                details += "\(i+1). \(m.title) at \(timeFormatter.string(from: m.startDate))\n"
            }
            alert.informativeText = details
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
        for (index, meeting) in meetings.enumerated() {
            let status = meeting.isActive ? "ACTIVE" : "upcoming in \(meeting.minutesUntilStart)m"
            print("  [\(index)] \(timeFormatter.string(from: meeting.startDate)) - \(meeting.title) (\(status))")
        }

        DispatchQueue.main.async { [weak self] in
            guard let button = self?.statusItem?.button else { return }

            // Prefer upcoming meetings over active ones if the next meeting is within 30 minutes
            var displayMeeting: Meeting?

            if let firstMeeting = meetings.first {
                // If first meeting is active, check if there's an upcoming one soon
                if firstMeeting.isActive {
                    // Check if there's a next meeting coming up soon (within 30 minutes)
                    if meetings.count > 1 {
                        let nextMeeting = meetings[1]
                        if nextMeeting.minutesUntilStart <= 30 {
                            displayMeeting = nextMeeting
                            print("⏭️ Showing next meeting instead of active one (starts in \(nextMeeting.minutesUntilStart)m)")
                        } else {
                            displayMeeting = firstMeeting
                        }
                    } else {
                        displayMeeting = firstMeeting
                    }
                } else {
                    displayMeeting = firstMeeting
                }
            }

            if let nextMeeting = displayMeeting {
                guard let format = self?.displayFormat else { return }
                let displayTitle: String
                let tooltipTitle: String
                let meetingTime = self?.timeFormatter.string(from: nextMeeting.startDate) ?? ""

                if nextMeeting.isActive {
                    let minutesRemaining = nextMeeting.minutesRemaining
                    let timeLeft = minutesRemaining >= 60 ? "\(minutesRemaining / 60)h \(minutesRemaining % 60)m" : "\(minutesRemaining)m"

                    // Tooltip always shows full details
                    tooltipTitle = "\(meetingTime) \(nextMeeting.title) (\(timeLeft) left)"

                    // Display title varies by format
                    switch format {
                    case .titleOnly:
                        displayTitle = "\(nextMeeting.title) (\(timeLeft) left)"
                    case .timeAndTitle:
                        displayTitle = "\(meetingTime) \(nextMeeting.title) (\(timeLeft) left)"
                    case .upcomingTimeAndTitle:
                        displayTitle = "\(timeLeft) left - \(nextMeeting.title)"
                    case .upcomingTimeOnly:
                        displayTitle = "\(timeLeft) left"
                    }
                    print("🟢 Active meeting: \(displayTitle)")
                } else {
                    let minutesUntil = nextMeeting.minutesUntilStart
                    let duration = nextMeeting.durationInMinutes

                    let timeUntil = minutesUntil >= 60 ? "\(minutesUntil / 60)h \(minutesUntil % 60)m" : "\(minutesUntil)m"
                    let durationStr = duration >= 60 ? "\(duration / 60)h \(duration % 60)m" : "\(duration)m"

                    // Tooltip always shows full details
                    tooltipTitle = "\(meetingTime) \(nextMeeting.title) in \(timeUntil) (\(durationStr))"

                    // Display title varies by format
                    switch format {
                    case .titleOnly:
                        displayTitle = "\(nextMeeting.title) in \(timeUntil)"
                    case .timeAndTitle:
                        displayTitle = "\(meetingTime) \(nextMeeting.title) in \(timeUntil) (\(durationStr))"
                    case .upcomingTimeAndTitle:
                        displayTitle = "in \(timeUntil) - \(nextMeeting.title)"
                    case .upcomingTimeOnly:
                        displayTitle = "in \(timeUntil)"
                    }
                    print("⏰ Upcoming meeting: \(displayTitle)")
                }

                self?.customButton?.tooltipText = tooltipTitle
                let truncated = String(displayTitle.prefix(8))
                button.title = truncated
            } else {
                button.title = "None"
                self?.customButton?.tooltipText = "No meetings"
                print("ℹ️ No meetings found")
            }
        }
    }

    func startTimer() {
        // Check meetings every 30 seconds for optimal balance of responsiveness and efficiency
        timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.updateMeetingStatus()
            self?.checkForMeetingAlerts()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func checkForMeetingAlerts() {
        // Alerts disabled
        return
    }

    @objc func openMeetingFromMenu(_ sender: NSMenuItem) {
        guard let meeting = sender.representedObject as? Meeting else { return }

        if let url = meeting.url {
            NSWorkspace.shared.open(url)
        } else {
            // If no URL, show the meeting alert
            showMeetingAlert(for: meeting)
        }
    }

    @objc func toggleLaunchAtLogin() {
        launchAtLogin.toggle()
    }

    private func updateLoginItem(enabled: Bool) {
        let appPath = Bundle.main.bundlePath

        // Check if app is in a temporary/development location
        if appPath.contains("DerivedData") || appPath.contains("/var/folders/") {
            DispatchQueue.main.async { [weak self] in
                let alert = NSAlert()
                alert.messageText = "Install App First"
                alert.informativeText = "To enable Launch at Login, please copy the app to your Applications folder first.\n\nYou can do this by running:\ncp -r '\(appPath)' /Applications/"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()

                // Reset the preference
                UserDefaults.standard.set(false, forKey: "launchAtLogin")
            }
            return
        }

        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                    print("✅ Launch at login enabled")
                } else {
                    try SMAppService.mainApp.unregister()
                    print("❌ Launch at login disabled")
                }
            } catch {
                print("⚠️ Failed to update launch at login: \(error.localizedDescription)")
                showLoginItemError(error.localizedDescription)
            }
        } else {
            // Fallback for older macOS versions
            let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.meetingsalert.app"
            if enabled {
                SMLoginItemSetEnabled(bundleIdentifier as CFString, true)
            } else {
                SMLoginItemSetEnabled(bundleIdentifier as CFString, false)
            }
        }
    }

    private func showLoginItemError(_ message: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Launch at Login Error"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func showMeetingAlert(for meeting: Meeting) {
        // Create a modern, elegant window
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame

        let windowWidth: CGFloat = 480
        let windowHeight: CGFloat = 560
        let windowX = screenFrame.midX - windowWidth / 2
        let windowY = screenFrame.midY - windowHeight / 2

        let windowFrame = NSRect(x: windowX, y: windowY, width: windowWidth, height: windowHeight)

        let window = NSWindow(contentRect: windowFrame,
                            styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered,
                            defer: false)

        window.title = ""
        window.titlebarAppearsTransparent = true
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true

        // Set window delegate to handle close
        let windowDelegate = MeetingAlertWindowDelegate()
        windowDelegate.onClose = { [weak self] in
            self?.meetingAlertWindow = nil
        }
        window.delegate = windowDelegate
        // Retain delegate with the window
        objc_setAssociatedObject(window, "delegate", windowDelegate, .OBJC_ASSOCIATION_RETAIN)

        // Create content view with visual effect background
        let visualEffectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 16
        visualEffectView.layer?.masksToBounds = true

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))

        // Header with gradient background
        let headerView = NSView(frame: NSRect(x: 0, y: windowHeight - 140, width: windowWidth, height: 140))
        headerView.wantsLayer = true

        let gradientLayer = CAGradientLayer()
        gradientLayer.frame = headerView.bounds
        gradientLayer.colors = [
            NSColor.systemBlue.withAlphaComponent(0.3).cgColor,
            NSColor.systemPurple.withAlphaComponent(0.2).cgColor
        ]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = CGPoint(x: 1, y: 1)
        headerView.layer?.addSublayer(gradientLayer)
        contentView.addSubview(headerView)

        // Calendar icon using SF Symbol
        if let calendarImage = NSImage(systemSymbolName: "calendar.badge.clock", accessibilityDescription: nil) {
            let iconView = NSImageView(image: calendarImage)
            iconView.frame = NSRect(x: windowWidth/2 - 32, y: windowHeight - 110, width: 64, height: 64)
            iconView.contentTintColor = .systemBlue
            iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 64, weight: .regular)
            contentView.addSubview(iconView)
        }

        // "Starting Soon" badge
        let badgeView = NSView(frame: NSRect(x: windowWidth/2 - 80, y: windowHeight - 165, width: 160, height: 28))
        badgeView.wantsLayer = true
        badgeView.layer?.backgroundColor = NSColor.systemBlue.cgColor
        badgeView.layer?.cornerRadius = 14

        let minutesUntil = meeting.minutesUntilStart
        let badgeText = minutesUntil <= 1 ? "Starting Now" : "Starting in \(minutesUntil) min"
        let badgeLabel = NSTextField(labelWithString: badgeText)
        badgeLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        badgeLabel.textColor = .white
        badgeLabel.alignment = .center
        badgeLabel.frame = NSRect(x: 0, y: 5, width: 160, height: 18)
        badgeView.addSubview(badgeLabel)
        contentView.addSubview(badgeView)

        // Meeting time with clock icon
        let timeContainer = NSView(frame: NSRect(x: 40, y: windowHeight - 220, width: windowWidth - 80, height: 40))

        if let clockImage = NSImage(systemSymbolName: "clock.fill", accessibilityDescription: nil) {
            let clockIcon = NSImageView(image: clockImage)
            clockIcon.frame = NSRect(x: timeContainer.bounds.width/2 - 60, y: 8, width: 24, height: 24)
            clockIcon.contentTintColor = .secondaryLabelColor
            clockIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)
            timeContainer.addSubview(clockIcon)
        }

        let timeLabel = NSTextField(labelWithString: mediumTimeFormatter.string(from: meeting.startDate))
        timeLabel.font = NSFont.monospacedSystemFont(ofSize: 28, weight: .semibold)
        timeLabel.alignment = .center
        timeLabel.frame = NSRect(x: timeContainer.bounds.width/2 - 25, y: 0, width: 200, height: 40)
        timeContainer.addSubview(timeLabel)
        contentView.addSubview(timeContainer)

        // Meeting title with subtle background
        let titleContainer = NSView(frame: NSRect(x: 30, y: windowHeight - 310, width: windowWidth - 60, height: 80))
        titleContainer.wantsLayer = true
        titleContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.5).cgColor
        titleContainer.layer?.cornerRadius = 12

        let titleLabel = NSTextField(labelWithString: meeting.title)
        titleLabel.font = NSFont.systemFont(ofSize: 22, weight: .medium)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 2
        titleLabel.frame = NSRect(x: 15, y: 15, width: titleContainer.bounds.width - 30, height: 50)
        titleContainer.addSubview(titleLabel)
        contentView.addSubview(titleContainer)

        // Duration with icon
        let duration = meeting.durationInMinutes
        let durationStr = duration >= 60 ? "\(duration / 60)h \(duration % 60)m" : "\(duration)m"

        let durationContainer = NSView(frame: NSRect(x: windowWidth/2 - 80, y: windowHeight - 355, width: 160, height: 30))

        if let timerImage = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil) {
            let timerIcon = NSImageView(image: timerImage)
            timerIcon.frame = NSRect(x: 30, y: 5, width: 20, height: 20)
            timerIcon.contentTintColor = .tertiaryLabelColor
            timerIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            durationContainer.addSubview(timerIcon)
        }

        let durationLabel = NSTextField(labelWithString: durationStr)
        durationLabel.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        durationLabel.alignment = .center
        durationLabel.textColor = .secondaryLabelColor
        durationLabel.frame = NSRect(x: 55, y: 5, width: 80, height: 22)
        durationContainer.addSubview(durationLabel)
        contentView.addSubview(durationContainer)

        // Participants section with improved layout
        var currentY: CGFloat = windowHeight - 400
        if !meeting.attendees.isEmpty {
            let participantsContainer = NSView(frame: NSRect(x: 30, y: currentY - 90, width: windowWidth - 60, height: 90))
            participantsContainer.wantsLayer = true
            participantsContainer.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.3).cgColor
            participantsContainer.layer?.cornerRadius = 10

            if let peopleImage = NSImage(systemSymbolName: "person.2.fill", accessibilityDescription: nil) {
                let peopleIcon = NSImageView(image: peopleImage)
                peopleIcon.frame = NSRect(x: 12, y: 58, width: 24, height: 24)
                peopleIcon.contentTintColor = .systemBlue
                peopleIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
                participantsContainer.addSubview(peopleIcon)
            }

            let participantsTitle = NSTextField(labelWithString: "Participants")
            participantsTitle.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            participantsTitle.textColor = .secondaryLabelColor
            participantsTitle.frame = NSRect(x: 42, y: 62, width: participantsContainer.bounds.width - 54, height: 18)
            participantsContainer.addSubview(participantsTitle)

            let participantsText = meeting.attendees.prefix(5).joined(separator: ", ") + (meeting.attendees.count > 5 ? " +\(meeting.attendees.count - 5) more" : "")
            let participantsField = NSTextField(wrappingLabelWithString: participantsText)
            participantsField.font = NSFont.systemFont(ofSize: 13)
            participantsField.textColor = .labelColor
            participantsField.maximumNumberOfLines = 2
            participantsField.lineBreakMode = .byTruncatingTail
            participantsField.frame = NSRect(x: 12, y: 10, width: participantsContainer.bounds.width - 24, height: 45)
            participantsContainer.addSubview(participantsField)

            contentView.addSubview(participantsContainer)
            currentY -= 100
        }

        // Action buttons at the bottom
        let buttonY: CGFloat = 20
        let buttonWidth: CGFloat = 180
        let buttonHeight: CGFloat = 44

        if let meetingURL = meeting.url {
            // Join button (primary action)
            let joinButton = NSButton(frame: NSRect(x: windowWidth/2 - buttonWidth - 10, y: buttonY, width: buttonWidth, height: buttonHeight))
            joinButton.title = "Join Meeting"
            joinButton.bezelStyle = .rounded
            joinButton.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
            joinButton.contentTintColor = .white
            joinButton.isBordered = true
            joinButton.wantsLayer = true
            joinButton.layer?.backgroundColor = NSColor.systemBlue.cgColor
            joinButton.layer?.cornerRadius = 10

            let joinAction = {
                NSWorkspace.shared.open(meetingURL)
                window.close()
            }

            joinButton.target = self
            joinButton.action = #selector(dismissMeetingAlert)

            // Store the action
            objc_setAssociatedObject(joinButton, "joinAction", joinAction as Any, .OBJC_ASSOCIATION_RETAIN)

            // Override the action to call our closure
            let originalAction = joinButton.action
            joinButton.action = #selector(executeJoinAction(_:))

            contentView.addSubview(joinButton)

            // Dismiss button
            let dismissButton = NSButton(frame: NSRect(x: windowWidth/2 + 10, y: buttonY, width: buttonWidth, height: buttonHeight))
            dismissButton.title = "Dismiss"
            dismissButton.bezelStyle = .rounded
            dismissButton.font = NSFont.systemFont(ofSize: 15, weight: .medium)
            dismissButton.target = self
            dismissButton.action = #selector(dismissMeetingAlert)
            dismissButton.wantsLayer = true
            dismissButton.layer?.cornerRadius = 10
            dismissButton.layer?.borderWidth = 1
            dismissButton.layer?.borderColor = NSColor.separatorColor.cgColor
            contentView.addSubview(dismissButton)
        } else {
            // Just a dismiss button centered
            let dismissButton = NSButton(frame: NSRect(x: windowWidth/2 - buttonWidth/2, y: buttonY, width: buttonWidth, height: buttonHeight))
            dismissButton.title = "OK"
            dismissButton.bezelStyle = .rounded
            dismissButton.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
            dismissButton.target = self
            dismissButton.action = #selector(dismissMeetingAlert)
            dismissButton.wantsLayer = true
            dismissButton.layer?.backgroundColor = NSColor.systemBlue.cgColor
            dismissButton.layer?.cornerRadius = 10
            dismissButton.contentTintColor = .white
            contentView.addSubview(dismissButton)
        }

        visualEffectView.addSubview(contentView)
        window.contentView = visualEffectView
        window.center()

        // Animate window appearance
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
        })

        NSApp.activate(ignoringOtherApps: true)

        // Store window reference
        self.meetingAlertWindow = window
    }

    @objc func executeJoinAction(_ sender: NSButton) {
        if let action = objc_getAssociatedObject(sender, "joinAction") as? (() -> Void) {
            action()
        }
    }

    @objc func dismissMeetingAlert() {
        meetingAlertWindow?.close()
        meetingAlertWindow = nil
    }

    @objc func showSettings() {
        // If settings window already exists, just bring it to front
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create settings window
        let windowWidth: CGFloat = 400
        let windowHeight: CGFloat = 310
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))

        // Title
        let titleLabel = NSTextField(labelWithString: "Display Format")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.frame = NSRect(x: 20, y: windowHeight - 50, width: windowWidth - 40, height: 24)
        contentView.addSubview(titleLabel)

        // Radio buttons for display format
        var yPosition: CGFloat = windowHeight - 80

        for i in 0..<4 {
            let radio = NSButton(radioButtonWithTitle: DisplayFormat(rawValue: i)?.description ?? "", target: self, action: #selector(displayFormatChanged(_:)))
            radio.frame = NSRect(x: 30, y: yPosition, width: windowWidth - 60, height: 24)
            radio.tag = i
            radio.state = (i == displayFormat.rawValue) ? .on : .off
            contentView.addSubview(radio)
            yPosition -= 30
        }

        // Separator line
        yPosition -= 20
        let separator = NSBox(frame: NSRect(x: 20, y: yPosition, width: windowWidth - 40, height: 1))
        separator.boxType = .separator
        contentView.addSubview(separator)

        // Animation settings section
        yPosition -= 30
        let animationLabel = NSTextField(labelWithString: "Animation")
        animationLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        animationLabel.frame = NSRect(x: 20, y: yPosition, width: windowWidth - 40, height: 24)
        contentView.addSubview(animationLabel)

        // Enable scrolling checkbox
        yPosition -= 30
        let scrollingCheckbox = NSButton(checkboxWithTitle: "Enable text scrolling on hover", target: self, action: #selector(toggleScrolling(_:)))
        scrollingCheckbox.frame = NSRect(x: 30, y: yPosition, width: windowWidth - 60, height: 24)
        scrollingCheckbox.state = scrollingEnabled ? .on : .off
        contentView.addSubview(scrollingCheckbox)

        // Close button
        let closeButton = NSButton(frame: NSRect(x: windowWidth - 90, y: 20, width: 70, height: 32))
        closeButton.title = "Close"
        closeButton.bezelStyle = .rounded
        closeButton.target = self
        closeButton.action = #selector(closeSettings)
        contentView.addSubview(closeButton)

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
    }

    @objc func displayFormatChanged(_ sender: NSButton) {
        displayFormat = DisplayFormat(rawValue: sender.tag) ?? .timeAndTitle

        // Update all radio buttons in the settings window
        if let contentView = settingsWindow?.contentView {
            for subview in contentView.subviews {
                if let button = subview as? NSButton, button.tag < 4 {
                    button.state = (button.tag == sender.tag) ? .on : .off
                }
            }
        }
    }

    @objc func toggleScrolling(_ sender: NSButton) {
        scrollingEnabled = (sender.state == .on)
    }

    @objc func closeSettings() {
        settingsWindow?.close()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
