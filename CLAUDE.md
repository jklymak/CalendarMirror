# CalendarMirror — Project Synopsis

A macOS menu bar app (Swift/AppKit+SwiftUI) that does one-way sync from an Exchange calendar to a Google Calendar. It uses Calendar.app as the intermediary — no direct Exchange or Google API calls. The app reads Exchange events via EventKit, then writes copies into a Google Calendar that is also visible in Calendar.app. Sync is one-way only: Exchange → Google, never the reverse.

Key design points:
- Runs as an NSStatusItem (menu bar only, no Dock icon)
- Syncs events from now to 1 year forward
- Uses a SHA256 hash of source events to skip syncs when nothing has changed
- Periodic sync every 10 minutes; manual "Sync Now" in menu
- Source/destination calendars chosen in a Preferences window (SwiftUI), stored in UserDefaults
- Preferences open automatically on first launch if not configured
- Synced events are tagged in their Notes field with `[Synced from Exchange UID: ...]` to allow cleanup of orphaned events
- Logs to `~/Library/Logs/CalendarSyncApp.log` with 1 MB rotation

Distribution constraints: No Developer ID certificate, so the app cannot be notarized or distributed as a signed Developer ID build. Distribution to spouse is done by copying the .app directly out of the .xcarchive (Show Package Contents → Products/Applications/), zipping it, and sending it. Recipient will need to bypass Gatekeeper via System Settings → Privacy & Security → Open Anyway on first launch.

Current work: packaging the app for a second user (spouse), including login-item registration via `SMAppService` (macOS 13+), and removing hard-coded assumptions so it works for any user's calendar setup.

The project lives at `~/Dropbox/CalendarSync/CalendarSyncApp/` and also at `~/bin/CalendarSync`. Main source files are `AppDelegate.swift` and `PreferencesView.swift` under `CalendarMirror/`.
