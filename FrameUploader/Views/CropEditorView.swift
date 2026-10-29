import AppKit
import SwiftUI

/// Lets the user pick how one photo fills the TV: drag the photo inside a 16:9 frame and zoom in or out,
/// or switch it to a blurred fill.
struct CropEditorView: View {
    let item: PhotoItem
    let onSave: (PhotoAdjustment) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var source: CGImage?
    @State private var displayImage: NSImage?
    @State private var loadError: String?
    @State private var fit: PhotoAdjustment.Fit
    /// Crop width as a fraction of the photo's width; the height follows from the 16:9 shape.
    @State private var cropWidth: CGFloat = 1
    /// Crop center, normalized with a top-left origin.
    @State private var center = CGPoint(x: 0.5, y: 0.5)
    @State private var hasManualCrop: Bool
    @State private var automaticCrop: CGRect?
    @State private var blurredPreview: NSImage?
    @State private var dragStartCenter: CGPoint?
    @State private var magnifyStartWidth: CGFloat?

    private let aspect = PhotoProcessor.tvSize.width / PhotoProcessor.tvSize.height
    private let maxZoom: CGFloat = 6

    init(item: PhotoItem, onSave: @escaping (PhotoAdjustment) -> Void) {
        self.item = item
        self.onSave = onSave
        _fit = State(initialValue: item.adjustment.fit)
        _hasManualCrop = State(initialValue: item.adjustment.crop != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Adjust “\(item.name)”")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Picker("Fit", selection: $fit) {
                    ForEach(PhotoAdjustment.Fit.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 330)
            }

            ZStack {
                Color.black.opacity(0.85)
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.white)
                } else if let source, let displayImage {
                    if mode(for: source) == .smartCrop {
                        cropCanvas(source: source, image: displayImage)
                    } else if let blurredPreview {
                        Image(nsImage: blurredPreview)
                            .resizable()
                            .aspectRatio(aspect, contentMode: .fit)
                            .padding(40)
                    } else {
                        ProgressView().controlSize(.large)
                    }
                } else {
                    ProgressView("Loading photo…")
                        .foregroundStyle(.white)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 10) {
                if let source, mode(for: source) == .smartCrop {
                    Button { setZoom(zoom(for: source) / 1.25, source: source) } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .help("Zoom out")
                    Slider(value: zoomBinding(for: source), in: 1...maxZoom)
                        .frame(maxWidth: 260)
                    Button { setZoom(zoom(for: source) * 1.25, source: source) } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .help("Zoom in")
                    Text("Drag the photo to move it. Pinch or use the slider to zoom.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let source {
                    Text(mode(for: source) == .blurredBackground
                         ? "The whole photo is shown over a blurred copy of itself."
                         : "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack {
                Button("Reset to Automatic") {
                    fit = .automatic
                    hasManualCrop = false
                    if let automaticCrop { apply(automaticCrop) }
                }
                .disabled(source == nil)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(source == nil)
            }
        }
        .padding(20)
        .frame(width: 960, height: 700)
        .task { await load() }
        .task(id: fit) { await renderBlurredPreview() }
    }

    // MARK: - Crop canvas

    private func cropCanvas(source: CGImage, image: NSImage) -> some View {
        GeometryReader { geometry in
            let imageSize = CGSize(width: source.width, height: source.height)
            let viewport = viewportRect(in: geometry.size)
            // Points on screen per photo pixel at the current zoom.
            let scale = viewport.width / (cropWidth * imageSize.width)
            let crop = currentCrop(imageSize: imageSize)
            let shown = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let origin = CGPoint(
                x: viewport.minX - crop.minX * imageSize.width * scale,
                y: viewport.minY - crop.minY * imageSize.height * scale
            )

            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: shown.width, height: shown.height)
                    .position(x: origin.x + shown.width / 2, y: origin.y + shown.height / 2)

                // Dim everything outside the TV frame.
                FrameMask(hole: viewport)
                    .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                ThirdsGrid(rect: viewport)
                    .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                    .allowsHitTesting(false)
                Rectangle()
                    .path(in: viewport)
                    .stroke(Color.white, lineWidth: 2)
                    .allowsHitTesting(false)
                Text("TV")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .position(x: viewport.minX + 22, y: viewport.minY + 14)
                    .allowsHitTesting(false)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .clipped()
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = dragStartCenter ?? center
                        dragStartCenter = start
                        // Moving the photo right moves the crop left over it.
                        center = CGPoint(
                            x: start.x - value.translation.width / (imageSize.width * scale),
                            y: start.y - value.translation.height / (imageSize.height * scale)
                        )
                        hasManualCrop = true
                        clampCenter(imageSize: imageSize)
                    }
                    .onEnded { _ in dragStartCenter = nil }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let start = magnifyStartWidth ?? cropWidth
                        magnifyStartWidth = start
                        setCropWidth(start / value.magnification, imageSize: imageSize)
                    }
                    .onEnded { _ in magnifyStartWidth = nil }
            )
        }
    }

    /// The largest 16:9 frame that fits in the canvas, leaving a margin to show what's cut off.
    private func viewportRect(in size: CGSize) -> CGRect {
        let available = CGSize(width: max(size.width - 120, 100), height: max(size.height - 80, 60))
        let width = min(available.width, available.height * aspect)
        let height = width / aspect
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    // MARK: - Crop state

    private func mode(for source: CGImage) -> FitMode {
        PhotoAdjustment(fit: fit, crop: hasManualCrop ? CGRect(x: 0, y: 0, width: 1, height: 1) : nil)
            .resolvedMode(for: CGSize(width: source.width, height: source.height))
    }

    private func currentCrop(imageSize: CGSize) -> CGRect {
        let height = CropPlanner.cropHeightFraction(widthFraction: cropWidth, imageSize: imageSize, aspect: aspect)
        return CGRect(x: center.x - cropWidth / 2, y: center.y - height / 2, width: cropWidth, height: height)
    }

    private func zoom(for source: CGImage) -> CGFloat {
        let imageSize = CGSize(width: source.width, height: source.height)
        return CropPlanner.maxCropWidthFraction(imageSize: imageSize, aspect: aspect) / cropWidth
    }

    private func zoomBinding(for source: CGImage) -> Binding<CGFloat> {
        Binding(
            get: { zoom(for: source) },
            set: { setZoom($0, source: source) }
        )
    }

    private func setZoom(_ zoom: CGFloat, source: CGImage) {
        let imageSize = CGSize(width: source.width, height: source.height)
        let maxWidth = CropPlanner.maxCropWidthFraction(imageSize: imageSize, aspect: aspect)
        setCropWidth(maxWidth / zoom, imageSize: imageSize)
    }

    private func setCropWidth(_ width: CGFloat, imageSize: CGSize) {
        let maxWidth = CropPlanner.maxCropWidthFraction(imageSize: imageSize, aspect: aspect)
        cropWidth = min(max(width, maxWidth / maxZoom), maxWidth)
        hasManualCrop = true
        clampCenter(imageSize: imageSize)
    }

    /// Keeps the frame inside the photo so the TV never shows an empty edge.
    private func clampCenter(imageSize: CGSize) {
        let height = CropPlanner.cropHeightFraction(widthFraction: cropWidth, imageSize: imageSize, aspect: aspect)
        center.x = min(max(center.x, cropWidth / 2), 1 - cropWidth / 2)
        center.y = min(max(center.y, height / 2), 1 - height / 2)
    }

    private func apply(_ crop: CGRect) {
        cropWidth = crop.width
        center = CGPoint(x: crop.midX, y: crop.midY)
        if let source {
            clampCenter(imageSize: CGSize(width: source.width, height: source.height))
        }
    }

    // MARK: - Loading and saving

    private func load() async {
        do {
            let image = try await PhotoLoader.previewImage(for: item.origin, maxPixelSize: 2048)
            let auto = await Task.detached(priority: .userInitiated) {
                PhotoProcessor.shared.automaticCrop(for: image)
            }.value
            source = image
            displayImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            automaticCrop = auto
            apply(item.adjustment.crop ?? auto)
            await renderBlurredPreview()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func renderBlurredPreview() async {
        guard let source, mode(for: source) == .blurredBackground else { return }
        let image = try? await Task.detached(priority: .userInitiated) {
            try PhotoProcessor.shared.makePreview(
                from: source,
                adjustment: PhotoAdjustment(fit: .blurredBackground),
                size: CGSize(width: 1280, height: 720)
            ).image
        }.value
        if let image {
            blurredPreview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }

    private func save() {
        var adjustment = PhotoAdjustment(fit: fit)
        if let source, mode(for: source) == .smartCrop, hasManualCrop {
            adjustment.crop = currentCrop(imageSize: CGSize(width: source.width, height: source.height))
            // A hand-placed crop always means cropping.
            if adjustment.fit == .automatic { adjustment.fit = .smartCrop }
        }
        onSave(adjustment)
        dismiss()
    }
}

/// A full-canvas rectangle with a hole, for dimming outside the TV frame (fill with even-odd).
private struct FrameMask: Shape {
    let hole: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRect(hole)
        return path
    }
}

/// Rule-of-thirds guides inside the TV frame.
private struct ThirdsGrid: Shape {
    let rect: CGRect

    func path(in _: CGRect) -> Path {
        var path = Path()
        for step in 1...2 {
            let x = rect.minX + rect.width * CGFloat(step) / 3
            let y = rect.minY + rect.height * CGFloat(step) / 3
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}
