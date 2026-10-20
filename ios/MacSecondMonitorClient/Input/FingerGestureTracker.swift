import CoreGraphics
import Foundation

/// Recognizes the finger gestures of the protocol's touch mapping from raw touches:
/// tap, drag after the slop, long press and two-finger tap (right click), two-finger scroll.
@MainActor
final class FingerGestureTracker {
    enum Gesture: Equatable {
        case tap(CGPoint)
        case secondaryClick(CGPoint)
        case dragBegan(from: CGPoint, to: CGPoint)
        case dragMoved(CGPoint)
        case dragEnded(CGPoint)
        case dragCancelled(CGPoint)
        case scrollBegan(CGPoint)
        case scrollChanged(at: CGPoint, delta: CGPoint)
        /// `velocity` in points per second, for momentum.
        case scrollEnded(at: CGPoint, velocity: CGPoint)
    }

    static let slop: CGFloat = 10
    static let longPressDelay: UInt64 = 500_000_000
    static let twoFingerTapMaxDuration: TimeInterval = 0.3

    var onGesture: (Gesture) -> Void = { _ in }

    private enum State {
        case idle
        /// One finger down, not moved beyond the slop yet.
        case pending
        case dragging
        case twoFingerPending
        case scrolling
        /// The gesture is over; wait until every finger is lifted.
        case done
    }

    private var state = State.idle
    private var order: [ObjectIdentifier] = []
    private var locations: [ObjectIdentifier: CGPoint] = [:]
    private var start = CGPoint.zero
    private var startTime: TimeInterval = 0
    private var lastCentroid = CGPoint.zero
    private var samples: [(time: TimeInterval, point: CGPoint)] = []
    private var longPressTask: Task<Void, Never>?

    var isTracking: Bool { !order.isEmpty }

    func began(_ id: ObjectIdentifier, at point: CGPoint, time: TimeInterval) {
        order.append(id)
        locations[id] = point
        switch (state, order.count) {
        case (.idle, 1):
            state = .pending
            start = point
            startTime = time
            scheduleLongPress()
        case (.pending, 2):
            cancelLongPress()
            state = .twoFingerPending
            start = centroid()
            lastCentroid = start
            startTime = time
        case (.twoFingerPending, _), (.scrolling, _):
            // A third finger is not part of the mapping.
            endScroll(velocity: .zero)
            state = .done
        default:
            // Extra fingers during a drag are ignored.
            break
        }
    }

    func moved(_ id: ObjectIdentifier, at point: CGPoint, time: TimeInterval) {
        guard locations[id] != nil else { return }
        locations[id] = point
        switch state {
        case .pending:
            guard distance(point, start) > Self.slop else { return }
            cancelLongPress()
            state = .dragging
            onGesture(.dragBegan(from: start, to: point))
        case .dragging:
            if id == order.first { onGesture(.dragMoved(point)) }
        case .twoFingerPending:
            let center = centroid()
            guard distance(center, start) > Self.slop else { return }
            state = .scrolling
            samples = [(time, center)]
            onGesture(.scrollBegan(start))
            onGesture(.scrollChanged(at: center, delta: CGPoint(x: center.x - start.x, y: center.y - start.y)))
            lastCentroid = center
        case .scrolling:
            let center = centroid()
            let delta = CGPoint(x: center.x - lastCentroid.x, y: center.y - lastCentroid.y)
            lastCentroid = center
            samples.append((time, center))
            samples.removeAll { time - $0.time > 0.1 }
            if delta != .zero { onGesture(.scrollChanged(at: center, delta: delta)) }
        case .idle, .done:
            break
        }
    }

    func ended(_ id: ObjectIdentifier, at point: CGPoint, time: TimeInterval) {
        guard locations[id] != nil else { return }
        locations[id] = point
        switch state {
        case .pending:
            cancelLongPress()
            onGesture(.tap(start))
            state = .done
        case .dragging where id == order.first:
            onGesture(.dragEnded(point))
            state = .done
        case .twoFingerPending:
            if time - startTime <= Self.twoFingerTapMaxDuration {
                onGesture(.secondaryClick(start))
            }
            state = .done
        case .scrolling:
            endScroll(velocity: velocity(at: time))
            state = .done
        default:
            break
        }
        remove(id)
    }

    func cancelled(_ id: ObjectIdentifier) {
        guard locations[id] != nil else { return }
        switch state {
        case .dragging:
            if let first = order.first, let point = locations[first] { onGesture(.dragCancelled(point)) }
        case .scrolling:
            endScroll(velocity: .zero)
        default:
            break
        }
        cancelLongPress()
        if state != .idle { state = .done }
        remove(id)
    }

    /// Aborts whatever is in progress, e.g. when the Apple Pencil touches down (palm rejection).
    func cancelAll() {
        for id in order {
            cancelled(id)
        }
    }

    // MARK: Helpers

    private func endScroll(velocity: CGPoint) {
        guard state == .scrolling else { return }
        onGesture(.scrollEnded(at: lastCentroid, velocity: velocity))
    }

    private func remove(_ id: ObjectIdentifier) {
        order.removeAll { $0 == id }
        locations[id] = nil
        if order.isEmpty {
            state = .idle
            samples = []
        }
    }

    private func centroid() -> CGPoint {
        let points = order.prefix(2).compactMap { locations[$0] }
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    /// Average over the last 100 ms; zero if the fingers rested before lifting.
    private func velocity(at time: TimeInterval) -> CGPoint {
        let recent = samples.filter { time - $0.time <= 0.1 }
        guard let first = recent.first, let last = recent.last, last.time > first.time, time - last.time < 0.05 else {
            return .zero
        }
        let dt = last.time - first.time
        return CGPoint(x: (last.point.x - first.point.x) / dt, y: (last.point.y - first.point.y) / dt)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func scheduleLongPress() {
        longPressTask?.cancel()
        longPressTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.longPressDelay)
            guard let self, !Task.isCancelled, self.state == .pending else { return }
            self.state = .done
            self.onGesture(.secondaryClick(self.start))
        }
    }

    private func cancelLongPress() {
        longPressTask?.cancel()
        longPressTask = nil
    }
}
