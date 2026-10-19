import Foundation

/// Global tuning constants. Changing `matchThreshold` or disabling liveness
/// requires explicit sign-off (see CLAUDE.md §11) and fresh FAR/FRR numbers in docs/metrics.md.
public enum FaceIDConfig {
    public static let matchThreshold: Float = 0.62          // cosine similarity — tune from measured FAR/FRR
    public static let enrollmentSamples = 15                // multiple poses: front, left, right, down, up
    public static let scanTimeout: Duration = .seconds(5)
    public static let maxAttemptsBeforeLockout = 3          // after this, password is required
    public static let minFaceCaptureQuality: Float = 0.4
    public static let requiredConsecutiveMatches = 3        // must match on several consecutive frames

    /// Minimum similarity between a new enrollment sample and the frontal samples,
    /// so a different person cannot slip into the template mid-enrollment.
    public static let enrollmentConsistencyThreshold: Float = 0.5

    public static let logSubsystem = "com.example.faceid"
    public static let keychainService = "com.example.faceid"
}

/// Sign convention for Vision head-pose angles as seen by the user.
/// Vision reports yaw/pitch in the image frame; whether positive yaw means the user turned
/// left depends on the camera mirroring. Verify once against a real camera feed and adjust here only.
public enum HeadPoseConvention {
    public static let leftTurnYawSign: Double = 1
    public static let upTiltPitchSign: Double = -1
}

public enum FaceIDStrings {
    /// Must be shown during enrollment and in the README (CLAUDE.md §1).
    public static let twoDCameraWarning = """
    กล้องของ Mac เป็นกล้อง 2D ไม่มีเซนเซอร์วัดความลึกแบบ TrueDepth ของ iPhone \
    ระบบนี้จึงปลอดภัยน้อยกว่า Face ID ของ Apple และอาจถูกหลอกได้ด้วยวิธีที่ซับซ้อน \
    รหัสผ่านยังคงใช้ได้เสมอ และไม่สามารถใช้ปลดล็อก FileVault ตอนบูตเครื่องได้
    """
}
