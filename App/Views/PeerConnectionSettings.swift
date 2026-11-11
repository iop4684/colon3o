import SoulseekKit
import SwiftUI

/// Settings › Soulseek: whether other users can connect to you, and the switches for it.
struct PeerConnectionSettings: View {
    @EnvironmentObject private var soulseek: SoulseekModel
    @EnvironmentObject private var sharing: PortSharing
    @AppStorage(PortSharing.shareOnlyOnWiFiKey) private var shareOnlyOnWiFi = false
    @State private var portText = ""

    var body: some View {
        Section {
            LabeledContent("Listening") { listenerValue }
            LabeledContent("From Outside") { checkValue }
            Button("Check Port Now") { sharing.checkPort() }
                .disabled(!soulseek.isLoggedIn || sharing.check == .checking)
        } header: {
            Text("Peer Connections")
        } footer: {
            Text(statusFooter)
        }

        Section {
            Toggle("Share Only on Wi-Fi", isOn: $shareOnlyOnWiFi)
                .onChange(of: shareOnlyOnWiFi) { _, _ in sharing.settingsChanged() }
            HStack {
                Text("Port")
                TextField(String(PortSharing.defaultPort), text: $portText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                if let pending = pendingPort {
                    Button("Use") {
                        sharing.setPort(pending)
                        portText = String(pending)
                    }
                    .buttonStyle(.borderless)
                }
            }
        } footer: {
            Text("colon3o listens on this port; your VPN (or router) has to forward the same TCP port to this phone. Share Only on Wi-Fi pauses uploads on mobile data; people's requests wait until you're back on Wi-Fi. The port must be between 1024 and 65535; 2234 is Soulseek's usual one.")
        }
        .onAppear { portText = String(sharing.port) }
    }

    /// A valid port that differs from the one in use, ready to apply.
    private var pendingPort: UInt16? {
        guard let value = Int(portText.trimmingCharacters(in: .whitespaces)), PortSharing.portRange.contains(value),
              UInt16(value) != sharing.port else { return nil }
        return UInt16(value)
    }

    @ViewBuilder
    private var listenerValue: some View {
        switch soulseek.listenerStatus {
        case .off:
            Text(soulseek.isLoggedIn ? "Off" : "Offline").foregroundStyle(.secondary)
        case let .listening(port, accepted):
            VStack(alignment: .trailing, spacing: 1) {
                Text("Port \(String(port))")
                if accepted > 0 {
                    Text("\(accepted) connection\(accepted == 1 ? "" : "s") from peers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case let .failed(message):
            Text(message).foregroundStyle(.orange).multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private var checkValue: some View {
        switch sharing.check {
        case .unknown:
            Text("Not checked").foregroundStyle(.secondary)
        case .checking:
            ProgressView()
        case .open:
            Label("Open", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .closed:
            Label("Closed", systemImage: "xmark.circle.fill").foregroundStyle(.orange)
        case let .failed(message):
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private var statusFooter: String {
        switch sharing.check {
        case .open:
            return "Other users can connect to you, so you get search results and downloads from people who can't accept connections themselves."
        case let .closed(port):
            return "Peers can't reach you. Turn on the VPN that forwards TCP port \(String(port)) to this phone, then check again."
        default:
            return "When your port is open, people who can't accept connections can still send you search results and files. Without it you only reach people whose own port is open."
        }
    }
}
