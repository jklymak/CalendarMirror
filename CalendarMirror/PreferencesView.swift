import SwiftUI
import EventKit
import ServiceManagement

struct PreferencesView: View {
    let eventStore: EKEventStore

    @State private var allCalendars: [EKCalendar] = []
    @State private var selectedSourceIDs: Set<String> = []
    @State private var selectedDestID: String = ""
    @State private var launchAtLogin: Bool = false

    // Separate source and destination candidates.
    // Any calendar is a valid source; only writable ones are valid destinations.
    var destCalendars: [EKCalendar] {
        allCalendars.filter { $0.allowsContentModifications }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // MARK: Source calendars (multi-select)
            Text("Source Calendars")
                .font(.headline)
            Text("Select one or more calendars to copy events from.")
                .font(.caption)
                .foregroundColor(.secondary)

            List {
                ForEach(allCalendars, id: \.calendarIdentifier) { cal in
                    Toggle(isOn: Binding(
                        get: { selectedSourceIDs.contains(cal.calendarIdentifier) },
                        set: { checked in
                            if checked {
                                selectedSourceIDs.insert(cal.calendarIdentifier)
                            } else {
                                selectedSourceIDs.remove(cal.calendarIdentifier)
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cal.title)
                            Text(cal.source.title)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .frame(height: 180)

            Divider()

            // MARK: Destination calendar (single select)
            Text("Destination Calendar")
                .font(.headline)
            Text("Events will be copied into this calendar.")
                .font(.caption)
                .foregroundColor(.secondary)

            Picker("", selection: $selectedDestID) {
                Text("— select a calendar —").tag("")
                ForEach(destCalendars, id: \.calendarIdentifier) { cal in
                    Text("\(cal.title)  (\(cal.source.title))")
                        .tag(cal.calendarIdentifier)
                }
            }
            .labelsHidden()

            Divider()

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        // If registration fails (e.g. user denied), revert the toggle
                        launchAtLogin = !enabled
                    }
                }

            HStack {
                Spacer()
                Button("Save") {
                    savePreferences()
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            allCalendars = eventStore.calendars(for: .event)
                .sorted { $0.source.title == $1.source.title
                    ? $0.title < $1.title
                    : $0.source.title < $1.source.title }
            loadPreferences()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Persistence

    func loadPreferences() {
        if let data = UserDefaults.standard.data(forKey: "sourceCalendarIdentifiers"),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            selectedSourceIDs = Set(ids)
        }
        selectedDestID = UserDefaults.standard.string(forKey: "destinationCalendarIdentifier") ?? ""
    }

    func savePreferences() {
        if let data = try? JSONEncoder().encode(Array(selectedSourceIDs)) {
            UserDefaults.standard.set(data, forKey: "sourceCalendarIdentifiers")
        }
        UserDefaults.standard.set(selectedDestID, forKey: "destinationCalendarIdentifier")
    }
}
