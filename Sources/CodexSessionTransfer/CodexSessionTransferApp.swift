import SwiftUI

@main
struct CodexSessionTransferApp: App {
    @StateObject private var model = TransferModel()

    var body: some Scene {
        MenuBarExtra("Codex Transfer", systemImage: "arrow.left.arrow.right") {
            TransferView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
