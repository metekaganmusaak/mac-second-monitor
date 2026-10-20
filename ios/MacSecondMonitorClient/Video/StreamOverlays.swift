import SwiftUI

/// Keyboard toggle and options, kept small and translucent in a corner of the stream.
struct StreamControls: View {
    @Binding var showsKeyboard: Bool
    @Binding var showsStats: Bool
    let onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button {
                showsKeyboard.toggle()
            } label: {
                Image(systemName: showsKeyboard ? "keyboard.chevron.compact.down" : "keyboard")
                    .frame(width: 40, height: 36)
            }
            .accessibilityLabel(showsKeyboard ? Text("stream.keyboard.hide") : Text("stream.keyboard.show"))

            Menu {
                Button {
                    showsStats.toggle()
                } label: {
                    if showsStats {
                        Label("stream.stats.hide", systemImage: "speedometer")
                    } else {
                        Label("stream.stats.show", systemImage: "speedometer")
                    }
                }
                Button(role: .destructive, action: onDisconnect) {
                    Label("stream.disconnect", systemImage: "xmark.circle")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 40, height: 36)
            }
            .accessibilityLabel(Text("stream.menu"))
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 4)
        .background(.black.opacity(0.4), in: Capsule())
        .opacity(0.75)
    }
}

/// Shown between WELCOME and the first decoded frame.
struct WaitingForPictureView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.white)
            Text("stream.waiting")
                .font(.headline)
        }
        .foregroundStyle(.white)
        .padding(24)
    }
}

struct ReconnectingView: View {
    let attempt: Int
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.white)
            Text("stream.reconnecting")
                .font(.headline)
            if attempt > 0 {
                Text(L10n.format(String(localized: "stream.reconnecting.attempt"), attempt))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Button("stream.disconnect", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .foregroundStyle(.white)
        .padding(24)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
