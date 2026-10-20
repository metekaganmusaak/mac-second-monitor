import SwiftUI

/// Asks for the code shown on the Mac. Submits automatically once all digits are typed.
struct PairingSheet: View {
    let hostName: String
    let prompt: PairingPrompt
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var code = ""
    @State private var submitted = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "lock.laptopcomputer")
                    .font(.system(size: 52))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text(hostName)
                        .font(.title3.weight(.semibold))
                    Text(L10n.format(String(localized: "pairing.prompt"), prompt.codeLength))
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)

                TextField("pairing.code", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(size: 40, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .focused($fieldFocused)
                    .disabled(submitted)
                    .onChange(of: code) { codeChanged($0) }

                if prompt.isRetry {
                    Label(L10n.format(String(localized: "pairing.retry"), prompt.attemptsLeft), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }

                Button(action: submit) {
                    if submitted {
                        ProgressView()
                            .frame(maxWidth: 200)
                    } else {
                        Text("pairing.submit")
                            .frame(maxWidth: 200)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(code.count != prompt.codeLength || submitted)

                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle("pairing.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel", action: onCancel)
                }
            }
        }
        .onAppear { fieldFocused = true }
        .onChange(of: prompt) { _ in
            // The Mac answered with a new prompt: the code was wrong.
            code = ""
            submitted = false
            fieldFocused = true
        }
    }

    private func codeChanged(_ value: String) {
        let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(prompt.codeLength))
        if digits != value {
            code = digits
            return
        }
        if digits.count == prompt.codeLength {
            submit()
        }
    }

    private func submit() {
        guard code.count == prompt.codeLength, !submitted else { return }
        submitted = true
        onSubmit(code)
    }
}
