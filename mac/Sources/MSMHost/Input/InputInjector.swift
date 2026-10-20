import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import MSMProtocol

/// Maps normalized video-frame coordinates to global display coordinates (points).
struct CoordinateMapper: Sendable, Equatable {
    /// Global bounds of the streamed display.
    var displayBounds: CGRect
    /// Part of the video frame (normalized) that shows the display; smaller than the
    /// full frame when a mirrored display is letterboxed.
    var contentRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    func point(x: Float, y: Float) -> CGPoint {
        let u = min(max((CGFloat(x) - contentRect.minX) / contentRect.width, 0), 1)
        let v = min(max((CGFloat(y) - contentRect.minY) / contentRect.height, 0), 1)
        // Stay one point inside so the cursor never lands on a neighbouring display.
        return CGPoint(
            x: displayBounds.minX + min(u * displayBounds.width, displayBounds.width - 1),
            y: displayBounds.minY + min(v * displayBounds.height, displayBounds.height - 1)
        )
    }

    func delta(dx: Float, dy: Float) -> CGSize {
        CGSize(
            width: CGFloat(dx) / contentRect.width * displayBounds.width,
            height: CGFloat(dy) / contentRect.height * displayBounds.height
        )
    }

    /// Normalized rect occupied by `source` when aspect-fitted into `frame`.
    static func aspectFit(source: CGSize, into frame: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0, frame.width > 0, frame.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let scale = min(frame.width / source.width, frame.height / source.height)
        let width = source.width * scale / frame.width
        let height = source.height * scale / frame.height
        return CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }
}

/// Counts consecutive clicks like the HID system does, for double / triple clicks.
struct ClickTracker {
    private var lastButton: PointerButton?
    private var lastTime: TimeInterval = 0
    private var lastPoint = CGPoint.zero
    private var count = 0

    mutating func register(_ button: PointerButton, at point: CGPoint, time: TimeInterval, interval: TimeInterval, maxDistance: CGFloat = 8) -> Int64 {
        let distance = hypot(point.x - lastPoint.x, point.y - lastPoint.y)
        if button == lastButton, time - lastTime <= interval, distance <= maxDistance {
            count += 1
        } else {
            count = 1
        }
        lastButton = button
        lastTime = time
        lastPoint = point
        return Int64(count)
    }
}

