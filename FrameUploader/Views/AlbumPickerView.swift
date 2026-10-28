import AppKit
import SwiftUI

struct AlbumPickerView: View {
    let onAdd: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var albums: [PhotoAlbum] = []
    @State private var selection: Set<PhotoAlbum.ID> = []
    @State private var state: LoadState = .loading

    private enum LoadState {
        case loading, loaded, denied
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose Photos Albums")
                .font(.headline)

            Group {
                switch state {
                case .loading:
                    ProgressView("Reading your Photos library…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .denied:
                    VStack(spacing: 10) {
                        Text(PhotoLibraryError.accessDenied.localizedDescription)
                            .multilineTextAlignment(.center)
                        Button("Open Privacy Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded where albums.isEmpty:
                    Text("No albums with photos were found.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .loaded:
                    List(albums, selection: $selection) { album in
                        HStack {
                            Image(systemName: "rectangle.stack")
                                .foregroundStyle(.secondary)
                            Text(album.title)
                            Spacer()
                            Text("\(album.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .listStyle(.bordered)
                    Text("Hold ⌘ to select more than one album.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") {
                    // Keep the library's order rather than the order of clicks.
                    onAdd(albums.map(\.id).filter(selection.contains))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440, height: 500)
        .task { await load() }
    }

    private func load() async {
        guard await PhotoLibrary.requestAccess() else {
            state = .denied
            return
        }
        albums = await Task.detached(priority: .userInitiated) { PhotoLibrary.albums() }.value
        state = .loaded
    }
}
