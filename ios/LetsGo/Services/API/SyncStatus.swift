import SwiftUI
import Observation

/// Whether the last pull from the server worked, for the map's status pill.
@Observable
final class SyncStatus {
    private(set) var lastSynced: Date?
    private(set) var problem: String?
    private(set) var syncing = false

    var isOnline: Bool { APIConfig.isConfigured && problem == nil && lastSynced != nil }

    func run(_ work: () async throws(APIError) -> Void) async {
        guard APIConfig.isConfigured, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            try await work()
            lastSynced = .now
            problem = nil
        } catch let error where error.isNotOnServer {
            // An older server without that part: the feature says so where it lives.
            lastSynced = .now
            problem = nil
        } catch {
            problem = error.errorDescription
        }
    }
}

extension View {
    /// Shows `message` as an alert while it's non-nil.
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert(
            "Couldn't do that",
            isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

/// Runs an action that may hit the server, turning a failure into alert text.
@MainActor
func attempt(_ message: Binding<String?>, _ work: () async throws(APIError) -> Void) async {
    do {
        try await work()
    } catch {
        message.wrappedValue = error.errorDescription
    }
}
