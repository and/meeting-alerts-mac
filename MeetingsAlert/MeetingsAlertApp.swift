import AppKit
import ServiceManagement

/// A filled, optionally stroked rounded rect whose colours follow the effective
/// appearance.
///
/// Assigning `someDynamicColor.cgColor` to a layer freezes it: CGColor has no notion of
/// light or dark, so it keeps whichever appearance happened to be current when it was
/// resolved. Resolving inside `updateLayer()` instead - which AppKit calls with the
/// view's effective appearance current, and again whenever that changes - is what makes
/// these follow the system.
final class AlertBackgroundView: NSView {
    var fill: NSColor = .clear
    var stroke: NSColor?
    var cornerRadius: CGFloat = 0

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fill.cgColor
        layer?.cornerRadius = cornerRadius
        layer?.borderWidth = stroke == nil ? 0 : 1
        layer?.borderColor = stroke?.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

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
    /// The meeting the visible panel describes, for its Join and Snooze actions.
    private var alertPanelMeeting: Meeting?
    private var snoozeTimer: Timer?
    /// Whether the panel's attendee card is expanded past the first four.
    private var alertShowsAllAttendees = false
    /// Identifies the meeting the panel last fired for, so it shows once rather than on
    /// every refresh while the meeting sits inside the lead-time window.
    var lastAlertedMeeting: String?
    /// How far ahead of the start time the panel appears.
    static let alertLeadTime: TimeInterval = 3 * 60
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

