import AppKit
import SwiftUI

struct TransferView: View {
    @ObservedObject var model: TransferModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sendSection
            Divider()
            receiveSection
            if !model.status.isEmpty {
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(16)
        .frame(width: 400)
        .onChange(of: model.sessionID) { _, _ in
            model.preview = nil
        }
    }

    private var sendSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Send session")
                .font(.headline)
            TextField("Session id", text: $model.sessionID)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.lookup() }
            if let preview = model.preview {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.title)
                        .lineLimit(2)
                    Text(preview.threadID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("\(preview.homeKind.label) · \(model.sizeLabel(preview.rolloutBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Button("Look up") {
                model.lookup()
            }
            .disabled(model.isBusy || model.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Text("Destination")
                .font(.headline)
                .padding(.top, 4)
            Text(destinationSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.peers.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.peers) { peer in
                        let selected = model.selectedPeerID == peer.id
                        Button {
                            model.selectPeer(peer.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(peer.name)
                                        .foregroundStyle(.primary)
                                    Text(peer.receiving ? "Receiving" : "App isn't open")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            TextField("Pairing code", text: $model.pairingCode)
                .textFieldStyle(.roundedBorder)
            Button {
                model.send()
            } label: {
                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Send")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isBusy || model.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var destinationSummary: String {
        if let discoveryNote = model.discoveryNote, model.peers.isEmpty {
            return discoveryNote
        }
        if model.peers.isEmpty {
            return "Looking for other Macs…"
        }
        if let id = model.selectedPeerID, let peer = model.peers.first(where: { $0.id == id }) {
            return "Sending to \(peer.name)"
        }
        return "Choose a Mac"
    }

    private var receiveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Receive on this Mac", isOn: Binding(
                get: { model.listening },
                set: { model.setListening($0) }
            ))
            if model.listening {
                if model.localCode.isEmpty {
                    Text("Starting…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(model.localCode)
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Text(model.listenAddress)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    HStack {
                        Button("Copy code") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.localCode, forType: .string)
                            model.status = "Copied the pairing code."
                        }
                        Button("New code") {
                            model.regenerateCode()
                        }
                    }
                }
            }
            if let lastImported = model.lastImported {
                Text(lastImported)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
