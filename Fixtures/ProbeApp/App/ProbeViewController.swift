import ProbeCore
import UIKit

/// Full-screen, portrait-only host that asks UIKit to keep system UI and edge
/// gestures out of the way as far as it allows.
final class ProbeViewController: UIViewController {
    private let model: ProbeModel

    init(model: ProbeModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        view = ProbeSurfaceView(model: model)
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    // System edge gestures then need a second swipe; the first reaches the probe.
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
}

/// Element whose accessibility value is read live from the model on every query.
final class ProbeReadoutElement: UIAccessibilityElement {
    var read: (@MainActor () -> String)?

    override var accessibilityValue: String? {
        get { read?() }
        set { _ = newValue }
    }
}

/// Element that resets the probe when activated through accessibility (a
/// Manzanero `press-id`). It is not a view, so it never receives touches.
final class ProbeResetElement: UIAccessibilityElement {
    var reset: (@MainActor () -> Void)?
    var read: (@MainActor () -> String)?

    override var accessibilityValue: String? {
        get { read?() }
        set { _ = newValue }
    }

    override func accessibilityActivate() -> Bool {
        reset?()
        // Returning true tells UIKit the action was handled, so it does not fall
        // back to a synthesized tap at the activation point.
        return true
    }
}

/// The touch surface. It records every UITouch it receives, has no gesture
/// recognizers, and draws a simple human-readable view of what it recorded.
/// Its accessibility children are UIAccessibilityElement objects, not views,
/// so they cannot intercept touches.
final class ProbeSurfaceView: UIView {
    // Namespaced by probe so later probes can add their own elements.
    static let summaryIdentifier = "probe.touch.summary"
    static let lastGestureIdentifier = "probe.touch.last-gesture"
    static let recentGesturesIdentifier = "probe.touch.recent-gestures"
    static let resetIdentifier = "probe.touch.reset"

    private let model: ProbeModel
    private let summaryElement: ProbeReadoutElement
    private let gestureElement: ProbeReadoutElement
    private let recentElement: ProbeReadoutElement
    private let resetElement: ProbeResetElement

    init(model: ProbeModel) {
        self.model = model
        summaryElement = ProbeReadoutElement(accessibilityContainer: NSObject())
        gestureElement = ProbeReadoutElement(accessibilityContainer: NSObject())
        recentElement = ProbeReadoutElement(accessibilityContainer: NSObject())
        resetElement = ProbeResetElement(accessibilityContainer: NSObject())
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        contentMode = .redraw

        for element in [summaryElement, gestureElement, recentElement, resetElement] as [UIAccessibilityElement] {
            element.accessibilityContainer = self
        }
        summaryElement.accessibilityIdentifier = Self.summaryIdentifier
        summaryElement.accessibilityLabel = "Probe summary"
        summaryElement.accessibilityTraits = [.staticText, .updatesFrequently]
        summaryElement.read = { [unowned model] in model.summaryJSON }

        gestureElement.accessibilityIdentifier = Self.lastGestureIdentifier
        gestureElement.accessibilityLabel = "Probe last gesture"
        gestureElement.accessibilityTraits = [.staticText, .updatesFrequently]
        gestureElement.read = { [unowned model] in model.lastGestureJSON }

        recentElement.accessibilityIdentifier = Self.recentGesturesIdentifier
        recentElement.accessibilityLabel = "Probe recent gestures"
        recentElement.accessibilityTraits = [.staticText, .updatesFrequently]
        recentElement.read = { [unowned model] in model.recentGesturesJSON }

        resetElement.accessibilityIdentifier = Self.resetIdentifier
        resetElement.accessibilityLabel = "Reset probe"
        resetElement.accessibilityTraits = .button
        resetElement.read = { [unowned model] in model.recorder.session }
        resetElement.reset = { [unowned model] in model.reset() }

        isAccessibilityElement = false
        accessibilityElements = [summaryElement, gestureElement, recentElement, resetElement]
        model.onChange = { [weak self] in self?.setNeedsDisplay() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Layout

    private var summaryRect: CGRect { CGRect(x: 16, y: 64, width: bounds.width - 32, height: 92) }
    private var gestureRect: CGRect { CGRect(x: 16, y: 164, width: bounds.width - 32, height: 120) }
    private var recentRect: CGRect { CGRect(x: 16, y: 292, width: bounds.width - 32, height: 92) }
    private var resetRect: CGRect { CGRect(x: bounds.midX - 90, y: bounds.maxY - 132, width: 180, height: 52) }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Container-space frames follow layout; none overlap, so an AX hit test
        // at the reset element's centre resolves to that element.
        summaryElement.accessibilityFrameInContainerSpace = summaryRect
        gestureElement.accessibilityFrameInContainerSpace = gestureRect
        recentElement.accessibilityFrameInContainerSpace = recentRect
        resetElement.accessibilityFrameInContainerSpace = resetRect
        if let window {
            model.interfaceDidChange(size: window.bounds.size, scale: window.screen.scale)
        }
        setNeedsDisplay()
    }

    // MARK: Touches (no super calls: the surface consumes every touch)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { model.handle(touches, phase: .began) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { model.handle(touches, phase: .moved) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { model.handle(touches, phase: .ended) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { model.handle(touches, phase: .cancelled) }

    // MARK: Drawing

    private static let palette: [UIColor] = [.systemYellow, .systemCyan, .systemPink, .systemGreen, .systemOrange,
                                             .systemPurple, .systemTeal, .systemRed, .systemIndigo, .systemMint]

    override func draw(_ rect: CGRect) {
        let summary = model.summary
        let text: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: UIColor.white,
        ]
        let heading: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .bold), .foregroundColor: UIColor.systemYellow,
        ]

