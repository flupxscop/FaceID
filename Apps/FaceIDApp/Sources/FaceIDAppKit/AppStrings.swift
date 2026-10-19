import FaceIDCore

/// User-facing Thai text for the menu bar app.
public enum AppStrings {
    public static let title = "FaceID"
    public static let enableToggle = "ใช้ใบหน้าปลดล็อก"
    public static let enrolled = "ลงทะเบียนใบหน้าแล้ว"
    public static let notEnrolled = "ยังไม่ได้ลงทะเบียนใบหน้า"
    public static let lockedOut = "พลาดหลายครั้ง ปลดล็อกด้วยรหัสผ่านหนึ่งครั้งเพื่อใช้ใบหน้าได้อีก"
    public static let passwordAlwaysWorks = "รหัสผ่านใช้ปลดล็อกได้เสมอ"

    public static let agentUnreachable = "ติดต่อ FaceIDAgent ไม่ได้ (ยังไม่ได้ติดตั้ง หรือ sign ด้วยใบรับรองคนละใบ)"
    public static let appUnsigned = "แอปนี้ยังไม่ได้ sign ด้วยใบรับรอง จึงยืนยันตัวตนของ agent ไม่ได้ ดู docs/local-signing.md"

    public static let warningTitle = "ก่อนลงทะเบียน"
    public static let warning = FaceIDStrings.twoDCameraWarning
    public static let privacyNote = "ภาพจากกล้องและข้อมูลใบหน้าถูกประมวลผลใน FaceIDAgent บนเครื่องนี้เท่านั้น ไม่ส่งออกจากเครื่อง และไม่บันทึกภาพ"
    public static let acknowledge = "ฉันเข้าใจข้อจำกัดนี้"
    public static let enroll = "ลงทะเบียนใบหน้า"
    public static let reEnroll = "ลงทะเบียนใหม่"
    public static let cancel = "ยกเลิก"
    public static let blinkHint = "กะพริบตาตามปกติหนึ่งครั้ง"
    public static let verifyingOwner = "ยืนยันด้วยรหัสผ่านของ Mac เพื่อบันทึก"

    public static let cameraDenied = "FaceIDAgent ยังไม่ได้รับสิทธิ์ใช้กล้อง เปิดได้ที่ การตั้งค่าระบบ › ความเป็นส่วนตัวและความปลอดภัย › กล้อง"
    public static let openCameraSettings = "เปิดการตั้งค่ากล้อง"
    public static let enrollmentBusy = "เริ่มลงทะเบียนไม่ได้ในตอนนี้ ลองใหม่อีกครั้ง"
    public static let enrollmentDone = "ลงทะเบียนสำเร็จ เปิด \"ใช้ใบหน้าปลดล็อก\" เพื่อเริ่มใช้งาน"
    public static let enrollmentFailed = "ลงทะเบียนไม่สำเร็จ (หมดเวลา, ไม่พบการกะพริบตา หรือยืนยันรหัสผ่านไม่ผ่าน) ข้อมูลที่เก็บมาถูกลบแล้ว"
    public static let enrollmentCancelled = "ยกเลิกการลงทะเบียนแล้ว ข้อมูลที่เก็บมาถูกลบแล้ว"

    public static let delete = "ลบข้อมูลใบหน้า"
    public static let deleteConfirm = "ยืนยันการลบ"
    public static let deleteDone = "ลบข้อมูลใบหน้าและกุญแจเข้ารหัสแล้ว"
    public static let deleteFailed = "ลบไม่สำเร็จ"
    public static let quit = "ออกจาก FaceID"

    public static let keychainApprovalNeeded = "FaceID ถูกอัปเดต ต้องอนุญาตให้อ่านข้อมูลใบหน้าใน Keychain อีกครั้ง (ระหว่างนี้หน้าล็อกใช้รหัสผ่าน)"
    public static let approveKeychain = "อนุญาต"
    public static let approveKeychainHint = "ในหน้าต่างที่ขึ้นมา ใส่รหัสผ่านเครื่องแล้วกด Always Allow (ให้สิทธิ์เฉพาะ FaceIDAgent ตัวนี้) อาจขึ้น 2 ครั้ง"
    public static let approveKeychainDone = "อนุญาตแล้ว ใช้ใบหน้าได้ตามเดิม"
    public static let approveKeychainFailed = "ยังไม่ได้รับอนุญาต (ถ้ากด Allow แทน Always Allow ต้องอนุญาตใหม่ทุกครั้ง)"

    public static let testScan = "ทดสอบสแกนใบหน้า"
    public static let testScanHint = "มองกล้อง กะพริบตา แล้วหันหน้าซ้ายและขวาเล็กน้อย (ไม่ได้ปลดล็อกอะไร)"
    public static let testScanRunning = "กำลังสแกน…"
    public static let testScanMatch = "✅ จำใบหน้าได้"
    public static let testScanNoMatch = "ไม่ตรงกับใบหน้าที่ลงทะเบียน"
    public static let testScanLiveness = "ไม่ผ่านการตรวจว่าเป็นคนจริง: กะพริบตาและหันหน้าซ้าย–ขวาเล็กน้อย"
    public static let testScanTimeout = "หมดเวลา: ไม่พบใบหน้าที่ชัดพอ"
    public static let testScanError = "สแกนไม่ได้ (ปิดใช้งานอยู่ ถูกล็อกชั่วคราว หรือยังไม่มีโมเดล)"
}
