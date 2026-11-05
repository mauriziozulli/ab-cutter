import AppKit

/// The OBS-style frame that is laid over Pro Tools: a border, a handle to
/// move it by, a corner to size it by, and nothing in between.
///
/// The inside is fully transparent, so clicks go straight through to Pro Tools
/// underneath and the edit window stays usable while it is framed. The shape
/// is locked to the Pro Tools band of the 4:5 post, so whatever is framed here
/// fills that band without cropping. The window is left out of the capture.
@MainActor
final class CaptureFrameWindow: NSPanel {
    static let border: CGFloat = 4
    private static let savedFrameKey = "captureFrame"

    var isRecording = false {
        didSet { frameView.isRecording = isRecording }
    }

    var countdown: Int? {
        didSet { frameView.countdown = countdown }
    }

    private let frameView = CaptureFrameView()

    init() {
        let initial = Self.restoredFrame()
        super.init(
            contentRect: initial,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = frameView
        frameView.onChange = { [weak self] in self?.persist() }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The rectangle actually recorded: inside the border, in global AppKit
    /// coordinates.
    var captureRect: CGRect {
        frame.insetBy(dx: Self.border, dy: Self.border)
    }

    /// Pixels the recording will have, for the readout.
    var capturePixels: CGSize {
        let scale = screen?.backingScaleFactor ?? 2
        return CGSize(width: captureRect.width * scale, height: captureRect.height * scale)
    }

    private func persist() {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.savedFrameKey)
        NotificationCenter.default.post(name: .captureFrameChanged, object: self)
    }

    private static func restoredFrame() -> NSRect {
        if let saved = UserDefaults.standard.string(forKey: savedFrameKey) {
            let rect = NSRectFromString(saved)
            if rect.width > 100, NSScreen.screens.contains(where: { $0.frame.intersects(rect) }) {
                return rect
            }
        }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(visible.width * 0.6, 1200)
        let height = width / PostLayout.screenAspect
        return NSRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width + border * 2,
            height: height + border * 2
        )
    }

    /// Resizes from the bottom-right corner, keeping the 3:2 inside.
    fileprivate func resize(toWidth width: CGFloat, keepingTopLeft topLeft: CGPoint) {
        let inner = max(width - Self.border * 2, 240)
        let height = inner / PostLayout.screenAspect + Self.border * 2
        let size = NSSize(width: inner + Self.border * 2, height: height)
        setFrame(NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height), display: true)
    }
}

extension Notification.Name {
    static let captureFrameChanged = Notification.Name("SessionCutter.captureFrameChanged")
}

@MainActor
private final class CaptureFrameView: NSView {
    var isRecording = false {
        didSet { needsDisplay = true }
    }
    var countdown: Int? {
        didSet { needsDisplay = true }
    }
    var onChange: (() -> Void)?

    private let grip: CGFloat = 22
    private var resizing = false
    private var anchor: CGPoint = .zero
    private var startWidth: CGFloat = 0
    private var startMouse: CGPoint = .zero

    private var tint: NSColor {
        if countdown != nil { return NSColor.systemOrange }
        return isRecording ? NSColor.systemRed : NSColor.systemBlue
    }

    private var tabRect: NSRect {
        NSRect(x: CaptureFrameWindow.border, y: bounds.maxY - 26 - CaptureFrameWindow.border, width: 190, height: 26)
    }

    private var gripRect: NSRect {
        NSRect(x: bounds.maxX - grip, y: 0, width: grip, height: grip)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()

        let border = CaptureFrameWindow.border
        let path = NSBezierPath(rect: bounds.insetBy(dx: border / 2, dy: border / 2))
        path.lineWidth = border
        tint.setStroke()
        path.stroke()

        // The handle: the one place besides the border that takes a click.
        let tab = NSBezierPath(roundedRect: tabRect, xRadius: 5, yRadius: 5)
        tint.withAlphaComponent(0.9).setFill()
        tab.fill()
        let label: String
        if let countdown {
            label = "Start in \(countdown) …"
        } else {
            label = isRecording ? "● Aufnahme läuft" : "Pro Tools · 3:2 · ziehen"
        }
        NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]).draw(at: NSPoint(x: tabRect.minX + 9, y: tabRect.minY + 5))

        // The countdown, big, in the middle — the frame is left out of the
        // recording, so it can say what it likes.
        if let countdown {
            let number = NSAttributedString(string: "\(countdown)", attributes: [
                .font: NSFont.systemFont(ofSize: min(bounds.height * 0.4, 220), weight: .heavy),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9)
            ])
            let size = number.size()
            let disc = NSRect(
                x: bounds.midX - size.height * 0.75,
                y: bounds.midY - size.height * 0.75,
                width: size.height * 1.5,
                height: size.height * 1.5
            )
            NSColor.black.withAlphaComponent(0.55).setFill()
            NSBezierPath(ovalIn: disc).fill()
            number.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
        }

        tint.setFill()
        let corner = NSBezierPath()
        corner.move(to: NSPoint(x: gripRect.maxX, y: gripRect.minY))
        corner.line(to: NSPoint(x: gripRect.maxX, y: gripRect.maxY))
        corner.line(to: NSPoint(x: gripRect.minX, y: gripRect.minY))
        corner.close()
        corner.fill()
    }

    /// Only the border, the handle and the corner are solid. Everything else
    /// lets the click fall through to Pro Tools.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let inner = bounds.insetBy(dx: CaptureFrameWindow.border + 2, dy: CaptureFrameWindow.border + 2)
        if tabRect.contains(local) || gripRect.contains(local) || !inner.contains(local) {
            return super.hitTest(point)
        }
        return nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard !isRecording, let window = window as? CaptureFrameWindow else { return }
        let local = convert(event.locationInWindow, from: nil)
        if gripRect.contains(local) {
            resizing = true
            anchor = CGPoint(x: window.frame.minX, y: window.frame.maxY)
            startWidth = window.frame.width
            startMouse = NSEvent.mouseLocation
        } else {
            resizing = false
            window.performDrag(with: event)
            onChange?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard resizing, let window = window as? CaptureFrameWindow else { return }
        let delta = NSEvent.mouseLocation.x - startMouse.x
        window.resize(toWidth: startWidth + delta, keepingTopLeft: anchor)
    }

    override func mouseUp(with event: NSEvent) {
        if resizing { onChange?() }
        resizing = false
    }

    override func resetCursorRects() {
        addCursorRect(gripRect, cursor: .crosshair)
        addCursorRect(tabRect, cursor: .openHand)
    }
}
