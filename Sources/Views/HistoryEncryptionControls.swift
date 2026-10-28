import SwiftUI

/// Encryption is opt-in. This view reviews the change before migrating the
/// history tree; the key never appears in application preferences or exports.
struct HistoryEncryptionControls: View {
    @Environment(ConfigStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.historyEncryptionBusy {
                ProgressView(L("Changing history encryption…"))
                    .accessibilityIdentifier("history-encryption-progress")
            } else if store.historyEncryptionStatus?.needsResume == true {
                Label(L("History encryption change is incomplete. Resume it before recording history."),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                Button(L("Resume encryption change")) { store.retryHistoryEncryption() }
                    .disabled(store.historyPurgeBlocked)
                    .accessibilityIdentifier("history-encryption-resume")
            } else if let status = store.historyEncryptionStatus {
                Label(L(status.enabled ? "Local history is encrypted." : "Local history is stored as plain text."),
                      systemImage: status.enabled ? "lock.shield" : "lock.open")
                    .font(.callout)
                Button(L(status.enabled ? "Decrypt history…" : "Encrypt history…")) {
                    store.requestHistoryEncryption(enabled: !status.enabled)
                }
                .disabled(store.historyPurgeBlocked || store.historyEncryptionError != nil)
                .accessibilityIdentifier("history-encryption-change")
            } else if store.historyEncryptionError != nil {
                Text(L("History encryption status is unavailable.")).font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView(L("Checking history encryption…"))
            }
            if let error = store.historyEncryptionError {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red)
                    Button(L("Retry")) { store.retryHistoryEncryption() }
                        .disabled(store.historyPurgeBlocked)
                        .accessibilityIdentifier("history-encryption-retry")
                }
            }
            Text(L("The encryption key stays in this Mac's Keychain. Losing access to the key makes encrypted history unreadable. Legacy backup folder names remain visible. Config files are not encrypted."))
                .font(.callout).foregroundStyle(.secondary)
        }
        .task { store.loadHistoryEncryptionStatus() }
        .confirmationDialog(
            L(store.pendingHistoryEncryption?.enabled == true ? "Encrypt all local history?" : "Decrypt all local history?"),
            isPresented: Binding(
                get: { store.pendingHistoryEncryption != nil },
                set: { if !$0 { store.cancelHistoryEncryption() } }
            ), titleVisibility: .visible, presenting: store.pendingHistoryEncryption
        ) { review in
            Button(L(review.enabled ? "Encrypt history" : "Decrypt history")) { store.confirmHistoryEncryption() }
                .accessibilityIdentifier("history-encryption-confirm")
            Button(L("Cancel"), role: .cancel) { store.cancelHistoryEncryption() }
        } message: { review in
            Text(L(review.enabled
                ? "Encrypts existing snapshots, indexes and legacy backups, and future history. The key is stored only in this Mac's Keychain. Close older AgentsConfig versions first. Config files are unchanged."
                : "Writes existing history and future snapshots as plain text protected by file permissions. Close older AgentsConfig versions first. Config files are unchanged."))
        }
    }
}
