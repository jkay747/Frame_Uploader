import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var coordinator: UploadCoordinator
    @AppStorage(SettingsKey.tvHost) private var tvHost = ""
    @AppStorage(SettingsKey.skipDuplicates) private var skipDuplicates = AppSettings.defaultSkipDuplicates
    @AppStorage(SettingsKey.replacePrevious) private var replacePrevious = AppSettings.defaultReplacePrevious
    @State private var showingAlbumPicker = false
    @State private var isDropTargeted = false
    @State private var showingTVSetup = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if coordinator.items.isEmpty {
                    emptyState
                } else {
                    PhotoGrid()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                coordinator.add(urls: urls)
                return true
            } isTargeted: { isDropTargeted = $0 }

            Divider()
            bottomBar
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: chooseFolders) {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                }
                .help("Add folders of photos (subfolders included)")
                Button {
                    showingAlbumPicker = true
                } label: {
                    Label("Add Photos Album", systemImage: "photo.on.rectangle.angled")
                }
                .help("Add albums from Apple Photos")
                Button(role: .destructive) {
                    coordinator.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .help("Remove all photos from this list")
                .disabled(coordinator.items.isEmpty || coordinator.isWorking)
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("TV, mat and slideshow settings")
            }
        }
        .sheet(isPresented: $showingTVSetup) {
            TVSetupSheet()
        }
        .task {
            // First launch: look for the TV before asking the user for anything.
            if tvHost.isEmpty { showingTVSetup = true }
        }
        .sheet(isPresented: $showingAlbumPicker) {
            AlbumPickerView { albumIDs in
                coordinator.addAlbums(albumIDs)
            }
        }
        .alert(
            coordinator.summary?.title ?? "",
            isPresented: Binding(
                get: { coordinator.summary != nil },
                set: { if !$0 { coordinator.summary = nil } }
            )
        ) {
            if (coordinator.summary?.failed ?? 0) > 0, coordinator.failedCount > 0 {
                Button("Retry Failed") { coordinator.retryFailed() }
            }
            Button("OK") {}
        } message: {
            Text(coordinator.summary?.message ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.stack")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop folders of photos here")
                .font(.title2.weight(.semibold))
            Text("Landscape photos are cropped to fill the screen around faces and subjects.\nPortrait photos are shown whole on a blurred background.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack {
                Button("Choose Folders…", action: chooseFolders)
                Button("Choose Photos Albums…") { showingAlbumPicker = true }
            }
            .controlSize(.large)
            if coordinator.isScanning {
                ProgressView("Finding photos…")
                    .controlSize(.small)
            }
        }
        .padding(40)
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                if tvHost.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                        Text("No TV set up yet.")
                        Button("Find My TV…") { showingTVSetup = true }
                            .buttonStyle(.link)
                    }
                } else {
                    Text(coordinator.statusText.isEmpty ? "TV: \(tvHost)" : coordinator.statusText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                if coordinator.isWorking {
                    ProgressView(value: coordinator.progress)
                        .frame(maxWidth: 320)
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Skip photos already on the TV", isOn: $skipDuplicates)
                Toggle("Replace my previous upload", isOn: $replacePrevious)
                    .help("Removes photos this app uploaded earlier that aren't in this batch. Other photos on the TV are never touched.")
            }
            .toggleStyle(.checkbox)
            .disabled(coordinator.isWorking)

            if coordinator.isWorking {
                Button("Stop") { coordinator.cancelUpload() }
                    .controlSize(.large)
            } else {
                if coordinator.failedCount > 0 {
                    Button("Retry \(coordinator.failedCount) Failed") { coordinator.retryFailed() }
                        .controlSize(.large)
                        .help("Upload only the photos marked with a warning. Previous uploads are left in place.")
                }
                Button {
                    coordinator.startUpload()
                } label: {
                    Label(uploadButtonTitle, systemImage: "tv")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(coordinator.includedCount == 0 || tvHost.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var uploadButtonTitle: String {
        let count = coordinator.includedCount
        return count == 0 ? "Upload to TV" : "Upload \(count) Photo\(count == 1 ? "" : "s")"
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, .image]
        panel.prompt = "Add"
        panel.message = "Choose folders (subfolders are included) or individual photos."
        if panel.runModal() == .OK {
            coordinator.add(urls: panel.urls)
        }
    }
}

private struct PhotoGrid: View {
    @EnvironmentObject private var coordinator: UploadCoordinator

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 300), spacing: 14)], spacing: 18) {
                ForEach(coordinator.items) { item in
                    PhotoCell(item: item)
                        .onTapGesture { coordinator.toggleIncluded(item.id) }
                        .contextMenu {
                            Button(item.isIncluded ? "Don't Upload This Photo" : "Upload This Photo") {
                                coordinator.toggleIncluded(item.id)
                            }
                            if case .file(let url) = item.origin {
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            }
                            Divider()
                            Button("Remove from List", role: .destructive) {
                                coordinator.remove(item.id)
                            }
                        }
                }
            }
            .padding(16)

            Text("Previews show exactly what the TV will display. Click a photo to leave it out.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)
        }
    }
}

private struct PhotoCell: View {
    @EnvironmentObject private var coordinator: UploadCoordinator
    let item: PhotoItem
    @State private var preview: PhotoPreview?
    @State private var loadFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.15))
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        if let preview {
                            Image(nsImage: preview.image)
                                .resizable()
                                .aspectRatio(16.0 / 9.0, contentMode: .fill)
                        } else if loadFailed {
                            Image(systemName: "photo.badge.exclamationmark")
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        if !item.isIncluded {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.black.opacity(0.55))
                                .overlay {
                                    Label("Skipped", systemImage: "eye.slash")
                                        .foregroundStyle(.white)
                                }
                        }
                    }

                StatusBadge(status: item.status)
                    .padding(6)
            }

            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let reason = item.status.failureReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(reason)
                            .textSelection(.enabled)
                    } else {
                        Text(item.group)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let preview {
                    Label(preview.mode.label, systemImage: preview.mode.systemImage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }
        }
        .contentShape(Rectangle())
        .task(id: item.id) {
            let loaded = await coordinator.previews.preview(for: item)
            if !Task.isCancelled {
                preview = loaded
                loadFailed = loaded == nil
            }
        }
    }
}

private struct StatusBadge: View {
    let status: UploadStatus

    var body: some View {
        switch status {
        case .pending:
            EmptyView()
        case .waiting:
            badge("clock", .secondary, help: "Waiting")
        case .preparing, .uploading:
            ProgressView()
                .controlSize(.small)
                .padding(4)
                .background(.thinMaterial, in: Circle())
                .help(status == .uploading ? "Uploading" : "Preparing")
        case .uploaded:
            badge("checkmark.circle.fill", .green, help: "Uploaded")
        case .alreadyOnTV:
            badge("checkmark.circle", .blue, help: "Already on the TV")
        case .failed(let message):
            badge("exclamationmark.triangle.fill", .orange, help: message)
        }
    }

    private func badge(_ symbol: String, _ color: Color, help: String) -> some View {
        Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(color)
            .padding(3)
            .background(.thinMaterial, in: Circle())
            .help(help)
    }
}
