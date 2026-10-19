import Darwin
import FaceIDAgentKit
import FaceIDCore

// `--check-isolation`: exit 0 only when the sandbox blocks networking (used by install.sh).
if CommandLine.arguments.contains("--check-isolation") {
    exit(NetworkLockdown.isNetworkBlocked() ? 0 : 1)
}

AgentRuntime(configuration: .load()).run()
