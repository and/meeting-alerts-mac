# Development

Developer documentation for Meeting Alerts. For what the app does and how to use it, see
[README.md](README.md).

## Building

With Xcode: open `MeetingAlerts.xcodeproj`, select your development team, build and run.

Without Xcode — the Command Line Tools are enough, and this is how the shipped builds are
made:

```bash
./scripts/release.sh --no-notarize
```

That compiles a universal (arm64 + x86_64) binary with `swiftc`, generates the icon,
assembles the `.app`, signs it, and writes `build/MeetingAlerts.dmg`. It deliberately stops
short of the repository root so a test build cannot overwrite a shipped one.

`xcodebuild` is not used anywhere. It requires full Xcode, and the pipeline is designed to
work with only the Command Line Tools installed.

## Releasing

A locally signed build is not enough: Gatekeeper blocks unnotarized apps on other people's
Macs. The full pipeline is one command.

```bash
./scripts/release.sh                    # build, sign, notarize, staple
./scripts/release.sh --publish v1.3.0   # ...and cut the GitHub release
```

It builds, signs with the Developer ID certificate, submits to Apple's notary service,
staples the ticket, promotes the DMG to the repository root, and — with `--publish` —
creates the GitHub release and uploads the asset. The DMG itself is signed as well as the
app inside it.

`--publish` refuses to run if the build is not notarized, if the tag is malformed, or if
the release already exists. Those checks run before any compilation, so a mistake costs
nothing. Bump `MARKETING_VERSION` and `BUILD_VERSION` at the top of the script first.

### Notarization credentials

One-time setup, storing an app-specific password in the login keychain:

```bash
xcrun notarytool store-credentials MeetingsAlertNotary \
  --apple-id <your-apple-id> --team-id <your-team-id>
```

Omit `--password` and notarytool prompts for it, keeping it out of your shell history.
App-specific passwords come from [account.apple.com](https://account.apple.com) under
Sign-In and Security — not from the developer portal.

An App Store Connect API key works too and is more durable, since it survives Apple ID
password changes:

```bash
xcrun notarytool store-credentials MeetingsAlertNotary \
  --key AuthKey_XXXXXXXXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_UUID>
```

The profile name is `MeetingsAlertNotary` — it names a keychain item created before the
app was renamed, and is unrelated to the app's own name. Override it with the
`NOTARY_PROFILE` environment variable.

Requirements: an active Apple Developer Program membership and a Developer ID Application
certificate in the login keychain. The script picks the certificate up by substring match,
so it holds no personal detail; set `SIGN_IDENTITY` if you have more than one.

### Verifying a build before sharing it

```bash
xcrun stapler validate MeetingAlerts.dmg
spctl -a -vvv -t open --context context:primary-signature MeetingAlerts.dmg
```

To check it the way a downloader experiences it, mark the file quarantined first:

```bash
xattr -w com.apple.quarantine "0081;00000000;Chrome;" MeetingAlerts.dmg
```

## The app icon

`scripts/make-icon.swift` draws the icon from the design handoff's fractional geometry, so
it regenerates exactly at any raster size; `release.sh` runs it on every build. There is no
binary artwork in the repository.

The design specifies three tiers of detail. Below 48px it drops to three thickened rules
with flat fills and no shadow; at 16px the neutral block goes entirely, leaving two rules
and the accent block. Editing the icon means editing the geometry constants, not a PNG.

## Architecture

Pure AppKit, no SwiftUI, chosen for memory footprint. EventKit for calendar access,
ServiceManagement for Launch at Login, `NSStatusItem` for the menu bar.

```
MeetingAlerts/
├── MeetingAlertsApp.swift    # menu bar, alert panel, settings, app lifecycle
├── CalendarManager.swift     # EventKit access, Meeting and Participant models
├── DebugLog.swift            # logging that compiles out of release builds
├── Info.plist
└── MeetingAlerts.entitlements
```

### Refreshing

Meetings update through three paths: a 30-second timer, the `EKEventStoreChanged`
notification, and `NSWorkspace.didWakeNotification`. The timer carries a 5-second tolerance
so macOS can batch its wakeup rather than hitting an exact fire date.

### Threading

`requestFullAccessToEvents` and the calendar-change notification both deliver on a
**background XPC thread**. Everything touching AppKit or mutable state must be moved to the
main thread first. Presenting a window from that thread throws an uncaught Objective-C
exception and aborts the process — it was a real crash on the first-launch path, which
every new user hits.

### Logging

`debugLog()` compiles to nothing without `-DDEBUG`, which release builds do not define. Use
it rather than `print()`; several call sites are the only statement in a `switch` case, so
deleting them outright would not compile.

## The alert panel

Implements the "Meeting Alert Window" design, direction 3a: grouped inset cards on a
window-grey ground, SF system type, hairline separators, circular avatars, trailing-aligned
dialog buttons. The system accent drives the controls; red is reserved for the countdown,
the only element that changes as the meeting approaches.

Sections render only when the calendar supplies their data, following the design's own
progressive disclosure. The design's Agenda block is not implemented: EventKit offers only
a free-text notes field, and parsing it into agenda items would invent structure that is
not there.

Three AppKit traps are worth knowing before editing this code.

**`NSStackView.edgeInsets` only applies along the stacking axis.** The top and bottom of a
horizontal stack are silently ignored, which collapsed every row to the height of its
tallest child — 30pt where the design asks for 44. Use the `padded(_:_:)` helper, which
builds real constraints.

**A dynamic `NSColor` resolved to `CGColor` is frozen.** `CGColor` has no notion of light
or dark, so assigning `someColor.cgColor` to a layer keeps whichever appearance happened to
be current when it was resolved — which broke light mode entirely. `AlertBackgroundView`
resolves inside `updateLayer()`, which AppKit calls with the view's effective appearance
current and again whenever it changes.

**`windowBackgroundColor` and `controlBackgroundColor` are both white in light mode** on
current macOS, so relying on them for the grouped-inset pattern gives white cards on a white
ground. The panel states its ground grey explicitly, and keeps it lighter than the cards in
dark mode, as the platform does.

## Testing

There are no unit tests. The panel is verified by driving the real app: create a calendar
event a few minutes out, wait for the alert to fire, and inspect the result with
`CGWindowListCopyWindowInfo` for geometry or `screencapture -l<windowid>` for appearance.
Accessibility scripting through System Events can click the panel's buttons, which is how
Return-to-join, Show all and Snooze were checked.

Screen Recording permission is required for `screencapture` to return anything; without it
the call fails rather than producing a blank image.

## Bundle identifier

`com.meetingalerts.app`. macOS keys calendar permission, the Launch at Login registration
and all saved settings to this string, so changing it resets those for every existing user.
It is also referenced by `SMAuthorizedClients` inside `Info.plist`. Version 1.3.0 changed it
once, as part of renaming the app; there is no reason to change it again.
