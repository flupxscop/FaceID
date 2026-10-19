import Darwin

/// Verifies that the OS sandbox denies this process all network access.
///
/// launchd starts the agent and the broker through `sandbox-exec` (`deny network*`), so even a
/// bug or a compromised dependency cannot send biometric data off the machine. Both check this
/// at startup and, in release builds, refuse to work when it is not enforced.
///
/// This is the only file allowed to touch sockets, and only to confirm they are blocked.
public enum NetworkLockdown {
    public static func isNetworkBlocked() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 {
            return errno == EPERM || errno == EACCES
        }
        defer { close(fd) }

        // Loopback discard port: nothing ever leaves the machine, even when unsandboxed.
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(9).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result != 0 && (errno == EPERM || errno == EACCES)
    }
}