    /// Whether Return activates the alert panel's primary button. On by default: the
    /// panel appears when a meeting is about to start, so joining is the likely intent.
    private var enterToJoinEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: "enterToJoinEnabled") as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "enterToJoinEnabled")
        }
    }

    private var scrollingEnabled: Bool {
        get {
            // Off by default; the reader opts in from Settings. Anyone who has already
            // toggled it keeps their choice, since only an absent key falls back here.
            UserDefaults.standard.object(forKey: "scrollingEnabled") as? Bool ?? false
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
        debugLog("🚀 MeetingsAlert: Application starting...")

        let fixedWidth: CGFloat = 80
        statusItem = NSStatusBar.system.statusItem(withLength: fixedWidth)
        debugLog("📊 Status item created: \(statusItem != nil)")

        if let button = statusItem?.button {
            // Use SF Symbol for calendar icon
            if let calendarImage = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Calendar") {
                // Set fixed image size to prevent shaking
                let fixedImage = NSImage(size: NSSize(width: 16, height: 16))
                fixedImage.lockFocus()
                calendarImage.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
                fixedImage.unlockFocus()
                // Drawing into a fresh NSImage loses the SF Symbol's template flag, which
                // left the glyph an untinted black bitmap. Template images are tinted by
                // the system for light/dark, menu-open inversion and accent colors.
                fixedImage.isTemplate = true

                button.image = fixedImage
                button.imagePosition = .imageLeading
                button.imageHugsTitle = true
            }
            button.title = "Load..."
            button.cell?.truncatesLastVisibleLine = true
            button.cell?.lineBreakMode = .byTruncatingTail
            debugLog("✅ Button title set to: \(button.title)")
        } else {
            debugLog("❌ Failed to get status item button!")
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
            debugLog("🔄 Calendar changed - refreshing meetings")
            self?.updateMeetingStatus()
            self?.checkForMeetingAlerts()
        }

        calendarManager?.requestAccess { [weak self] granted in
            debugLog("📆 Calendar access granted: \(granted)")
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
        debugLog("💤 System woke from sleep - updating meetings immediately")
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
            debugLog("Could not get meetings")
            return
        }

        debugLog("📋 Found \(meetings.count) meetings")

        for (index, meeting) in meetings.enumerated() {
            let status = meeting.isActive ? "ACTIVE" : "upcoming in \(meeting.minutesUntilStart)m"
            debugLog("  [\(index)] \(timeFormatter.string(from: meeting.startDate)) - \(meeting.title) (\(status))")
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
                            debugLog("⏭️ Showing next meeting instead of active one (starts in \(nextMeeting.minutesUntilStart)m)")
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
                    debugLog("🟢 Active meeting: \(displayTitle)")
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
                    debugLog("⏰ Upcoming meeting: \(displayTitle)")
                }

                self?.customButton?.tooltipText = tooltipTitle
                let truncated = String(displayTitle.prefix(8))
                button.title = truncated
            } else {
                button.title = "None"
                self?.customButton?.tooltipText = "No meetings"
                debugLog("ℹ️ No meetings found")
            }
        }
    }

    func startTimer() {
        // Check meetings every 30 seconds for optimal balance of responsiveness and efficiency
        timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.updateMeetingStatus()
            self?.checkForMeetingAlerts()
        }
        // Let the system batch this wakeup with work it was already doing. Nothing here
        // needs 30.000s precision, and an exact fire date keeps the CPU from idling.
        timer?.tolerance = 5.0
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// Shows the meeting alert panel once per meeting, shortly before it starts.
    ///
    /// Called from the 30s timer, from wake, from calendar changes and from the calendar
    /// access callback. The last two arrive on a background XPC thread, so everything that
    /// touches AppKit or mutable state is moved to the main thread first - presenting this
    /// window off the main thread throws an uncaught exception and aborts the process.
    func checkForMeetingAlerts() {
        guard let meetings = calendarManager?.getUpcomingMeetings() else { return }

        let now = Date()
        guard let due = meetings.first(where: {
            let untilStart = $0.startDate.timeIntervalSince(now)
            return untilStart > 0 && untilStart <= Self.alertLeadTime
        }) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // The start date is part of the key so that rescheduling a meeting alerts again.
            let key = "\(due.title)|\(due.startDate.timeIntervalSince1970)"
            guard self.lastAlertedMeeting != key, self.meetingAlertWindow == nil else { return }
            self.lastAlertedMeeting = key
            self.showMeetingAlert(for: due)
        }
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
                    debugLog("✅ Launch at login enabled")
                } else {
                    try SMAppService.mainApp.unregister()
                    debugLog("❌ Launch at login disabled")
                }
            } catch {
                debugLog("⚠️ Failed to update launch at login: \(error.localizedDescription)")
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

    // MARK: - Meeting alert panel
    //
    // Implements the "Meeting Alert Window" design, direction 3a ("macOS native"):
    // grouped inset cards on a window-grey ground, SF system type, hairline separators
    // inset to the text edge, circular avatars, and trailing-aligned dialog buttons.
    // The system accent carries the controls; red is reserved for the countdown, which
    // is the only element that changes as the meeting approaches.
    //
    // Sections render only when the calendar actually supplies their data, following
    // the design's own progressive disclosure (details / + call / + attendees).

    private static let alertPanelWidth: CGFloat = 420

    /// The design's window-grey ground (#ececee), with a dark counterpart.
    ///
    /// Both windowBackgroundColor and controlBackgroundColor resolve to white in light
    /// mode on current macOS, so relying on them left white cards on a white ground with
    /// only a hairline between them. This states the contrast explicitly while still
    /// adapting, and in dark mode keeps the ground lighter than the cards, as the
    /// platform does.
    private static let alertGround = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0.161, green: 0.161, blue: 0.165, alpha: 1)
            : NSColor(srgbRed: 0.925, green: 0.925, blue: 0.933, alpha: 1)
    }

    /// Adds `view` to `stack` and pins its width to the stack's, minus the stack's own
    /// insets. NSStackView's `.width` alignment does not stretch arranged subviews
    /// reliably here - without this the cards size to their content and sit trailing.
    /// A view that absorbs slack so the element after it lands on the trailing edge.
    private func alertSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return spacer
    }

    private func addFullWidth(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    /// Wraps `view` in a container that holds it off the edges by `insets`.
    ///
    /// NSStackView.edgeInsets only takes effect along the stacking axis: the top and
    /// bottom of a horizontal stack are ignored, which collapsed every row here to the
    /// height of its tallest child. Real constraints are the only reliable padding.
    private func padded(_ view: NSView, _ insets: NSEdgeInsets) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.right),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom)
        ])
        return container
    }

    private func showMeetingAlert(for meeting: Meeting) {
        alertPanelMeeting = meeting
        alertShowsAllAttendees = false

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.alertPanelWidth, height: 200),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Meeting Alert"
        window.level = .floating
        window.isReleasedWhenClosed = false

        let ground = alertContent(for: meeting)
        window.contentView = ground
        ground.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: Self.alertPanelWidth, height: ground.fittingSize.height))

        let windowDelegate = MeetingAlertWindowDelegate()
        windowDelegate.onClose = { [weak self] in
            self?.meetingAlertWindow = nil
        }
        window.delegate = windowDelegate
        objc_setAssociatedObject(window, "delegate", windowDelegate, .OBJC_ASSOCIATION_RETAIN)

        window.center()
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1.0
        }
        NSApp.activate(ignoringOtherApps: true)

        self.meetingAlertWindow = window
    }

    /// Builds the panel's whole view tree, ground included, so it can be rebuilt in place
    /// when the attendee list expands.
    private func alertContent(for meeting: Meeting) -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false

        addFullWidth(alertHeader(for: meeting), to: root)

        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 14
        body.translatesAutoresizingMaskIntoConstraints = false

        if let url = meeting.url {
            addFullWidth(alertVideoCard(url: url), to: body)
        }
        if let location = meeting.location {
            addFullWidth(alertLocationCard(location), to: body)
        }
        if !meeting.participants.isEmpty {
            addFullWidth(alertAttendeesSection(for: meeting), to: body)
        }
        // Nothing but the header - keep the ground from collapsing onto the footer.
        let bodyBottom: CGFloat = body.arrangedSubviews.isEmpty ? 4 : 12
        addFullWidth(padded(body, NSEdgeInsets(top: 0, left: 16, bottom: bodyBottom, right: 16)), to: root)

        addFullWidth(alertHairline(), to: root)
        addFullWidth(alertFooter(for: meeting), to: root)

        // The design's grouped-inset pattern needs a window-grey ground for the cards to
        // sit on; without painting it the window draws white and the cards vanish into it.
        let ground = AlertBackgroundView()
        ground.wantsLayer = true
        ground.fill = Self.alertGround
        ground.translatesAutoresizingMaskIntoConstraints = false
        ground.addSubview(root)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.alertPanelWidth),
            root.leadingAnchor.constraint(equalTo: ground.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: ground.trailingAnchor),
            root.topAnchor.constraint(equalTo: ground.topAnchor),
            root.bottomAnchor.constraint(equalTo: ground.bottomAnchor)
        ])
        return ground
    }

    /// Expands or collapses the attendee card, rebuilding the panel around the new list
    /// and growing the window downward so its title stays where the reader left it.
    @objc func toggleShowAllAttendees() {
        guard let window = meetingAlertWindow, let meeting = alertPanelMeeting else { return }
        alertShowsAllAttendees.toggle()

        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        let ground = alertContent(for: meeting)
        window.contentView = ground
        ground.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: Self.alertPanelWidth, height: ground.fittingSize.height))
        window.setFrameTopLeftPoint(topLeft)
    }

    /// Lays a transparent button over `view` so a whole composed row is clickable.
    private func clickable(_ view: NSView, action: Selector) -> NSView {
        let button = NSButton(title: "", target: self, action: action)
        button.isTransparent = true
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            button.topAnchor.constraint(equalTo: view.topAnchor),
            button.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        return view
    }

    /// App mark, title, the time/duration/calendar line, and the countdown pill.
    private func alertHeader(for meeting: Meeting) -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 52),
            icon.heightAnchor.constraint(equalToConstant: 52)
        ])

        let title = NSTextField(labelWithString: meeting.title)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 2
        title.preferredMaxLayoutWidth = Self.alertPanelWidth - 16 - 52 - 14 - 16

        var parts = ["\(timeFormatter.string(from: meeting.startDate)) – \(timeFormatter.string(from: meeting.endDate))"]
        let minutes = meeting.durationInMinutes
        parts.append(minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min")
        if !meeting.calendarTitle.isEmpty { parts.append(meeting.calendarTitle) }
        let subtitle = NSTextField(labelWithString: parts.joined(separator: " · "))
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail

        let text = NSStackView(views: [title, subtitle, alertCountdownPill(for: meeting)])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 5
        text.setCustomSpacing(8, after: subtitle)

        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 14
        return padded(row, NSEdgeInsets(top: 18, left: 16, bottom: 16, right: 16))
    }

    /// The one red element: it is what changes as the meeting approaches.
    private func alertCountdownPill(for meeting: Meeting) -> NSView {
        let minutes = meeting.minutesUntilStart
        let label = NSTextField(labelWithString: minutes <= 1 ? "Starting Now" : "Starting in \(minutes) min")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false

        let pill = AlertBackgroundView()
        pill.wantsLayer = true
        pill.fill = .systemRed
        pill.cornerRadius = 10
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor)
        ])
        return pill
    }

    private func alertVideoCard(url: URL) -> NSView {
        let name = NSTextField(labelWithString: "Video call")
        name.font = .systemFont(ofSize: 13, weight: .semibold)

        let detail = NSTextField(labelWithString: alertShortLink(url))
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail

        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        // The card states which call this is; joining is the footer's default button, so
        // that Return has one unambiguous target rather than two identical Join buttons.
        return alertCard(padded(text, NSEdgeInsets(top: 11, left: 14, bottom: 11, right: 14)))
    }

    private func alertLocationCard(_ location: String) -> NSView {
        let name = NSTextField(labelWithString: "Location")
        name.font = .systemFont(ofSize: 13, weight: .semibold)

        let detail = NSTextField(labelWithString: location)
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail

        let text = NSStackView(views: [name, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        return alertCard(padded(text, NSEdgeInsets(top: 11, left: 14, bottom: 11, right: 14)))
    }

    /// Section label plus the RSVP tally, over a card of attendee rows.
    private func alertAttendeesSection(for meeting: Meeting) -> NSView {
        let heading = NSTextField(labelWithString: "ATTENDEES")
        heading.font = .systemFont(ofSize: 11, weight: .semibold)
        heading.textColor = .secondaryLabelColor

        var tallies: [String] = []
        let accepted = meeting.participants.filter { $0.rsvp == .accepted }.count
        let declined = meeting.participants.filter { $0.rsvp == .declined }.count
        let pending = meeting.participants.filter { $0.rsvp == .pending || $0.rsvp == .tentative }.count
        if accepted > 0 { tallies.append("\(accepted) yes") }
        if declined > 0 { tallies.append("\(declined) no") }
        if pending > 0 { tallies.append("\(pending) pending") }
        let tally = NSTextField(labelWithString: tallies.joined(separator: " · "))
        tally.font = .systemFont(ofSize: 11)
        tally.textColor = .secondaryLabelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headingRow = NSStackView(views: [heading, spacer, tally])
        headingRow.orientation = .horizontal
        headingRow.alignment = .firstBaseline
        headingRow.spacing = 12

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0

        // Organiser first, then people who accepted - the order the design shows and the
        // order that answers "is this meeting actually happening" fastest.
        let ordered = meeting.participants.sorted { lhs, rhs in
            if lhs.isOrganizer != rhs.isOrganizer { return lhs.isOrganizer }
            if (lhs.rsvp == .accepted) != (rhs.rsvp == .accepted) { return lhs.rsvp == .accepted }
            // Swift's sort is not stable, so break ties by name - otherwise the same
            // meeting lists its attendees in a different order each time it alerts.
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        let collapsedLimit = 4
        let shown = alertShowsAllAttendees ? ordered : Array(ordered.prefix(collapsedLimit))
        for person in shown {
            addFullWidth(alertAttendeeRow(person), to: rows)
        }

        // The disclosure row only earns its place when there is something behind it.
        if ordered.count > collapsedLimit {
            addFullWidth(padded(alertHairline(), NSEdgeInsets(top: 0, left: 54, bottom: 0, right: 0)), to: rows)

            let remaining = ordered.count - collapsedLimit
            let more = NSTextField(labelWithString: alertShowsAllAttendees ? "Show fewer" : "Show all \(ordered.count)")
            more.font = .systemFont(ofSize: 13)
            more.textColor = .controlAccentColor
            more.setContentHuggingPriority(.defaultHigh, for: .horizontal)

            let chevron = NSTextField(labelWithString: alertShowsAllAttendees ? "\u{2039}" : "\u{203A}")
            chevron.font = .systemFont(ofSize: 15)
            chevron.textColor = .tertiaryLabelColor

            let badge = alertShowsAllAttendees ? "\u{2212}" : "+\(remaining)"
            let moreRow = NSStackView(views: [alertAvatar(badge, muted: true), more, alertSpacer(), chevron])
            moreRow.orientation = .horizontal
            moreRow.alignment = .centerY
            moreRow.spacing = 10
            let padded = padded(moreRow, NSEdgeInsets(top: 7, left: 14, bottom: 7, right: 14))
            addFullWidth(clickable(padded, action: #selector(toggleShowAllAttendees)), to: rows)
        }

        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6
        addFullWidth(padded(headingRow, NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)), to: section)
        addFullWidth(alertCard(rows), to: section)
        return section
    }

    private func alertAttendeeRow(_ person: Participant) -> NSView {
        let name = NSTextField(labelWithString: person.name)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingTail

        let text = NSStackView(views: [name])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0
        if person.isOrganizer {
            let role = NSTextField(labelWithString: "Organiser")
            role.font = .systemFont(ofSize: 11)
            role.textColor = .secondaryLabelColor
            text.addArrangedSubview(role)
        }

        let state: String
        switch person.rsvp {
        case .accepted: state = "Yes"
        case .declined: state = "No"
        case .tentative: state = "Maybe"
        case .pending: state = "No reply"
        }
        let stateLabel = NSTextField(labelWithString: state)
        stateLabel.font = .systemFont(ofSize: 12)
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.setContentHuggingPriority(.required, for: .horizontal)

        text.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let row = NSStackView(views: [alertAvatar(person.initials, muted: false), text, alertSpacer(), stateLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return padded(row, NSEdgeInsets(top: 7, left: 14, bottom: 7, right: 14))
    }

    private func alertAvatar(_ text: String, muted: Bool) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = muted ? .secondaryLabelColor : .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let circle = AlertBackgroundView()
        circle.wantsLayer = true
        circle.fill = muted ? .quaternaryLabelColor : .systemGray
        circle.cornerRadius = 15
        circle.translatesAutoresizingMaskIntoConstraints = false
        circle.addSubview(label)
        NSLayoutConstraint.activate([
            circle.widthAnchor.constraint(equalToConstant: 30),
            circle.heightAnchor.constraint(equalToConstant: 30),
            label.centerXAnchor.constraint(equalTo: circle.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: circle.centerYAnchor)
        ])
        return circle
    }

    private func alertFooter(for meeting: Meeting) -> NSView {
        let snoozeMinutes = max(1, Int((alertSnoozeDelay(for: meeting) / 60).rounded()))
        let snooze = NSButton(title: "Snooze \(snoozeMinutes) min", target: self, action: #selector(snoozeMeetingAlert))
        snooze.bezelStyle = .rounded
        snooze.font = .systemFont(ofSize: 13)

        let primary: NSButton
        if meeting.url != nil {
            primary = alertAccentButton(title: "Join", action: #selector(joinFromAlert))
        } else {
            primary = alertAccentButton(title: "Dismiss", action: #selector(dismissMeetingAlert))
        }
        // Making it the default button is what binds Return to it.
        primary.keyEquivalent = enterToJoinEnabled ? "\r" : ""

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [spacer, snooze, primary])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return padded(row, NSEdgeInsets(top: 12, left: 16, bottom: 16, right: 16))
    }

    private func alertAccentButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.bezelColor = .controlAccentColor
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
        ])
        return button
    }

    private func alertCard(_ content: NSView) -> NSView {
        let card = AlertBackgroundView()
        card.wantsLayer = true
        card.fill = .textBackgroundColor
        card.stroke = .separatorColor
        card.cornerRadius = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        return card
    }

    private func alertHairline() -> NSView {
        let line = AlertBackgroundView()
        line.wantsLayer = true
        line.fill = .separatorColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    /// Trims the scheme and any trailing slash so the link reads like the design's
    /// "meet.internal/qtr-planning" rather than a full URL.
    private func alertShortLink(_ url: URL) -> String {
        var text = url.absoluteString
        for prefix in ["https://", "http://"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if text.hasSuffix("/") { text = String(text.dropLast()) }
        return text
    }

    @objc func joinFromAlert() {
        if let url = alertPanelMeeting?.url {
            NSWorkspace.shared.open(url)
        }
        dismissMeetingAlert()
    }

    /// How long Snooze delays the panel: long enough to get out of the way, but back
    /// about a minute before the meeting starts. A fixed five minutes would always land
    /// after the start, since the panel only appears three minutes ahead of it - the
    /// button would defer the reminder past the thing it is reminding you about. Once the
    /// meeting has begun there is no start left to beat, so five minutes it is.
    private func alertSnoozeDelay(for meeting: Meeting) -> TimeInterval {
        let beforeStart = meeting.startDate.timeIntervalSinceNow - 60
        return beforeStart >= 30 ? beforeStart : 5 * 60
    }

    @objc func snoozeMeetingAlert() {
        guard let meeting = alertPanelMeeting else { return }
        let delay = alertSnoozeDelay(for: meeting)
        dismissMeetingAlert()
        snoozeTimer?.invalidate()
        snoozeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.showMeetingAlert(for: meeting)
        }
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
        let windowHeight: CGFloat = 440
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

        // Meeting alert section
        yPosition -= 20
        let alertSeparator = NSBox(frame: NSRect(x: 20, y: yPosition, width: windowWidth - 40, height: 1))
        alertSeparator.boxType = .separator
        contentView.addSubview(alertSeparator)

        yPosition -= 30
        let alertLabel = NSTextField(labelWithString: "Meeting Alert")
        alertLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        alertLabel.frame = NSRect(x: 20, y: yPosition, width: windowWidth - 40, height: 24)
        contentView.addSubview(alertLabel)

        yPosition -= 30
        let enterCheckbox = NSButton(checkboxWithTitle: "Press Return to join the meeting",
                                     target: self, action: #selector(toggleEnterToJoin(_:)))
        enterCheckbox.frame = NSRect(x: 30, y: yPosition, width: windowWidth - 60, height: 24)
        enterCheckbox.state = enterToJoinEnabled ? .on : .off
        contentView.addSubview(enterCheckbox)

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

    @objc func toggleEnterToJoin(_ sender: NSButton) {
        enterToJoinEnabled = (sender.state == .on)
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
