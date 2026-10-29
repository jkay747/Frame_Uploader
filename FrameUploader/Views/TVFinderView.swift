import AppKit
import SwiftUI

/// Searches the network for Frame TVs and lets the user pick one, or type an IP address if none is found.
struct TVFinderView: View {
    /// Called with the chosen TV's address.
    let onChoose: (String) -> Void

    @State private var state: SearchState = .searching
    @State private var manualHost = ""

    private enum SearchState {
        case searching
        case found([DiscoveredTV])
        case notFound
        case localNetworkDenied
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch state {
            case .searching:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Looking for your Frame TV on the network…")
                }
                Text("Make sure the TV is on or in Art Mode. If your Mac asks to find devices on your local network, click Allow.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            case .found(let tvs):
                Text(tvs.count == 1 ? "Found your Frame TV:" : "Found \(tvs.count) Frame TVs. Choose one:")
                ForEach(tvs) { tv in
                    Button {
                        onChoose(tv.host)
                    } label: {
                        HStack {
                            Image(systemName: "tv")
                            VStack(alignment: .leading) {
                                Text(tv.name)
                                Text([tv.model, tv.host].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Use This TV")
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                Button("Search Again") { Task { await search() } }
                    .buttonStyle(.link)
                manualEntry(intro: "Not the right TV? Enter its IP address instead.")

            case .notFound:
                Label("Couldn't find a Frame TV on your network.", systemImage: "exclamationmark.magnifyingglass")
                    .font(.headline)
                Text("Check that the TV is on and connected to the same network as this Mac, then search again, or enter the TV's IP address below.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Search Again") { Task { await search() } }
                manualEntry(intro: "To find your TV's IP address:")

            case .localNetworkDenied:
                Label("macOS is blocking access to your local network.", systemImage: "network.slash")
                    .font(.headline)
                Text("Frame Uploader needs permission to reach devices on your home network to find and talk to the TV.")
                    .fixedSize(horizontal: false, vertical: true)
                Text("1. Open System Settings › Privacy & Security › Local Network.\n2. Turn on Frame Uploader.\n3. Quit and reopen Frame Uploader, then search again.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("If Frame Uploader isn't in that list, or it is already on, the copy you just built may not have been approved yet. See “Local network access” in the README.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Local Network Settings") {
                        NSWorkspace.shared.open(LocalNetworkAccess.settingsURL)
                    }
                    Button("Search Again") { Task { await search() } }
                }
            }
        }
        .task { await search() }
    }

    private func manualEntry(intro: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.vertical, 4)
            Text(intro)
                .font(.subheadline.weight(.semibold))
            Text(TVHelp.findIPAddress)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack {
                TextField("TV IP address", text: $manualHost, prompt: Text("e.g. 192.168.1.50"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(useManualHost)
                Button("Use This Address", action: useManualHost)
                    .disabled(AppSettings.normalizedHost(manualHost).isEmpty)
            }
        }
    }

    private func useManualHost() {
        let host = AppSettings.normalizedHost(manualHost)
        guard !host.isEmpty else { return }
        onChoose(host)
    }

    private func search() async {
        state = .searching
        let result = await TVDiscovery.findFrameTVs()
        if !result.tvs.isEmpty {
            state = .found(result.tvs)
        } else if result.localNetworkDenied {
            state = .localNetworkDenied
        } else {
            state = .notFound
        }
    }
}

/// Shown at launch when no TV has been set up yet.
struct TVSetupSheet: View {
    @AppStorage(SettingsKey.tvHost) private var tvHost = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set Up Your Frame TV")
                .font(.title2.weight(.semibold))
            TVFinderView { host in
                tvHost = host
                dismiss()
            }
            HStack {
                Spacer()
                Button("Not Now") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}
