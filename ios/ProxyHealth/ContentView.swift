import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section("Apple Health") {
                    if model.isAuthorized {
                        Label("Access requested", systemImage: "heart.text.square.fill")
                            .foregroundStyle(.pink)
                    }
                    Button(model.isAuthorized ? "Review Health access" : "Connect Apple Health") {
                        Task { await model.requestAuthorization() }
                    }
                }

                Section("Server") {
                    LabeledContent("URL", value: model.settings.serverURL)
                    LabeledContent("Token", value: model.settings.token.isEmpty ? "Not set" : "••••••")
                    if let connection = model.connection {
                        Text(connection).font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("Test connection") { Task { await model.testConnection() } }
                }

                Section("Sync") {
                    Button {
                        Task { await model.syncNow() }
                    } label: {
                        HStack {
                            Text(model.isSyncing ? "Syncing…" : "Sync now")
                            Spacer()
                            if model.isSyncing { ProgressView() }
                        }
                    }
                    .disabled(model.isSyncing || !model.isAuthorized || !model.settings.isConfigured)

                    if let date = model.lastSyncAt {
                        LabeledContent("Last sync", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let report = model.lastReport {
                        LabeledContent("Samples", value: "\(report.samples)")
                        LabeledContent("Workouts", value: "\(report.workouts)")
                        LabeledContent("Days summarised", value: "\(report.days)")
                        if !report.errors.isEmpty {
                            LabeledContent("Warnings", value: "\(report.errors.count)")
                        }
                    }
                    if let error = model.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }

                if !model.log.isEmpty {
                    Section("Activity") {
                        ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption.monospaced())
                        }
                    }
                }
            }
            .navigationTitle("Proxy Health")
            .toolbar {
                Button("Settings", systemImage: "gearshape") { showSettings = true }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(settings: model.settings)
            }
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var settings: SyncSettings
    @State private var confirmReset = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://your-server.run.app", text: $settings.serverURL)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API token", text: $settings.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server")
                } footer: {
                    Text("Token must match an entry in the server's API_TOKENS.")
                }

                Section {
                    Stepper("Raw samples: \(settings.sampleBackfillDays) days", value: $settings.sampleBackfillDays, in: 1...365)
                    Stepper("Daily summaries & workouts: \(settings.dailyBackfillDays) days", value: $settings.dailyBackfillDays, in: 7...1825, step: 30)
                } header: {
                    Text("First-sync history")
                } footer: {
                    Text("Raw heart-rate history is large; longer windows mean more Firestore writes.")
                }

                Section {
                    Button("Re-sync everything", role: .destructive) { confirmReset = true }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.saveSettings(settings)
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Forget sync progress and upload the history window again?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Re-sync", role: .destructive) { model.resetSync() }
            }
        }
    }
}

#Preview {
    ContentView().environment(AppModel())
}
