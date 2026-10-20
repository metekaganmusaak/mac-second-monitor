import SwiftUI

/// Pick a Mac: USB status, Macs found with Bonjour, an address field and recent hosts.
struct ConnectView: View {
    @EnvironmentObject private var session: SessionController
    @EnvironmentObject private var recents: RecentHostsStore
    @StateObject private var browser = BonjourBrowser()
    @State private var address = ""
    @State private var addressInvalid = false
    @State private var showsSettings = false

    var body: some View {
        NavigationStack {
            List {
                usbSection
                nearbySection
                manualSection
                if !recents.hosts.isEmpty {
                    recentSection
                }
            }
            .disabled(connectingRoute != nil)
            .overlay {
                if let route = connectingRoute {
                    ConnectingCard(title: connectingTitle(route)) { session.disconnect() }
                }
            }
            .navigationTitle("connect.title")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showsSettings = true
                    } label: {
                        Label("settings.title", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showsSettings) {
                SettingsView()
            }
        }
        .sheet(isPresented: pairingPresented) {
            if let prompt = session.pairingPrompt, let route = session.route {
                PairingSheet(
                    hostName: session.displayName(for: route),
                    prompt: prompt,
                    onSubmit: { session.submitPairingCode($0) },
                    onCancel: { session.cancelPairing() }
                )
            }
        }
        .alert(Text("error.title"), isPresented: failurePresented, presenting: session.failure) { _ in
            Button("common.ok", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    // MARK: Sections

    private var usbSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: "cable.connector")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("connect.usb.title")
                        .font(.headline)
                    Text(usbStatus)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var usbStatus: LocalizedStringKey {
        switch session.usbState {
        case .listening, .inactive: "connect.usb.waiting"
        case .failed: "connect.usb.failed"
        case .unavailable: "connect.usb.simulator"
        }
    }

    private var nearbySection: some View {
        Section {
            if browser.state == .denied {
                Label("connect.nearby.denied", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            } else if browser.services.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("connect.nearby.searching")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(browser.services) { service in
                Button {
                    session.connect(to: service.target)
                } label: {
                    HostRow(systemImage: "desktopcomputer", title: service.name, subtitle: service.isCompatible ? nil : String(localized: "connect.nearby.incompatible"))
                }
                .disabled(!service.isCompatible)
            }
        } header: {
            Text("connect.section.nearby")
        } footer: {
            Text("connect.nearby.footer")
        }
    }

    private var manualSection: some View {
        Section {
            HStack {
                TextField("connect.manual.placeholder", text: $address)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit(connectToAddress)
                    .onChange(of: address) { _ in addressInvalid = false }
                Button("connect.manual.connect", action: connectToAddress)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("connect.section.manual")
        } footer: {
            if addressInvalid {
                Text("connect.manual.invalid")
                    .foregroundStyle(.red)
            }
        }
    }

    private var recentSection: some View {
        Section("connect.section.recent") {
            ForEach(recents.hosts) { host in
                Button {
                    session.connect(to: host.target)
                } label: {
                    HostRow(systemImage: "clock.arrow.circlepath", title: host.title, subtitle: host.subtitle)
                }
            }
            .onDelete { recents.remove(atOffsets: $0) }
        }
    }

    // MARK: Helpers

    private var connectingRoute: SessionRoute? {
        if case let .connecting(route) = session.phase { return route }
        return nil
    }

    private func connectingTitle(_ route: SessionRoute) -> String {
        switch route {
        case .usb: String(localized: "connect.usb.connecting")
        case .network: L10n.format(String(localized: "connect.connecting"), session.displayName(for: route))
        }
    }

    private func connectToAddress() {
        guard let target = HostTarget(parsing: address) else {
            addressInvalid = true
            return
        }
        session.connect(to: target)
    }

    private var pairingPresented: Binding<Bool> {
        Binding(
            get: { session.pairingPrompt != nil },
            set: { if !$0 { session.cancelPairing() } }
        )
    }

    private var failurePresented: Binding<Bool> {
        Binding(
            get: { session.failure != nil },
            set: { if !$0 { session.failure = nil } }
        )
    }
}

private struct HostRow: View {
    let systemImage: String
    let title: String
    let subtitle: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                // Explicit colors: inside a List button, `.primary` would resolve to the tint.
                Text(title)
                    .foregroundStyle(Color(.label))
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Color(.secondaryLabel))
                }
            }
            Spacer()
            // `forward` points left in right-to-left languages.
            Image(systemName: "chevron.forward")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

private struct ConnectingCard: View {
    let title: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Button("common.cancel", role: .cancel, action: onCancel)
                .buttonStyle(.bordered)
        }
        .padding(28)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(radius: 20)
        .padding()
    }
}
