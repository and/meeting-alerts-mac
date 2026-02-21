# MeetingsAlert

A lightweight macOS menu bar application that displays your upcoming calendar meetings with real-time updates and smart notifications.

## Features

- **Menu Bar Display**: Shows upcoming meetings directly in your macOS menu bar
- **Smart Meeting Selection**: Automatically switches between active and upcoming meetings based on timing
- **Real-time Updates**:
  - Refreshes every 30 seconds
  - Detects calendar changes immediately
  - Updates when system wakes from sleep
- **Meeting Alerts**: Half-screen popup notification 2 minutes before meetings start
- **Video Conference Integration**: Automatically detects and displays links for Zoom, Google Meet, Microsoft Teams, and Webex
- **Customizable Display**: Four display format options
- **Smooth Scrolling**: Optional text scrolling animation on hover (3 characters per second)
- **Instant Tooltips**: Shows full meeting details on hover without delay
- **Multi-day Support**: Shows meetings from today and tomorrow
- **Launch at Login**: Optional automatic startup
- **Memory Optimized**: Uses approximately 39MB of RAM
- **Native macOS Design**: Uses SF Symbols and AppKit for native look and feel

## Requirements

- macOS 13.0 or later
- Calendar access permission (Full Access on macOS 14+)

## Installation

1. Open `MeetingsAlert.xcodeproj` in Xcode
2. Build and run the project (⌘R)
3. Grant calendar access when prompted
4. The app will appear in your menu bar

## Usage

### Menu Bar Display

The menu bar shows your next meeting in a compact format. The exact display depends on your settings:

- **Time + Title** (default): `10:00 AM Meeting Name (30m)`
- **Title Only**: `Meeting Name`
- **Upcoming Time + Title**: `in 15m Meeting Name (30m)`
- **Upcoming Time Only**: `in 15m`

When a meeting is active, it shows time remaining: `10:00 AM Meeting Name (15m left)`

### Display Behavior

- If you have an active meeting and the next meeting starts within 30 minutes, the upcoming meeting is displayed
- Otherwise, the currently active meeting is shown
- Meetings are filtered to only show those that haven't ended

### Menu Items

Click the menu bar icon to see:

- **Next three meetings**: Clickable list of upcoming meetings (opens video conference link if available)
- **Settings**: Configure display format and scrolling animation
- **Launch at Login**: Toggle automatic startup
- **Quit**: Exit the application

### Settings

Access settings from the menu to configure:

1. **Display Format**:
   - Just the title
   - Time + Title
   - Upcoming meeting time + Title
   - Just the upcoming meeting time

2. **Scrolling Animation**: Enable/disable text scrolling on hover

### Meeting Details

Hover over the menu bar text to see a tooltip with:
- Full meeting title
- Start and end times
- Duration
- Participant names
- Video conference link (if available)

### Video Conference Integration

The app automatically detects video conference links from:
- Event URL field
- Event notes/description

Supported platforms:
- Zoom
- Google Meet
- Microsoft Teams
- Webex

Click a meeting in the dropdown menu to open its video conference link in your browser.

## Technical Details

### Architecture

- **Pure AppKit**: No SwiftUI dependency for optimal memory usage
- **EventKit Framework**: Calendar access and event management
- **ServiceManagement**: Launch at login functionality
- **NSStatusItem**: Menu bar integration
- **NotificationCenter**: Calendar change and system wake detection

### Files Structure

```
MeetingsAlert/
├── MeetingsAlertApp.swift      # Main app logic and UI
├── CalendarManager.swift       # Calendar integration and meeting data
├── Info.plist                  # App configuration
└── MeetingsAlert.entitlements  # Sandbox permissions
```

### Calendar Access

The app requires Full Access to your calendar on macOS 14+ (or regular access on earlier versions). This permission allows the app to:
- Read event titles, times, and details
- Access participant information
- Detect video conference links

The app does NOT modify your calendar in any way - it only reads event data.

### Update Mechanisms

The app updates meeting information through three mechanisms:

1. **Timer-based**: Every 30 seconds
2. **Calendar changes**: Immediate update when events are created, modified, or deleted
3. **System wake**: Immediate update when computer wakes from sleep

### Memory Optimization

The app is optimized for low memory usage:
- Pure AppKit instead of SwiftUI
- Reused DateFormatter instances
- No caching of event data
- Approximately 39MB RAM usage

## Troubleshooting

### App Not Showing Meetings

1. Check calendar access permissions in System Settings > Privacy & Security > Calendars
2. If using macOS 14+, ensure Full Access is granted (not just Write-Only)
3. Restart the app

### Calendar Access Reset

If you need to reset permissions:

```bash
tccutil reset Calendar com.meetingsalert.app
```

Then restart the app and grant permission again.

### App Disappeared After Granting Permission

This is expected behavior during first launch. Restart the app after granting calendar access.

### Meetings Not Updating

The app should update automatically through:
- Calendar change detection
- Wake from sleep detection
- 30-second timer

If meetings still don't update, quit and restart the app.

### Menu Items Greyed Out

This should not occur in the current version. If it does, restart the app.

## Known Limitations

- Only shows meetings from today and tomorrow
- Requires Full Access on macOS 14+ (Read-Only access is not sufficient for reading events)
- Only displays non-all-day events
- Menu bar display limited to 8 characters (scrolls on hover when enabled)

## Development

### Building from Source

1. Clone the repository
2. Open `MeetingsAlert.xcodeproj` in Xcode
3. Select your development team in project settings
4. Build and run

### Key Components

#### CalendarManager

Handles all calendar-related operations:
- Permission requests
- Event fetching
- Meeting data extraction
- Calendar change notifications

#### MeetingsAlertApp

Main application logic:
- Menu bar UI management
- Meeting display formatting
- Scrolling animation
- Settings management
- Alert notifications
- User interaction handling

### Custom Components

**StatusBarButton**: Custom NSView for instant tooltips without system delay

**DisplayFormat Enum**: Four display format options for user preference

**Meeting Struct**: Data model with computed properties for active status, time remaining, and duration

## Privacy

- The app only reads calendar data locally on your Mac
- No data is sent to any external servers
- Calendar access is protected by macOS sandboxing and requires explicit permission

## License

Copyright 2025. All rights reserved.

## Credits

Built with Swift and AppKit for macOS.
