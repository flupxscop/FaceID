#if DEBUG
import FaceIDCore
import Foundation

/// VM-only test hook for docs/plugin-vm-test.md E6: macOS guests on Apple silicon have no camera,
/// so the lock-screen `Allow` path (plugin → broker → agent → unlock) cannot be reached by scanning.
///
/// Three locks, all required:
///   1. compiled into debug builds only — release builds do not contain this file
///      (Scripts/build-app.sh fails a release build whose agent contains `marker`);
///   2. the agent runs in a virtual machine (`kern.hv_vmm_present`);
///   3. `flagURL` exists, is owned by root and writable by nobody else (needs sudo to create).
/// The gate is re-checked on every request, so deleting the file turns it off immediately.
public enum ForcedMatchTestMode {
    public static let flagURL = URL(fileURLWithPath: "/Library/Application Support/FaceID/force-match-vm-test")
    /// Present in the agent binary only when this file is compiled in. Keep in sync with build-app.sh and install.sh.
    public static let marker = "FACEID-FORCED-MATCH-VM-TEST"

    public static func isActive(
        flagURL: URL = flagURL,
        isVirtualMachine: Bool = runningInVirtualMachine(),
        isRootProtected: (URL) -> Bool = InstallPins.isRootProtected
    ) -> Bool {
        isVirtualMachine && isRootProtected(flagURL)
    }

    public static func runningInVirtualMachine() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 else { return false }
        return value == 1
    }
}

/// Answers `.match` without the camera while the test mode is active; otherwise runs the real scan.
struct ForcedMatchTestAuthenticator: FaceAuthenticating {
    let wrapped: any FaceAuthenticating
    let isActive: @Sendable () -> Bool

    func authenticate() async -> AuthOutcome {
        guard isActive() else { return await wrapped.authenticate() }
        AgentLog.lifecycle.fault("\(ForcedMatchTestMode.marker, privacy: .public): answering match without a scan")
        return .match
    }

    var isLockedOut: Bool {
        get async { await wrapped.isLockedOut }
    }

    func resetAfterPasswordAuthentication() async {
        await wrapped.resetAfterPasswordAuthentication()
    }
}
#endif
