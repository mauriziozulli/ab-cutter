import AVFoundation
import CoreImage
import CoreMedia

/// Everything one post frame is made of, decided before playback starts so
/// the compositor never has to think.
struct LayoutPlan: @unchecked Sendable {
    var renderSize: CGSize
    /// Core Image coordinates: origin bottom left.
    var filmRect: CGRect
    var screenRect: CGRect
    /// The story format fills the space around the two bands with the film,
    /// softened and darkened, so the frame never reads as letterboxed.
    var softBackdrop: Bool
    /// Full-canvas overlays, drawn once on the main actor.
    var title: CGImage?
    var labelOriginal: CGImage?
    var labelMix: CGImage?
    /// Composition time of every A/B switch, and which side plays at 0.
    var switches: [Double]
    var startsOnMix: Bool
    var filmTrackID: CMPersistentTrackID
    var screenTrackID: CMPersistentTrackID

    func isMix(at seconds: Double) -> Bool {
        let flips = switches.filter { $0 <= seconds }.count
        return (flips % 2 == 1) != startsOnMix
    }

    /// The two bands. A gap between them comes off the film band, which
    /// fills its rect by cropping anyway; Pro Tools keeps its full height.
    static func rects(for format: OutputFormat, gap: Double = 0) -> (film: CGRect, screen: CGRect) {
        let size = format.size
        let block = PostLayout.filmBandHeight + PostLayout.screenBandHeight
        let bottom = ((size.height - block) / 2).rounded()
        let spacing = CGFloat(min(max(gap, 0), PostLayout.filmBandHeight / 2)).rounded()
        let screen = CGRect(x: 0, y: bottom, width: size.width, height: PostLayout.screenBandHeight)
        let film = CGRect(
            x: 0, y: screen.maxY + spacing,
            width: size.width, height: PostLayout.filmBandHeight - spacing
        )
        return (film, screen)
    }
}

final class LayoutInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let plan: LayoutPlan

    init(timeRange: CMTimeRange, plan: LayoutPlan) {
        self.timeRange = timeRange
        self.plan = plan
        self.requiredSourceTrackIDs = [plan.filmTrackID, plan.screenTrackID]
            .filter { $0 != kCMPersistentTrackID_Invalid }
            .map { NSNumber(value: $0) }
    }
}

/// Stacks film over Pro Tools, lays the title and the side's label on top.
/// The same code draws the preview, the export and the stills, so what is
/// seen while cutting is exactly what is posted.
final class SessionCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let colourSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private let context = CIContext(options: [
        .workingColorSpace: SessionCompositor.colourSpace,
        .cacheIntermediates: false
    ])

    let sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? LayoutInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "SessionCutter", code: 1))
            return
        }
        let plan = instruction.plan
        let canvas = CGRect(origin: .zero, size: plan.renderSize)
        let seconds = CMTimeGetSeconds(request.compositionTime)

        var image = CIImage(color: CIColor(red: 0.063, green: 0.063, blue: 0.078)).cropped(to: canvas)

        let film = request.sourceFrame(byTrackID: plan.filmTrackID).map { CIImage(cvPixelBuffer: $0) }
        if plan.softBackdrop, let film {
            image = Self.backdrop(film, canvas: canvas)
            // The gap reads as a clean cut, not as backdrop showing through.
            let gap = CGRect(
                x: 0, y: plan.screenRect.maxY,
                width: canvas.width, height: plan.filmRect.minY - plan.screenRect.maxY
            )
            if gap.height > 0 {
                image = CIImage(color: CIColor(red: 0.063, green: 0.063, blue: 0.078))
                    .cropped(to: gap).composited(over: image)
            }
        }
        if let film {
            image = Self.place(film, in: plan.filmRect).composited(over: image)
        }
        if let screen = request.sourceFrame(byTrackID: plan.screenTrackID).map({ CIImage(cvPixelBuffer: $0) }) {
            image = Self.place(screen, in: plan.screenRect).composited(over: image)
        }
        if let title = plan.title {
            image = CIImage(cgImage: title).composited(over: image)
        }
        if let label = plan.isMix(at: seconds) ? plan.labelMix : plan.labelOriginal {
            image = CIImage(cgImage: label).composited(over: image)
        }

        context.render(image.cropped(to: canvas), to: output, bounds: canvas, colorSpace: Self.colourSpace)
        request.finish(withComposedVideoFrame: output)
    }

    /// Fills `rect` with the picture, cropping whatever overhangs, centred.
    static func place(_ image: CIImage, in rect: CGRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = max(rect.width / extent.width, rect.height / extent.height)
        let width = extent.width * scale
        let height = extent.height * scale
        return image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(
                translationX: rect.midX - width / 2,
                y: rect.midY - height / 2
            ))
            .cropped(to: rect)
    }

    private static func backdrop(_ film: CIImage, canvas: CGRect) -> CIImage {
        let filled = place(film, in: canvas)
        let blurred = filled.clampedToExtent()
            .applyingGaussianBlur(sigma: 40)
            .cropped(to: canvas)
        let scrim = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.55)).cropped(to: canvas)
        return scrim.composited(over: blurred)
    }
}
