import Charts
import DiskTraceCore
import SwiftUI

@main
struct DiskTraceApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("DiskTrace") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 480)
                .task { await model.refresh() }
        }
        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView {
            HistoryView().tabItem { Label("History", systemImage: "clock") }
            GrowthView().tabItem { Label("Growth", systemImage: "chart.bar") }
            HealthView().tabItem { Label("Health", systemImage: "heart.text.square") }
        }
        .padding()
    }
}

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Volume free space").font(.headline)
            if model.samples.isEmpty {
                Text("No samples yet.").foregroundStyle(.secondary)
            } else {
                Chart(model.samples) { sample in
                    LineMark(
                        x: .value("Time", sample.observedAt),
                        y: .value("Free bytes", sample.freeBytes))
                }
                .frame(minHeight: 220)
            }
            Text(model.status).font(.footnote).foregroundStyle(.secondary)
            Divider()
            Text("Recent alerts").font(.headline)
            if model.alerts.isEmpty {
                Text("No agent alerts — expected activity stays silent.")
                    .foregroundStyle(.secondary)
            } else {
                List(model.alerts) { alert in
                    VStack(alignment: .leading) {
                        Text(alert.reason.rawValue).font(.callout)
                        Text("class: \(alert.evidenceClass.rawValue) · \(alert.evaluatedAt, style: .time)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct GrowthView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading) {
            Text("Largest directory growth (7 days)").font(.headline)
            if model.growth.isEmpty {
                Text("No measured growth.").foregroundStyle(.secondary)
            } else {
                Table(model.growth) {
                    TableColumn("Path", value: \.pathID)
                    TableColumn("Δ allocated") { delta in
                        Text(ByteCountFormatter.string(
                            fromByteCount: delta.deltaAllocatedBytes, countStyle: .file))
                    }
                    TableColumn("Calibration") { delta in
                        Text(delta.calibration.rawValue)
                    }
                }
            }
        }
    }
}

struct HealthView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Monitoring health").font(.headline)
            Text("Database: \(model.databasePath)").font(.footnote).textSelection(.enabled)
            Text("Samples: \(model.samples.count)")
            Text("Growth rows: \(model.growth.count)")
            Text("Alerts: \(model.alerts.count)")
            Text(
                "Coverage gaps and permission state are recorded by the agent as "
                    + "CoverageGap rows and surfaced here."
            ).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            TextField("Database path", text: $model.databasePath)
            Button("Reload") { Task { await model.refresh() } }
        }
        .padding()
        .frame(width: 420)
    }
}
