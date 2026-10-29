import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            TVSettingsView()
                .tabItem { Label("TV", systemImage: "tv") }
            DisplaySettingsView()
                .tabItem { Label("Art Mode", systemImage: "photo.artframe") }
            UploadSettingsView()
                .tabItem { Label("Uploads", systemImage: "arrow.up.circle") }
        }
        .frame(width: 520)
        .padding(.vertical, 8)
    }
}

private struct TVSettingsView: View {
    @AppStorage(SettingsKey.tvHost) private var tvHost = ""
    @State private var testState: TestState = .idle
    @State private var showingFinder = false

    private enum TestState {
        case idle
        case testing(String)
        case success(String)
        case failure(String)
    }

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("TV IP address", text: $tvHost, prompt: Text("e.g. 192.168.1.50"))
                        .onSubmit { tvHost = AppSettings.normalizedHost(tvHost) }
                    Button("Find Automatically…") { showingFinder = true }
                }
                Text("To find the IP address yourself:\n\n" + TVHelp.findIPAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    Button("Connect & Pair") {
                        Task { await testConnection() }
                    }
                    .disabled(tvHost.isEmpty || isTesting)
                    Button("Forget Pairing") {
                        TokenStore.remove(for: AppSettings.normalizedHost(tvHost))
                        testState = .idle
                    }
                    .disabled(tvHost.isEmpty || isTesting)
                }
                statusView
                Text("The first time you connect, the TV asks whether to allow “Frame Uploader”. Choose Allow with your TV remote. The TV must be on or in Art Mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingFinder) {
            VStack(alignment: .leading, spacing: 16) {
                TVFinderView { host in
                    tvHost = host
                    testState = .idle
                    showingFinder = false
                }
                HStack {
                    Spacer()
                    Button("Cancel") { showingFinder = false }
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(24)
            .frame(width: 500)
        }
    }

    private var isTesting: Bool {
        if case .testing = testState { return true }
        return false
    }

    @ViewBuilder
    private var statusView: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing(let message):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(message)
            }
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func testConnection() async {
        let host = AppSettings.normalizedHost(tvHost)
        tvHost = host
        testState = .testing("Looking for the TV…")
        do {
            let info = try await TVDeviceInfo.fetch(host: host)
            guard info.isFrameTV else {
                testState = .failure("Found “\(info.displayName)”, but it doesn't report Art Mode support. Is this a Frame TV?")
                return
            }

            testState = .testing("Connecting… Check your TV and choose Allow if asked.")
            let client = try await FrameArtClient.connected(to: host)
            let version = (try? await client.apiVersion()) ?? "unknown"
            if let mattes = try? await client.matteOptions(), !mattes.types.isEmpty {
                // Only offer mats that suit a full-screen 16:9 photo.
                let suitable = mattes.types.filter { !["panoramic", "triptych", "mix", "squares"].contains($0) }
                UserDefaults.standard.set(suitable, forKey: SettingsKey.tvMatteTypes)
                if !mattes.colors.isEmpty {
                    UserDefaults.standard.set(mattes.colors, forKey: SettingsKey.tvMatteColors)
                }
            }
            await client.disconnect()

            var model = ""
            if let modelName = info.device?.modelName {
                model = " (\(modelName))"
            }
            testState = .success("Connected to \(info.displayName)\(model). Art Mode API \(version).")
        } catch {
            testState = .failure(error.localizedDescription)
        }
    }
}

private struct DisplaySettingsView: View {
    @AppStorage(SettingsKey.matteType) private var matteType = AppSettings.defaultMatteType
    @AppStorage(SettingsKey.matteColor) private var matteColor = AppSettings.defaultMatteColor
    @AppStorage(SettingsKey.slideshowEnabled) private var slideshowEnabled = AppSettings.defaultSlideshowEnabled
    @AppStorage(SettingsKey.slideshowMinutes) private var slideshowMinutes = AppSettings.defaultSlideshowMinutes
    @AppStorage(SettingsKey.slideshowShuffle) private var slideshowShuffle = AppSettings.defaultSlideshowShuffle

    var body: some View {
        Form {
            Section("Mat") {
                Picker("Style", selection: $matteType) {
                    ForEach(withCurrent(Matte.availableTypes, matteType), id: \.self) { type in
                        Text(Matte.displayName(type)).tag(type)
                    }
                }
                Picker("Color", selection: $matteColor) {
                    ForEach(withCurrent(Matte.availableColors, matteColor), id: \.self) { color in
                        Text(Matte.displayName(color)).tag(color)
                    }
                }
                .disabled(matteType == "none")
                Text("“None” shows each photo edge to edge. With a mat, the TV shrinks the photo to sit inside a border. Changing this also updates photos already on the TV the next time you upload them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Slideshow") {
                Toggle("Start a slideshow after uploading", isOn: $slideshowEnabled)
                Picker("Change photo", selection: $slideshowMinutes) {
                    ForEach(SlideshowInterval.options) { option in
                        Text(option.label).tag(option.minutes)
                    }
                }
                .disabled(!slideshowEnabled)
                Toggle("Shuffle", isOn: $slideshowShuffle)
                    .disabled(!slideshowEnabled)
                Text("The slideshow cycles through everything in the TV's My Photos. Turn on “Replace my previous upload” to keep it to your latest batch. When the slideshow is off, the TV shows the first uploaded photo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// Keeps a saved choice selectable even if the TV's list doesn't include it.
    private func withCurrent(_ options: [String], _ current: String) -> [String] {
        options.contains(current) ? options : options + [current]
    }
}

private struct UploadSettingsView: View {
    @AppStorage(SettingsKey.tvHost) private var tvHost = ""
    @AppStorage(SettingsKey.skipDuplicates) private var skipDuplicates = AppSettings.defaultSkipDuplicates
    @AppStorage(SettingsKey.replacePrevious) private var replacePrevious = AppSettings.defaultReplacePrevious
    @ObservedObject private var registry = UploadRegistry.shared
    @State private var confirmingForget = false

    private var host: String { AppSettings.normalizedHost(tvHost) }

    var body: some View {
        Form {
            Section {
                Toggle("Skip photos already on the TV", isOn: $skipDuplicates)
                Text("Photos are recognized by their contents, so renamed or moved files are still skipped.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Replace my previous upload", isOn: $replacePrevious)
                Text("After uploading, removes photos this app put on the TV earlier that aren't part of the new batch. Photos you added any other way are never removed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Upload history") {
                LabeledContent("Photos uploaded by this app", value: "\(registry.records(for: host).count)")
                Button("Forget Upload History…") { confirmingForget = true }
                    .disabled(registry.records(for: host).isEmpty)
                Text("Forgetting the history leaves the photos on the TV, but this app will no longer recognize or remove them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Forget the upload history for this TV?", isPresented: $confirmingForget) {
            Button("Forget History", role: .destructive) { registry.forget(host: host) }
        }
    }
}
