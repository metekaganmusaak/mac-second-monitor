import MSMProtocol
import UIKit

/// Transparent surface over the video. Maps fingers, Apple Pencil, trackpad / mouse and
/// hardware keys to INPUT events in normalized video-frame coordinates.
final class TouchInputView: UIView {
    var send: (InputEvent) -> Void = { _ in }
    var videoSize = CGSize.zero
    /// Whether the soft keyboard holds the focus; otherwise this view takes it back on touch.
    var isSoftKeyboardActive: () -> Bool = { false }

    let hardwareKeyboard = HardwareKeyboard()

    private let fingers = FingerGestureTracker()
    private let momentum = ScrollMomentum()
    private var momentumPoint = CGPoint.zero
    private var pencil: UITouch?
    private var pointerButtons: [ObjectIdentifier: PointerButton] = [:]
    private var lastPoint = CGPoint.zero
    private let feedback = UIImpactFeedbackGenerator(style: .medium)

    private var geometry: VideoGeometry {
        VideoGeometry(bounds: bounds, videoSize: videoSize)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear

        fingers.onGesture = { [weak self] in self?.handle($0) }
        momentum.onStep = { [weak self] delta in
            guard let self else { return }
            self.sendScroll(.momentum, at: self.momentumPoint, delta: delta)
        }
        momentum.onEnd = { [weak self] in
            guard let self else { return }
            self.sendScroll(.momentumEnded, at: self.momentumPoint, delta: .zero)
        }

        // Pointer (trackpad / mouse) moves without a button, and Apple Pencil hover.
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))

        // Scroll-only recognizers: no touches, just trackpad and wheel scroll events.
        let trackpad = UIPanGestureRecognizer(target: self, action: #selector(trackpadScroll(_:)))
        trackpad.allowedScrollTypesMask = .continuous
        trackpad.maximumNumberOfTouches = 0
        trackpad.cancelsTouchesInView = false
        addGestureRecognizer(trackpad)

        let wheel = UIPanGestureRecognizer(target: self, action: #selector(wheelScroll(_:)))
        wheel.allowedScrollTypesMask = .discrete
        wheel.maximumNumberOfTouches = 0
        wheel.cancelsTouchesInView = false
        addGestureRecognizer(wheel)

        // The Mac draws its own cursor into the stream.
        addInteraction(UIPointerInteraction(delegate: self))

        NotificationCenter.default.addObserver(self, selector: #selector(releaseEverything), name: UIApplication.willResignActiveNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var canBecomeFirstResponder: Bool { true }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !isFirstResponder, !isSoftKeyboardActive() {
            becomeFirstResponder()
        }
        for touch in touches {
            let point = touch.location(in: self)
            switch touch.type {
            case .pencil:
                guard pencil == nil else { continue }
                pencil = touch
                fingers.cancelAll()
                momentum.stop()
                // No slop for a stylus: it is precise, so it presses immediately.
                sendPointer(.move, .left, .stylus, at: point, pressure: Self.pressure(touch))
                sendPointer(.down, .left, .stylus, at: point, pressure: Self.pressure(touch))
            case .indirectPointer:
                let button = Self.button(for: event?.buttonMask ?? .primary)
                pointerButtons[ObjectIdentifier(touch)] = button
                momentum.stop()
                sendPointer(.move, button, .mouse, at: point)
                sendPointer(.down, button, .mouse, at: point)
            case .direct where pencil == nil:
                momentum.stop()
                fingers.began(ObjectIdentifier(touch), at: point, time: touch.timestamp)
            default:
                break
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            switch touch.type {
            case .pencil where touch === pencil:
                // Pencil samples at up to 240 Hz; send the coalesced points for smooth strokes.
                for sample in event?.coalescedTouches(for: touch) ?? [touch] {
                    sendPointer(.move, .left, .stylus, at: sample.location(in: self), pressure: Self.pressure(sample))
                }
            case .indirectPointer:
                guard let button = pointerButtons[ObjectIdentifier(touch)] else { continue }
                sendPointer(.move, button, .mouse, at: touch.location(in: self))
            case .direct:
                fingers.moved(ObjectIdentifier(touch), at: touch.location(in: self), time: touch.timestamp)
            default:
                break
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        for touch in touches {
            let point = touch.location(in: self)
            switch touch.type {
            case .pencil where touch === pencil:
                pencil = nil
                sendPointer(cancelled ? .cancel : .up, .left, .stylus, at: point, pressure: 0)
            case .indirectPointer:
                guard let button = pointerButtons.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
                sendPointer(cancelled ? .cancel : .up, button, .mouse, at: point)
            case .direct:
                if cancelled {
                    fingers.cancelled(ObjectIdentifier(touch))
                } else {
                    fingers.ended(ObjectIdentifier(touch), at: point, time: touch.timestamp)
                }
            default:
                break
            }
        }
    }

    private func handle(_ gesture: FingerGestureTracker.Gesture) {
        switch gesture {
        case let .tap(point):
            click(.left, at: point)
        case let .secondaryClick(point):
            feedback.impactOccurred()
            click(.right, at: point)
        case let .dragBegan(start, point):
            sendPointer(.move, .left, .finger, at: start)
            sendPointer(.down, .left, .finger, at: start)
            sendPointer(.move, .left, .finger, at: point)
        case let .dragMoved(point):
            sendPointer(.move, .left, .finger, at: point)
        case let .dragEnded(point):
            sendPointer(.up, .left, .finger, at: point)
        case let .dragCancelled(point):
            sendPointer(.cancel, .left, .finger, at: point)
        case let .scrollBegan(point):
            sendScroll(.began, at: point, delta: .zero)
        case let .scrollChanged(point, delta):
            sendScroll(.changed, at: point, delta: geometry.normalizedDelta(delta))
        case let .scrollEnded(point, velocity):
            sendScroll(.ended, at: point, delta: .zero)
            momentumPoint = point
            momentum.start(velocity: geometry.normalizedDelta(velocity))
        }
    }

    // MARK: Pointer and scroll recognizers

    @objc private func hover(_ recognizer: UIHoverGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        var tool = PointerTool.mouse
        if #available(iOS 16.1, *), recognizer.zOffset > 0 {
            tool = .stylus
        }
        sendPointer(.move, .left, tool, at: recognizer.location(in: self))
    }

    @objc private func trackpadScroll(_ recognizer: UIPanGestureRecognizer) {
        let point = recognizer.location(in: self)
        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        switch recognizer.state {
        case .began:
            momentum.stop()
            sendScroll(.began, at: point, delta: .zero)
            if translation != .zero {
                sendScroll(.changed, at: point, delta: geometry.normalizedDelta(translation))
            }
        case .changed:
            sendScroll(.changed, at: point, delta: geometry.normalizedDelta(translation))
        case .ended:
            sendScroll(.ended, at: point, delta: .zero)
            momentumPoint = point
            momentum.start(velocity: geometry.normalizedDelta(recognizer.velocity(in: self)))
        case .cancelled, .failed:
            sendScroll(.ended, at: point, delta: .zero)
        default:
            break
        }
    }

    /// Mouse wheel notches become plain wheel steps without gesture phases.
    @objc private func wheelScroll(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        let translation = recognizer.translation(in: self)
        recognizer.setTranslation(.zero, in: self)
        guard translation != .zero else { return }
        sendScroll(.none, at: recognizer.location(in: self), delta: geometry.normalizedDelta(translation))
    }

    // MARK: Keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = hardwareKeyboard.handle(presses, action: .down, send: send)
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = hardwareKeyboard.handle(presses, action: .up, send: send)
        if !rest.isEmpty { super.pressesEnded(rest, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let rest = hardwareKeyboard.handle(presses, action: .up, send: send)
        if !rest.isEmpty { super.pressesCancelled(rest, with: event) }
    }

    /// Nothing may stay pressed on the Mac while the app is not in front.
    @objc private func releaseEverything() {
        fingers.cancelAll()
        momentum.stop()
        if let pencil {
            self.pencil = nil
            sendPointer(.cancel, .left, .stylus, at: pencil.location(in: self), pressure: 0)
        }
        for button in pointerButtons.values {
            sendPointer(.cancel, button, .mouse, at: lastPoint)
        }
        pointerButtons.removeAll()
        hardwareKeyboard.releaseAll(send: send)
    }

    // MARK: Sending

    private func click(_ button: PointerButton, at point: CGPoint) {
        sendPointer(.move, button, .finger, at: point)
        sendPointer(.down, button, .finger, at: point)
        sendPointer(.up, button, .finger, at: point)
    }

    private func sendPointer(_ action: PointerAction, _ button: PointerButton, _ tool: PointerTool, at point: CGPoint, pressure: Float = 1) {
        lastPoint = point
        let position = geometry.normalizedPoint(point)
        send(.pointer(action: action, button: button, tool: tool, x: position.x, y: position.y, pressure: pressure))
    }

    private func sendScroll(_ phase: ScrollPhase, at point: CGPoint, delta: CGVector) {
        let position = geometry.normalizedPoint(point)
        send(.scroll(phase: phase, unit: .normalized, x: position.x, y: position.y, dx: Float(delta.dx), dy: Float(delta.dy)))
    }

    private static func pressure(_ touch: UITouch) -> Float {
        guard touch.maximumPossibleForce > 0 else { return 1 }
        return Float(min(max(touch.force / touch.maximumPossibleForce, 0), 1))
    }

    private static func button(for mask: UIEvent.ButtonMask) -> PointerButton {
        if mask.contains(.secondary) { return .right }
        if mask.contains(.button(3)) { return .middle }
        return .left
    }
}

extension TouchInputView: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        .hidden()
    }
}
