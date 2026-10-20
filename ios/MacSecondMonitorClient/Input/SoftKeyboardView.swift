import MSMProtocol
import UIKit

/// Invisible responder that brings up the on-screen keyboard. Committed text goes out as TEXT
/// (layout independent); Return, Tab and Backspace as KEY events.
final class SoftKeyboardView: UIView, UIKeyInput {
    var send: (InputEvent) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    private let hardwareKeyboard: HardwareKeyboard

    // UITextInputTraits: the Mac does its own corrections.
    var autocorrectionType = UITextAutocorrectionType.no
    var autocapitalizationType = UITextAutocapitalizationType.none
    var spellCheckingType = UITextSpellCheckingType.no
    var smartQuotesType = UITextSmartQuotesType.no
    var smartDashesType = UITextSmartDashesType.no
    var smartInsertDeleteType = UITextSmartInsertDeleteType.no
    var keyboardType = UIKeyboardType.default
    var keyboardAppearance = UIKeyboardAppearance.dark
    var returnKeyType = UIReturnKeyType.default

    init(hardwareKeyboard: HardwareKeyboard) {
        self.hardwareKeyboard = hardwareKeyboard
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var canBecomeFirstResponder: Bool { true }

    override var inputAccessoryView: UIView? { accessoryBar }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onDismiss() }
        return resigned
    }

    // MARK: UIKeyInput

    /// Always true so Backspace keeps working on an "empty" field.
    var hasText: Bool { true }

    func insertText(_ text: String) {
        var pending = ""
        for character in text {
            switch character {
            case "\n", "\r", "\r\n":
                sendText(&pending)
                tap(HIDUsage.returnKey)
            case "\t":
                sendText(&pending)
                tap(HIDUsage.tab)
            default:
                pending.append(character)
            }
        }
        sendText(&pending)
    }

    func deleteBackward() {
        tap(HIDUsage.backspace)
    }

    // A hardware keyboard typing while this view is focused still sends physical keys.
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

    // MARK: Private

    private func sendText(_ text: inout String) {
        guard !text.isEmpty else { return }
        send(.text(text))
        text = ""
    }

    private func tap(_ usage: UInt16) {
        send(.key(action: .down, usage: usage, modifiers: []))
        send(.key(action: .up, usage: usage, modifiers: []))
    }

    /// Keys the on-screen keyboard lacks but a Mac needs.
    private lazy var accessoryBar: UIToolbar = {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.barStyle = .black
        bar.tintColor = .white
        let dismiss = UIBarButtonItem(image: UIImage(systemName: "keyboard.chevron.compact.down"), primaryAction: UIAction { [weak self] _ in
            self?.resignFirstResponder()
        })
        dismiss.accessibilityLabel = String(localized: "stream.keyboard.hide")
        bar.items = [
            keyItem("escape", String(localized: "keyboard.escape"), HIDUsage.escape),
            keyItem("arrow.right.to.line", String(localized: "keyboard.tab"), HIDUsage.tab),
            .flexibleSpace(),
            keyItem("arrow.left", String(localized: "keyboard.left"), HIDUsage.leftArrow),
            keyItem("arrow.up", String(localized: "keyboard.up"), HIDUsage.upArrow),
            keyItem("arrow.down", String(localized: "keyboard.down"), HIDUsage.downArrow),
            keyItem("arrow.right", String(localized: "keyboard.right"), HIDUsage.rightArrow),
            .flexibleSpace(),
            dismiss,
        ]
        return bar
    }()

    private func keyItem(_ symbol: String, _ label: String, _ usage: UInt16) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: symbol), primaryAction: UIAction { [weak self] _ in
            self?.tap(usage)
        })
        item.accessibilityLabel = label
        return item
    }
}
