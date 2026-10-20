import Foundation

public enum PointerAction: UInt8, Sendable {
    case move = 0
    case down = 1
    case up = 2
    /// The gesture was aborted; the host releases the button without clicking twice.
    case cancel = 3
}

public enum PointerButton: UInt8, Sendable, CaseIterable {
    case left = 0
    case right = 1
    case middle = 2
}

public enum PointerTool: UInt8, Sendable {
    case mouse = 0
    case finger = 1
    case stylus = 2
}

public enum ScrollPhase: UInt8, Sendable {
    /// A discrete wheel step without a gesture.
    case none = 0
    case began = 1
    case changed = 2
    case ended = 3
    case momentum = 4
    case momentumEnded = 5
}

public enum ScrollUnit: UInt8, Sendable {
    /// Fractions of the video frame width / height (pixel-precise gestures).
    case normalized = 0
    /// Wheel lines.
    case lines = 1
}

public enum KeyAction: UInt8, Sendable {
    case down = 1
    case up = 2
}

public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
    public static let capsLock = KeyModifiers(rawValue: 1 << 4)
    public static let function = KeyModifiers(rawValue: 1 << 5)
}

/// INPUT (client → host). Coordinates are normalized to the video frame (0...1).
public enum InputEvent: Sendable, Equatable {
    case pointer(action: PointerAction, button: PointerButton, tool: PointerTool, x: Float, y: Float, pressure: Float)
    /// Positive `dy` moves the content down (the finger moved down), like a touch screen.
    case scroll(phase: ScrollPhase, unit: ScrollUnit, x: Float, y: Float, dx: Float, dy: Float)
    /// `usage` is a USB HID usage ID from the Keyboard/Keypad page (0x07).
    case key(action: KeyAction, usage: UInt16, modifiers: KeyModifiers)
    /// Text committed by a soft keyboard or an input method.
    case text(String)

    enum Kind: UInt8 {
        case pointer = 0x01
        case scroll = 0x02
        case key = 0x03
        case text = 0x04
    }

    public init(_ message: Message) throws {
        var reader = ByteReader(message.payload)
        guard let kind = Kind(rawValue: try reader.u8()) else {
            throw ProtocolError.invalidPayload("unknown input kind")
        }
        switch kind {
        case .pointer:
            guard let action = PointerAction(rawValue: try reader.u8()) else {
                throw ProtocolError.invalidPayload("pointer action")
            }
            let button = PointerButton(rawValue: try reader.u8()) ?? .left
            let tool = PointerTool(rawValue: try reader.u8()) ?? .mouse
            try reader.skip(1)
            self = .pointer(action: action, button: button, tool: tool, x: try reader.f32(), y: try reader.f32(), pressure: try reader.f32())
        case .scroll:
            let phase = ScrollPhase(rawValue: try reader.u8()) ?? .none
            let unit = ScrollUnit(rawValue: try reader.u8()) ?? .normalized
            try reader.skip(2)
            self = .scroll(phase: phase, unit: unit, x: try reader.f32(), y: try reader.f32(), dx: try reader.f32(), dy: try reader.f32())
        case .key:
            guard let action = KeyAction(rawValue: try reader.u8()) else {
                throw ProtocolError.invalidPayload("key action")
            }
            try reader.skip(1)
            self = .key(action: action, usage: try reader.u16(), modifiers: KeyModifiers(rawValue: try reader.u16()))
        case .text:
            guard let text = String(data: reader.rest(), encoding: .utf8) else {
                throw ProtocolError.invalidPayload("text is not UTF-8")
            }
            self = .text(text)
        }
    }

    public func message() -> Message {
        var writer = ByteWriter(capacity: 24)
        switch self {
        case let .pointer(action, button, tool, x, y, pressure):
            writer.u8(Kind.pointer.rawValue)
            writer.u8(action.rawValue)
            writer.u8(button.rawValue)
            writer.u8(tool.rawValue)
            writer.u8(0)
            writer.f32(x)
            writer.f32(y)
            writer.f32(pressure)
        case let .scroll(phase, unit, x, y, dx, dy):
            writer.u8(Kind.scroll.rawValue)
            writer.u8(phase.rawValue)
            writer.u8(unit.rawValue)
            writer.u16(0)
            writer.f32(x)
            writer.f32(y)
            writer.f32(dx)
            writer.f32(dy)
        case let .key(action, usage, modifiers):
            writer.u8(Kind.key.rawValue)
            writer.u8(action.rawValue)
            writer.u8(0)
            writer.u16(usage)
            writer.u16(modifiers.rawValue)
        case let .text(text):
            writer.u8(Kind.text.rawValue)
            writer.bytes(Data(text.utf8))
        }
        return Message(type: .input, payload: writer.data)
    }
}
