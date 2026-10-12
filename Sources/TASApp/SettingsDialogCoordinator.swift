#if os(macOS)
/// A settings editor owns the operation slot until its actual dismissal.
/// Submission checks synchronously on the main actor; rejection keeps inputs.
struct SettingsDialogCoordinator {
    private(set) var isPresented = false
    var allowsBackgroundOperation: Bool { !isPresented }
    mutating func reserve(connected: Bool, busy: Bool, otherDialog: Bool) -> Bool {
        guard connected, !busy, !otherDialog, !isPresented else { return false }
        isPresented = true
        return true
    }
    func canSubmit(connected: Bool, busy: Bool, otherDialog: Bool) -> Bool {
        isPresented && connected && !busy && !otherDialog
    }
    mutating func dismiss() { isPresented = false }
}
#endif
