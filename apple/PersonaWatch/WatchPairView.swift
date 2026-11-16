import SwiftUI
import WatchKit
import PersonaWire

struct WatchPairView: View {
    @Environment(WatchModel.self) private var model
    @State private var allDay = WatchAllDay.shared
    /// The phone's `recordingDay`: absent from a phone that doesn't take day recordings, 0 until its user agrees.
    @AppStorage(WatchSync.phoneDayKey) private var phoneDay: Int?

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Watch.blockSpacing) {
                Theme.Icon.image(Theme.Icon.handoff).font(Theme.Font.title).foregroundStyle(Theme.accent)
                if model.missing.isEmpty {
                    Text("Not paired yet").font(Theme.Font.heading)
                    Text("Once Persona on your iPhone is paired, tap Sync from iPhone below.").font(Theme.Font.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("No watch credential yet").font(Theme.Font.heading)
                    Text("When your iPhone is online, tap below to sync again.")
                        .font(Theme.Font.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                WatchSyncButton()
                // In the scroll view: beside it, it squeezed the page until the sync button was out of sight. A place, as
                // on the home list: Record is on the page it opens.
                NavigationLink { WatchRecordingView() } label: { WatchRecordingsLabel() }
                .padding(.top, Theme.Space.s)
                // Recording needs the phone, not the hub: all-day recording too, once the phone takes it (its page
                // points to the phone's consent until the user agreed there).
                if allDay.access(phoneDay: phoneDay) != .hidden {
                    NavigationLink { WatchAllDayView() } label: {
                        Label("All-Day Recording", systemImage: Theme.Icon.allDay).lineLimit(1)
                    }
                    .padding(.top, Theme.Space.s)
                }
            }
            .padding()
        }
    }
}
/// Sync from iPhone: asks the phone for the watch's credentials (it tries the hub again for the ones it has not got).
struct WatchSyncButton: View {
    @Environment(WatchModel.self) private var model
    @State private var syncing = false
    @State private var failed = false

    var body: some View {
        VStack(spacing: Theme.Watch.blockSpacing) {
            Button {
                syncing = true
                failed = false
                WatchSync.shared.requestConfig { ok in
                    syncing = false
                    failed = !ok
                    WKInterfaceDevice.current().play(ok && model.missing.isEmpty ? .success : .failure)
                }
            } label: {
                HStack {
                    if syncing { ProgressView() }
                    Text("Sync from iPhone").lineLimit(1)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(syncing)
            if failed {
                Text("Can't reach your iPhone. Open Persona on your iPhone, or tap Sync to Apple Watch in its Settings.").font(Theme.Font.label).foregroundStyle(Theme.cautionText)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