/// Posts mouse, scroll and keyboard events. Needs the Accessibility permission.
/// Not thread-safe: use from one serial queue.
final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var pressed: [PointerButton: Int64] = [:]
    private var clicks = ClickTracker()
    private var flags: CGEventFlags = []
    private var location: CGPoint?
    private var scrollRemainder = CGSize.zero
    private var inMomentum = false
    private var warnedAboutPermission = false

    static var isTrusted: Bool { AXIsProcessTrusted() }

    func handle(_ event: InputEvent, mapper: CoordinateMapper) {
        if !warnedAboutPermission, !Self.isTrusted {
            warnedAboutPermission = true
            Log.input.error("Accessibility permission missing; input events are ignored by macOS")
        }
        switch event {
        case let .pointer(action, button, _, x, y, pressure):
            pointer(action: action, button: button, at: mapper.point(x: x, y: y), pressure: Double(pressure))
        case let .scroll(phase, unit, x, y, dx, dy):
            scroll(phase: phase, unit: unit, at: mapper.point(x: x, y: y), delta: unit == .lines ? CGSize(width: CGFloat(dx), height: CGFloat(dy)) : mapper.delta(dx: dx, dy: dy))
        case let .key(action, usage, modifiers):
            key(action: action, usage: usage, modifiers: modifiers)
        case let .text(text):
            type(text)
        }
    }

    /// Releases buttons and modifiers still held when a client disconnects mid-gesture.
    func releaseAll() {
        if let location {
            for (button, clickState) in pressed {
                postMouse(Self.upType(button), button: button, at: location, clickState: clickState, pressure: 0)
            }
        }
        pressed.removeAll()
        if !flags.isEmpty {
            flags = []
            if let event = CGEvent(keyboardEventSource: source, virtualKey: 0x38, keyDown: false) {
                event.type = .flagsChanged
                event.flags = []
                event.post(tap: .cghidEventTap)
            }
        }
    }

    // MARK: Pointer

    private func pointer(action: PointerAction, button: PointerButton, at point: CGPoint, pressure: Double) {
        switch action {
        case .move:
            let type: CGEventType
            let dragButton: PointerButton
            if pressed[.left] != nil {
                (type, dragButton) = (.leftMouseDragged, .left)
            } else if pressed[.right] != nil {
                (type, dragButton) = (.rightMouseDragged, .right)
            } else if pressed[.middle] != nil {
                (type, dragButton) = (.otherMouseDragged, .middle)
            } else {
                (type, dragButton) = (.mouseMoved, .left)
            }
            postMouse(type, button: dragButton, at: point, clickState: pressed[dragButton] ?? 0, pressure: pressure)
        case .down:
            guard pressed[button] == nil else { return }
            let clickState = clicks.register(button, at: point, time: ProcessInfo.processInfo.systemUptime, interval: NSEvent.doubleClickInterval)
            pressed[button] = clickState
            postMouse(Self.downType(button), button: button, at: point, clickState: clickState, pressure: pressure)
        case .up, .cancel:
            guard let clickState = pressed.removeValue(forKey: button) else { return }
            postMouse(Self.upType(button), button: button, at: point, clickState: clickState, pressure: 0)
        }
    }

    private func postMouse(_ type: CGEventType, button: PointerButton, at point: CGPoint, clickState: Int64, pressure: Double) {
        let cgButton: CGMouseButton = switch button {
        case .left: .left
        case .right: .right
        case .middle: .center
        }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: cgButton) else { return }
        if let location {
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64(point.x - location.x))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64(point.y - location.y))
        }
        if clickState > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
        }
        if button == .middle {
            event.setIntegerValueField(.mouseEventButtonNumber, value: 2)
        }
        event.setDoubleValueField(.mouseEventPressure, value: pressure)
        event.flags = flags
        event.post(tap: .cghidEventTap)
        location = point
    }

    private static func downType(_ button: PointerButton) -> CGEventType {
        switch button {
        case .left: .leftMouseDown
        case .right: .rightMouseDown
        case .middle: .otherMouseDown
        }
    }

    private static func upType(_ button: PointerButton) -> CGEventType {
        switch button {
        case .left: .leftMouseUp
        case .right: .rightMouseUp
        case .middle: .otherMouseUp
        }
    }

    // MARK: Scroll

    private func scroll(phase: ScrollPhase, unit: ScrollUnit, at point: CGPoint, delta: CGSize) {
        // Scroll events go to the window under the cursor, so move it there first.
        if pressed.isEmpty, phase == .began || phase == .none, location != point {
            postMouse(.mouseMoved, button: .left, at: point, clickState: 0, pressure: 0)
        }

        let event: CGEvent?
        if unit == .lines {
            event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: Int32(delta.height.rounded()), wheel2: Int32(delta.width.rounded()), wheel3: 0)
        } else {
            let total = CGSize(width: delta.width + scrollRemainder.width, height: delta.height + scrollRemainder.height)
            let whole = CGSize(width: total.width.rounded(.towardZero), height: total.height.rounded(.towardZero))
            scrollRemainder = CGSize(width: total.width - whole.width, height: total.height - whole.height)
            event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: Int32(whole.height), wheel2: Int32(whole.width), wheel3: 0)
            event?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        }
        guard let event else { return }

        switch phase {
        case .none:
            break
        case .began:
            inMomentum = false
            scrollRemainder = .zero
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 1)
        case .changed:
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)
        case .ended:
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)
        case .momentum:
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: inMomentum ? 2 : 1)
            inMomentum = true
        case .momentumEnded:
            event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 3)
            inMomentum = false
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    // MARK: Keyboard

    private func key(action: KeyAction, usage: UInt16, modifiers: KeyModifiers) {
        flags = Self.flags(for: modifiers)
        guard let keyCode = HIDKeyMap.keyCode(forUsage: usage),
              let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: action == .down)
        else { return }

        if HIDKeyMap.modifierFlag(forUsage: usage) != nil {
            event.type = .flagsChanged
            event.flags = flags
        } else {
            var keyFlags = flags
            // Real arrow, navigation and function keys carry these flags; some apps check them.
            if (0x7B...0x7E).contains(keyCode) {
                keyFlags.formUnion([.maskNumericPad, .maskSecondaryFn])
            } else if [0x72, 0x73, 0x74, 0x75, 0x77, 0x79].contains(keyCode) || (0x3A...0x45).contains(usage) {
                keyFlags.insert(.maskSecondaryFn)
            }
            event.flags = keyFlags
        }
        event.post(tap: .cghidEventTap)
    }

    private func type(_ text: String) {
        let units = Array(text.utf16)
        // CGEventKeyboardSetUnicodeString accepts at most 20 UTF-16 units per event.
        var index = 0
        while index < units.count {
            var end = min(index + 20, units.count)
            // Don't split a surrogate pair.
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) {
                end -= 1
            }
            let chunk = Array(units[index..<end])
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
                chunk.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
                event.flags = []
                event.post(tap: .cghidEventTap)
            }
            index = end
        }
    }

    static func flags(for modifiers: KeyModifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.capsLock) { flags.insert(.maskAlphaShift) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }
}
