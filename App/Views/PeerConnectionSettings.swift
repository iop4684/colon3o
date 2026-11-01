import SoulseekKit
import SwiftUI

/// Settings › Soulseek: whether other users can connect to you, and the switches for it.
struct PeerConnectionSettings: View {
    @EnvironmentObject private var soulseek: SoulseekModel
    @EnvironmentObject private var sharing: PortSharing
    @AppStorage(PortSharing.openRouterPortKey) private var openRouterPort = true
    @AppStorage(PortSharing.shareOnlyOnWiFiKey) private var shareOnlyOnWiFi = true
    @State private var portText = ""

    var body: some View {
        Section {
            LabeledContent("Listening") { listenerValue }
            LabeledContent("Router") { routerValue }
            LabeledContent("From Outside") { checkValue }
            Button("Check Port Now") { sharing.checkPort() }
                .disabled(!soulseek.isLoggedIn || sharing.check == .checking)
            if case .failed = sharing.router {
                Button("Try the Router Again") { sharing.tryAgain() }
            }
        } header: {
            Text("Peer Connections")
        } footer: {
            Text(statusFooter)
        }

        Section {
            Toggle("Open Port on Router", isOn: $openRouterPort)
                .onChange(of: openRouterPort) { _, _ in sharing.settingsChanged() }
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
            Text("Open Port on Router asks your home router to forward the port to this phone (NAT-PMP or UPnP), only on Wi-Fi, for an hour at a time while colon3o is online. Share Only on Wi-Fi pauses uploads on mobile data; people's requests wait until you're back on Wi-Fi. The port must be between 1024 and 65535; 2234 is Soulseek's usual one.")
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
    private var routerValue: some View {
        switch sharing.router {
        case let .off(reason):
            Text(reason).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        case .working:
            ProgressView()
        case let .opened(method, externalPort):
            VStack(alignment: .trailing, spacing: 1) {
                Label("Opened with \(method)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if externalPort != sharing.port {
                    Text("Outside port \(String(externalPort))").font(.caption).foregroundStyle(.secondary)
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
        var parts: [String] = []
        switch sharing.check {
        case .open:
            parts.append("Other users can connect to you, so you get search results and downloads from people who can't accept connections themselves.")
        case let .closed(port):
            if !sharing.onWiFi {
                parts.append("On mobile data the port can't be opened; it works on Wi-Fi.")
            } else if let localIP = sharing.localIP {
                parts.append("Peers can't reach you yet. In your router's settings, turn on UPnP, or forward TCP port \(String(port)) to this phone (\(localIP)).")
            } else {
                parts.append("Peers can't reach you yet. Turn on UPnP in your router's settings, or forward TCP port \(String(port)) to this phone.")
            }
        default:
            parts.append("When your port is open, people who can't accept connections can still send you search results and files. Without it you only reach people whose own port is open.")
        }
        if let note = sharing.providerNote { parts.append(note) }
        return parts.joined(separator: " ")
    }
}
