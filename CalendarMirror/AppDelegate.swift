import Cocoa
import EventKit
import CryptoKit
import SwiftUI

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    var timer: Timer?
    var debounceTimer: Timer?
    var statusItem: NSStatusItem?
    var preferencesWindow: NSWindow?
    
    let eventStore = EKEventStore()

    let logFileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CalendarSyncApp.log")

    let maxLogSize: UInt64 = 1_000_000 // 1 MB

    func _log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fullMessage = "[\(timestamp)] \(message)\n"
        let data = fullMessage.data(using: .utf8)!

        if FileManager.default.fileExists(atPath: logFileURL.path),
           let attr = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
           let fileSize = attr[.size] as? UInt64,
           fileSize > maxLogSize {
            // Truncate file
            try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
        }

        if FileManager.default.fileExists(atPath: logFileURL.path),
           let fileHandle = try? FileHandle(forWritingTo: logFileURL) {
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
            fileHandle.closeFile()
        } else {
            try? data.write(to: logFileURL)
        }
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        self._log("App launched")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                if let button = statusItem?.button {
                    button.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Calendar Sync")
                }

                // Create the dropdown menu
                let menu = NSMenu()
                menu.addItem(NSMenuItem(title: "Sync Now", action: #selector(forceSync), keyEquivalent: "s"))
                menu.addItem(NSMenuItem.separator())
                let prefsItem = NSMenuItem(title: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
                prefsItem.target = self
                menu.addItem(prefsItem)
                let viewLogItem = NSMenuItem(title: "View Log", action: #selector(openLog), keyEquivalent: "")
                viewLogItem.target = self
                menu.addItem(viewLogItem)
                menu.addItem(NSMenuItem.separator())
                menu.addItem(NSMenuItem(title: "Quit", action: #selector(terminate), keyEquivalent: "q"))
                statusItem?.menu = menu
        
        eventStore.requestFullAccessToEvents { granted, error in
            guard granted, error == nil else {
                self._log("Permission denied: \(String(describing: error))")
                return
            }
            self._log("Got permission!")
            DispatchQueue.main.async {
                // self.setupObservers()
                self.startPeriodicSync()
                // Open preferences on first run if nothing is configured yet
                let hasSource = UserDefaults.standard.data(forKey: "sourceCalendarIdentifiers") != nil
                let hasDest = UserDefaults.standard.string(forKey: "destinationCalendarIdentifier") != nil
                if !hasSource || !hasDest {
                    self.openPreferences()
                } else {
                    self.syncCalendars()
                }
            }
        }
    }

    @objc func forceSync() {
        syncCalendars()
    }

    @objc func openPreferences() {
        if preferencesWindow == nil {
            let view = PreferencesView(eventStore: eventStore)
            let hosting = NSHostingView(rootView: view)
            hosting.autoresizingMask = [.width, .height]
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "CalendarSync Preferences"
            window.contentView = hosting
            window.center()
            window.isReleasedWhenClosed = false
            preferencesWindow = window
        }
        preferencesWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func terminate() {
        NSApplication.shared.terminate(nil)
    }
    
    @objc func openLog() {
        NSWorkspace.shared.open(logFileURL)
    }

    func setupObservers() {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(eventStoreChanged),
                name: .EKEventStoreChanged,
                object: eventStore
            )
        }
    
    @objc func eventStoreChanged(_ notification: Notification) {
        _log("Event store changed!")
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { _ in
            self.syncCalendars()
            }
            
        }

    func startPeriodicSync() {
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            self._log("Running fallback sync...")
            self.syncCalendars()
        }
    }

    
    func hashEvents(_ events: [EKEvent]) -> String {
        let eventStrings = events
            .sorted(by: { $0.eventIdentifier < $1.eventIdentifier })
            .map {
                "\($0.eventIdentifier ?? "nil")|\($0.title ?? "nil")|\($0.startDate.timeIntervalSinceReferenceDate)|\($0.endDate.timeIntervalSinceReferenceDate)|\($0.lastModifiedDate?.timeIntervalSinceReferenceDate ?? 0)"
            }
            .joined(separator: "\n")
        
        let data = Data(eventStrings.utf8)
        return sha256(data: data)
    }

    func sha256(data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
    
    func syncCalendars() {
        // Load calendar selections from Preferences
        guard let sourceData = UserDefaults.standard.data(forKey: "sourceCalendarIdentifiers"),
              let sourceIDs = try? JSONDecoder().decode([String].self, from: sourceData),
              !sourceIDs.isEmpty else {
            _log("No source calendars configured. Open Preferences to set them up.")
            return
        }
        guard let destID = UserDefaults.standard.string(forKey: "destinationCalendarIdentifier"),
              !destID.isEmpty else {
            _log("No destination calendar configured. Open Preferences to set it up.")
            return
        }

        let allCals = eventStore.calendars(for: .event)
        let sourceCals = allCals.filter { sourceIDs.contains($0.calendarIdentifier) }
        guard !sourceCals.isEmpty else {
            _log("Source calendar(s) not found — they may have been removed from Calendar.app.")
            return
        }
        guard let googleCal = allCals.first(where: { $0.calendarIdentifier == destID }) else {
            _log("Destination calendar not found — it may have been removed from Calendar.app.")
            return
        }
        
        
        let hashFileURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".calendarSyncHash")

        func loadPreviousHash() -> String? {
            return try? String(contentsOf: hashFileURL, encoding: .utf8)
        }

        func saveCurrentHash(_ hash: String) {
            try? hash.write(to: hashFileURL, atomically: true, encoding: .utf8)
        }
        

        let now = Date()
        let oneYear = Calendar.current.date(byAdding: .year, value: 1, to: now)!
        let predicate = eventStore.predicateForEvents(withStart: now, end: oneYear, calendars: sourceCals)
        let exchangeEvents = eventStore.events(matching: predicate)

        let exchangeUIDs = Set(exchangeEvents.map { $0.eventIdentifier })
        
        let newHash = hashEvents(exchangeEvents)

        if let previousHash = loadPreviousHash(), previousHash == newHash {
            self._log("No changes detected. Skipping sync.")
            //DispatchQueue.main.async {
            //    NSApp.terminate(nil)
            //}
            return
        }
        
        _log("Changes detected. Syncing...")
        saveCurrentHash(newHash)
        
        let predicateG = eventStore.predicateForEvents(withStart: now, end: oneYear, calendars: [googleCal])
        let googleEvents = eventStore.events(matching: predicateG)
        for gEvent in googleEvents {
            // do {
            //        try eventStore.remove(event, span: .thisEvent)
            //    self._log("Removed event: \(event.title ?? "Untitled")")
            //    } catch {
            //        self._log("Error removing event: \(error)")
            //    }
            guard let notes = gEvent.notes,
                      notes.contains("[Synced from Exchange UID:") else { continue }

                if let match = notes.range(of: #"UID: (.+?)]"#, options: .regularExpression),
                   let uid = String(notes[match]).components(separatedBy: "UID: ").last?.replacingOccurrences(of: "]", with: ""),
                   !exchangeUIDs.contains(uid) {
                    try? eventStore.remove(gEvent, span: .thisEvent)
                    _log("Deleted orphaned event: \(gEvent.title ?? "Untitled")")
                }
            }

        for event in exchangeEvents {
            let pred = eventStore.predicateForEvents(withStart: event.startDate, end: event.endDate, calendars: [googleCal])
            let googleEvents = eventStore.events(matching: pred)
            
            // Look for the event in Google Calendar using the UID in the notes
            let existingGoogleEvent = googleEvents.first { gEvent in
                guard let notes = gEvent.notes else { return false }
                return notes.contains("[Synced from Exchange UID: \(event.eventIdentifier ?? "")]")
            }

            if let existingEvent = existingGoogleEvent {
                // If the event exists, check if the start/end date has changed
                if existingEvent.startDate != event.startDate || existingEvent.endDate != event.endDate {
                    // Update the event
                    existingEvent.startDate = event.startDate
                    existingEvent.endDate = event.endDate
                    existingEvent.title = event.title
                    existingEvent.notes = "[Synced from Exchange UID: \(event.eventIdentifier ?? "")]"
                    
                    do {
                        try eventStore.save(existingEvent, span: .thisEvent)
                        self._log("Updated event: \(event.title ?? "Untitled")")
                    } catch {
                        self._log("Error updating event: \(error)")
                    }
                } else {
                    // If no changes, just skip it
                    // self._log("No changes to event: \(event.title ?? "Untitled")")
                }
            } else {
                // If no matching event, create a new one
                let newEvent = EKEvent(eventStore: eventStore)
                newEvent.calendar = googleCal
                newEvent.title = event.title
                newEvent.startDate = event.startDate
                newEvent.endDate = event.endDate
                newEvent.notes = "[Synced from Exchange UID: \(event.eventIdentifier ?? "")]"

                do {
                    try eventStore.save(newEvent, span: .thisEvent)
                    self._log("Synced new event: \(event.title ?? "Untitled")")
                } catch {
                    self._log("Error saving new event: \(error)")
                }
            }
        }

        
        _log("Sync complete.")
        //DispatchQueue.main.async {
        //    NSApp.terminate(nil)
        //}
    }

    func applicationWillTerminate(_ aNotification: Notification) {}

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }
}