        let summaryText = NSMutableAttributedString(string: "TOUCH PROBE  session \(summary.session)\n", attributes: heading)
        summaryText.append(NSAttributedString(string: """
            began \(summary.began)  moved \(summary.moved)  ended \(summary.ended)  cancelled \(summary.cancelled)
            active \(summary.active)  max \(summary.maxActive)  gestures \(summary.gestures)  unmatched \(summary.unmatched)
            log \(summary.log.lines) lines  \(summary.log.bytes) B  dropped \(summary.log.dropped)\(summary.log.error == nil ? "" : "  WRITE ERROR")
            """, attributes: text))
        summaryText.draw(in: summaryRect)

        let gesture = model.recorder.lastGesture
        let gestureText = NSMutableAttributedString(
            string: gesture.gesture == 0 ? "LAST GESTURE  none yet\n"
                : String(format: "LAST GESTURE  #%d  max %d  %.3f s\n", gesture.gesture, gesture.maxActive, gesture.duration),
            attributes: heading)
        for contact in gesture.contacts.prefix(5) {
            gestureText.append(NSAttributedString(string: String(
                format: "c%d (%.3f,%.3f)->(%.3f,%.3f) %.3fs %@\n", contact.c, contact.from[0], contact.from[1],
                contact.to[0], contact.to[1], contact.duration, contact.end), attributes: text))
        }
        if gesture.contacts.count > 5 {
            gestureText.append(NSAttributedString(string: "+\(gesture.contacts.count - 5) more\n", attributes: text))
        }
        gestureText.draw(in: gestureRect)

        let recent = model.recorder.recentGestures
        let recentText = NSMutableAttributedString(
            string: "RECENT  \(recent.recent.count) listed  \(recent.dropped) dropped\n", attributes: heading)
        // Newest first on screen; the readout itself is oldest first.
        for entry in recent.recent.reversed().prefix(4) {
            recentText.append(NSAttributedString(string: String(
                format: "#%d  %d contact(s)  max %d  %.3f s\n", entry.gesture, entry.contacts.count, entry.maxActive,
                entry.duration), attributes: text))
        }
        recentText.draw(in: recentRect)

        let reset = UIBezierPath(roundedRect: resetRect, cornerRadius: 10)
        UIColor.darkGray.setStroke()
        reset.lineWidth = 1.5
        reset.stroke()
        let resetText = NSAttributedString(string: "RESET\naccessibility only", attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: UIColor.gray,
            .paragraphStyle: { let style = NSMutableParagraphStyle(); style.alignment = .center; return style }(),
        ])
        resetText.draw(in: resetRect.insetBy(dx: 4, dy: 8))

        // Landing marks: rings at each recent began position, labelled by contact index.
        let label: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .bold), .foregroundColor: UIColor.white,
        ]
        for mark in model.landings {
            let color = Self.palette[mark.contact % Self.palette.count]
            let ring = UIBezierPath(arcCenter: mark.point, radius: 22, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            ring.lineWidth = 2
            color.setStroke()
            ring.stroke()
            let cross = UIBezierPath()
            cross.move(to: CGPoint(x: mark.point.x - 6, y: mark.point.y))
            cross.addLine(to: CGPoint(x: mark.point.x + 6, y: mark.point.y))
            cross.move(to: CGPoint(x: mark.point.x, y: mark.point.y - 6))
            cross.addLine(to: CGPoint(x: mark.point.x, y: mark.point.y + 6))
            cross.lineWidth = 1
            cross.stroke()
            NSAttributedString(string: "\(mark.contact)", attributes: label)
                .draw(at: CGPoint(x: mark.point.x + 18, y: mark.point.y - 30))
        }
        // Contacts currently down: filled discs at their latest position.
        for (contact, point) in model.current {
            Self.palette[contact % Self.palette.count].withAlphaComponent(0.5).setFill()
            UIBezierPath(arcCenter: point, radius: 18, startAngle: 0, endAngle: .pi * 2, clockwise: true).fill()
        }
    }
}
