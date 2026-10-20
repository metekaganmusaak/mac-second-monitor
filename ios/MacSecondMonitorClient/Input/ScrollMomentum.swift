import QuartzCore
import UIKit

/// Continues a fling after the fingers lift, decelerating like `UIScrollView`, so the Mac
/// receives momentum-phase scroll events as it would from a trackpad.
@MainActor
final class ScrollMomentum {
    /// Fractions of the frame per second.
    static let minimumStartSpeed: CGFloat = 0.25
    static let stopSpeed: CGFloat = 0.02
    static let maximumDuration: CFTimeInterval = 3
    /// `UIScrollView.DecelerationRate.normal`, per millisecond.
    static let decelerationRate: CGFloat = 0.998

    /// Normalized delta for one display frame.
    var onStep: (CGVector) -> Void = { _ in }
    var onEnd: () -> Void = {}

    private var displayLink: CADisplayLink?
    private var velocity = CGVector.zero
    private var lastTimestamp: CFTimeInterval = 0
    private var startTimestamp: CFTimeInterval = 0

    var isRunning: Bool { displayLink != nil }

    /// - Parameter velocity: normalized units per second.
    func start(velocity: CGVector) {
        stop()
        guard hypot(velocity.dx, velocity.dy) >= Self.minimumStartSpeed else { return }
        self.velocity = velocity
        lastTimestamp = 0
        startTimestamp = 0
        let link = CADisplayLink(target: DisplayLinkProxy(self), selector: #selector(DisplayLinkProxy.tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Ends the momentum early (a new touch) or when it has run out.
    func stop() {
        guard let displayLink else { return }
        displayLink.invalidate()
        self.displayLink = nil
        onEnd()
    }

    fileprivate func tick(_ link: CADisplayLink) {
        if startTimestamp == 0 {
            startTimestamp = link.timestamp
            lastTimestamp = link.timestamp - link.duration
        }
        let dt = link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp
        let decay = pow(Self.decelerationRate, CGFloat(dt * 1000))
        velocity = CGVector(dx: velocity.dx * decay, dy: velocity.dy * decay)
        guard hypot(velocity.dx, velocity.dy) >= Self.stopSpeed,
              link.timestamp - startTimestamp < Self.maximumDuration
        else {
            stop()
            return
        }
        onStep(CGVector(dx: velocity.dx * CGFloat(dt), dy: velocity.dy * CGFloat(dt)))
    }
}

/// CADisplayLink retains its target; the proxy keeps that from retaining the owner.
@MainActor
private final class DisplayLinkProxy: NSObject {
    private weak var owner: ScrollMomentum?

    init(_ owner: ScrollMomentum) {
        self.owner = owner
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let owner else { return link.invalidate() }
        owner.tick(link)
    }
}
