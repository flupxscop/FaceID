import Darwin
import FaceIDBrokerKit
import FaceIDCore

// `--check-isolation`: exit 0 only when the sandbox blocks networking (used by build/install scripts).
if CommandLine.arguments.contains("--check-isolation") {
    exit(NetworkLockdown.isNetworkBlocked() ? 0 : 1)
}

BrokerRuntime(configuration: .load()).run()
