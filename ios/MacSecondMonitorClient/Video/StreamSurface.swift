import MSMProtocol
import SwiftUI
import UIKit

/// The video layer plus the input surface on top of it.
struct StreamSurface: UIViewRepresentable {
    let output: VideoOutput
    let videoSize: CGSize
    @Binding var showsKeyboard: Bool
    let send: (InputEvent) -> Void
    let onPixelSizeChange: (CGSize) -> Void

    func makeUIView(context: Context) -> StreamSurfaceView {
        StreamSurfaceView(output: output)
    }

    func updateUIView(_ view: StreamSurfaceView, context: Context) {
        view.input.videoSize = videoSize
        view.input.send = send
        view.keyboard.send = send
        view.onPixelSizeChange = onPixelSizeChange
        let showsKeyboard = $showsKeyboard
        view.keyboard.onDismiss = {
            if showsKeyboard.wrappedValue { showsKeyboard.wrappedValue = false }
        }
        view.setSoftKeyboardVisible(self.showsKeyboard)
    }
}

final class StreamSurfaceView: UIView {
    let input = TouchInputView()
    let keyboard: SoftKeyboardView
    var onPixelSizeChange: (CGSize) -> Void = { _ in }

    private let output: VideoOutput
    private var reportedSize = CGSize.zero

    init(output: VideoOutput) {
        self.output = output
        keyboard = SoftKeyboardView(hardwareKeyboard: input.hardwareKeyboard)
        super.init(frame: .zero)
        backgroundColor = .black
        layer.insertSublayer(output.layer, at: 0)

        input.frame = bounds
        input.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        input.isSoftKeyboardActive = { [weak keyboard] in keyboard?.isFirstResponder ?? false }
        addSubview(input)
        // Zero-sized: it only exists to own the on-screen keyboard.
        addSubview(keyboard)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        output.layer.frame = bounds
        CATransaction.commit()

        guard let scale = window?.windowScene?.screen.scale else { return }
        let size = DeviceProfile.pixelSize(points: bounds.size, scale: scale)
        if size != reportedSize {
            reportedSize = size
            onPixelSizeChange(size)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        // The layer is shared; take it back if another surface held it.
        if output.layer.superlayer !== layer {
            layer.insertSublayer(output.layer, at: 0)
            setNeedsLayout()
        }
        if !keyboard.isFirstResponder {
            input.becomeFirstResponder()
        }
    }

    func setSoftKeyboardVisible(_ visible: Bool) {
        if visible {
            if !keyboard.isFirstResponder { keyboard.becomeFirstResponder() }
        } else if !input.isFirstResponder {
            // Hardware keys go to the input surface whenever the soft keyboard is hidden.
            input.becomeFirstResponder()
        }
    }
}
