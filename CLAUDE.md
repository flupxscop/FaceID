# CLAUDE.md — Project FaceID for macOS

ไฟล์นี้อธิบายโปรเจกต์ให้ Claude (และนักพัฒนา) เข้าใจบริบท สถาปัตยกรรม ข้อจำกัด และกฎการทำงาน
อ่านไฟล์นี้ทั้งหมดก่อนแก้โค้ดทุกครั้ง

---

## 1. ภาพรวมโปรเจกต์

**FaceID for macOS** คือระบบสแกนใบหน้าผ่านกล้อง FaceTime/กล้องภายนอก เพื่อปลดล็อก Mac
ในกรณี **หน้าจอล็อก / Screensaver** (หลังจากผู้ใช้ล็อกอินครั้งแรกแล้ว) และ (ทางเลือก) ใช้ยืนยัน `sudo`

### เป้าหมาย
- ลงทะเบียนใบหน้า (Enrollment) ผ่านแอป Menu Bar
- ปลดล็อกหน้าจอด้วยใบหน้าภายใน ~1–2 วินาที
- มี Liveness Detection กันการใช้รูปถ่าย/วิดีโอ
- **ต้องมีทางสำรองเป็นรหัสผ่านเสมอ** — ห้ามสร้างสถานการณ์ที่ผู้ใช้ถูกล็อกออกจากเครื่อง

### สิ่งที่ "ไม่อยู่ในขอบเขต" (ทำไม่ได้/ไม่ควรทำ)
- **ปลดล็อก FileVault ตอนบูตเครื่อง** — macOS บังคับใช้รหัสผ่านเพื่อถอดรหัสดิสก์ ทำแทนไม่ได้
- **แทนที่ Touch ID / Secure Enclave ของระบบ** — API ของ LocalAuthentication ไม่เปิดให้เพิ่ม biometric ใหม่
- **ปลดล็อก Login Keychain** โดยไม่มีรหัสผ่าน — ห้ามเก็บรหัสผ่านผู้ใช้ไว้เพื่อ "พิมพ์แทน"
- ห้ามปิด SIP หรือแนะนำให้ผู้ใช้ปิด SIP

> ⚠️ กล้อง 2D ทั่วไปไม่มีข้อมูลความลึกแบบ TrueDepth จึงปลอดภัยน้อยกว่า Face ID ของ iPhone
> ต้องระบุคำเตือนนี้ใน UI ตอน Enrollment และ README

---

## 2. Tech Stack

| ส่วน | เทคโนโลยี |
|---|---|
| ภาษา | Swift 6 (strict concurrency) |
| OS ขั้นต่ำ | macOS 14 Sonoma |
| กล้อง | AVFoundation (`AVCaptureSession`, `AVCaptureVideoDataOutput`) |
| ตรวจจับใบหน้า | Vision (`VNDetectFaceRectanglesRequest`, `VNDetectFaceLandmarksRequest`, `VNDetectFaceCaptureQualityRequest`) |
| จดจำใบหน้า | Core ML — โมเดล face embedding (เช่น ArcFace/MobileFaceNet แปลงเป็น `.mlpackage`) |
| เก็บข้อมูล | Keychain + เข้ารหัสด้วย CryptoKit (คีย์ใน Secure Enclave ถ้ามี) |
| สื่อสารข้ามโปรเซส | XPC (`NSXPCConnection`, Mach service) |
| ปลดล็อกหน้าจอ | macOS Authorization Plugin (`SecurityAgentPlugins`) |
| sudo (ทางเลือก) | PAM module (C) `pam_faceid.so` |
| UI | SwiftUI + `MenuBarExtra` |
| ทดสอบ | Swift Testing / XCTest |

> ตรวจสอบ license ของโมเดล embedding ก่อนใช้ — โมเดลบางตัวห้ามใช้เชิงพาณิชย์

---

## 3. สถาปัตยกรรม

```
 macOS lock screen
        │
┌───────▼─────────────────────┐  XPC (system)  ┌──────────────────────┐  XPC   ┌───────────────────────────┐
│ FaceIDAuthPlugin            │ ─────────────▶ │ FaceIDBroker          │ ─────▶ │ FaceIDAgent (LaunchAgent)  │
│ (SecurityAgentHelper,       │ ◀───────────── │ (LaunchDaemon, root,  │ ◀───── │  - กล้อง + Vision + CoreML  │
│  รันเป็น _securityagent)     │  code + uid    │  ส่งต่อเฉพาะคำขอ/ผล)   │  code  │  - Liveness, Matching      │
└─────────────────────────────┘                └──────────────────────┘        └──────────────┬────────────┘
        │ fallback: password                     จับคู่ด้วย audit session             agent เชื่อมต่อออกไป
                                                                                  ลงทะเบียนกับ broker เอง
┌────────────────────┐   XPC (per-user)                                        ┌──────────▼──────────┐
│ FaceIDApp (MenuBar) │ ─────────────────────────────────────────────────────▶ │ FaceIDCore (lib)     │
│ Enrollment, เปิด/ปิด │                                                         │ TemplateStore        │
└────────────────────┘                                                         │ (Keychain+CryptoKit) │
                                                                               └─────────────────────┘
```

**เหตุผลที่ต้องแยก LaunchAgent:** Authorization Plugin รันในโปรเซสของ Apple
ซึ่งเข้าถึงกล้อง (TCC) ได้ยาก จึงให้ LaunchAgent ใน session ของผู้ใช้ (ได้สิทธิ์กล้องแล้ว)
เป็นผู้สแกน แล้วส่งผลกลับผ่าน XPC

**เหตุผลที่ต้องมี FaceIDBroker:** plugin ถูกโหลดใน `SecurityAgentHelper` ซึ่งรันเป็น `_securityagent`
จึงค้นหา Mach service ใน launchd domain ของผู้ใช้ไม่ได้ (ยืนยันใน VM แล้ว) broker เป็น LaunchDaemon
ที่มี service ระดับระบบ agent เชื่อมต่อ**ออกไป**ลงทะเบียนกับ broker และ broker จับคู่ plugin กับ agent
จาก audit session เดียวกัน
- broker ส่งต่อแค่ "สแกน/ยกเลิก" และผลลัพธ์ (ตัวเลข + uid ของ agent ที่ตอบ) ห้ามแตะข้อมูลชีวมิติ
- ทุกฝั่งตรวจ code signature: broker sign แบบ **ad-hoc** และถูกตรวจด้วย identifier + **cdhash** (ภายใน SecurityAgentHelper
  ตรวจใบรับรองที่ไม่ใช่ของ Apple ไม่ได้ — ยืนยันใน VM) ส่วน broker ตรวจ agent ด้วยใบรับรอง, รับ plugin เฉพาะ host ของ Apple
- ค่าที่ต้องตรวจอยู่ใน `/Library/Application Support/FaceID/pins.plist` (เขียนโดย install.sh, root เท่านั้นแก้ได้)
- agent เปิดให้ broker เรียกได้แค่ `FaceIDUnlockServiceProtocol` (สแกน/ยกเลิก) — enrollment/ลบ ทำได้จากแอปเท่านั้น
- ห้ามใช้ private API ของ Apple เพื่อข้ามขอบเขตผู้ใช้

### Flow การปลดล็อก
1. ผู้ใช้ปลุกเครื่อง → หน้าล็อกเรียก mechanism ของ `FaceIDAuthPlugin`
2. Plugin ส่ง `authenticate(requestID:)` ผ่าน XPC ไปที่ `FaceIDBroker` ซึ่งส่งต่อให้ `FaceIDAgent` ใน audit session เดียวกัน
3. Agent เปิดกล้อง → ตรวจคุณภาพภาพ → Liveness → สร้าง embedding → เทียบกับ template
4. ผลลัพธ์: `.match` / `.noMatch` / `.livenessFailed` / `.timeout` / `.error`
5. `.match` → plugin ตั้งผล `kAuthorizationResultAllow`
6. อย่างอื่น (ไม่ match, timeout, error, agent ไม่ตอบ) → plugin คืน `kAuthorizationResultDeny`
   ซึ่งทำให้ล้มเหลวเฉพาะเงื่อนไขใบหน้า กฎ `system.login.screensaver` เป็นแบบ `k-of-n = 1`
   (`[com.example.faceid.face, authenticate-session-owner-or-admin]`) จึงไปถามรหัสผ่านต่อ
   **รหัสผ่านต้องเป็นตัวเลือกสุดท้ายในกฎเสมอ** ดู `Plugins/FaceIDAuthPlugin/screensaver-rule.plist`
   > ✅ ยืนยันใน VM แล้ว (macOS 27, 2026-10-18): `Deny` ทำให้ไปถามรหัสผ่านต่อ และปลดล็อกด้วยรหัสผ่านได้
   > (ข้อ E4/E5 ใน `docs/plugin-vm-test.md`) ต้องทดสอบซ้ำเมื่อเปลี่ยนเวอร์ชัน macOS
7. ปิดกล้องทันทีเมื่อจบ (ไฟกล้องต้องดับ)

---

## 4. โครงสร้างโฟลเดอร์

```
FaceID/
├── CLAUDE.md
├── README.md
├── Package.swift                  # FaceIDCore เป็น Swift Package
├── Sources/
│   └── FaceIDCore/
│       ├── Camera/CameraService.swift        # protocol CameraProviding + impl
│       ├── Detection/FaceDetector.swift      # Vision
│       ├── Detection/QualityGate.swift       # แสง, มุม, ความคม, ขนาดหน้า
│       ├── Liveness/LivenessChecker.swift    # กะพริบตา + หันหน้า (challenge)
│       ├── Recognition/EmbeddingModel.swift  # Core ML wrapper
│       ├── Recognition/Matcher.swift         # cosine similarity + threshold
│       ├── Storage/TemplateStore.swift       # Keychain + CryptoKit
│       └── XPC/FaceIDServiceProtocol.swift   # @objc protocol ที่ใช้ร่วมกัน
├── Apps/
│   ├── FaceIDApp/                 # Menu bar app (Enrollment/Settings)
│   └── FaceIDAgent/               # LaunchAgent + XPC listener
├── Plugins/
│   ├── FaceIDAuthPlugin/          # Authorization plugin bundle (.bundle)
│   └── pam_faceid/                # PAM module (C) — optional
├── Models/
│   └── FaceEmbedding.mlpackage
├── Scripts/
│   ├── install.sh                 # ติดตั้ง + backup authorizationdb
│   ├── uninstall.sh               # คืนค่า authorizationdb จาก backup
│   └── recovery.md                # วิธีกู้คืนถ้าถูกล็อก
├── LaunchAgents/
│   └── com.example.faceid.agent.plist
└── Tests/
    └── FaceIDCoreTests/
```

---

## 5. คำสั่งที่ใช้บ่อย

```bash
# Build + test core library
swift build
swift test

# Build ทั้งหมด (Xcode project)
xcodebuild -scheme FaceIDApp -configuration Debug build
xcodebuild -scheme FaceIDAgent -configuration Debug build
xcodebuild -scheme FaceIDAuthPlugin -configuration Debug build

# ดู log
log stream --predicate 'subsystem == "com.example.faceid"' --level debug

# ดูกฎ authorization ปัจจุบัน (อ่านอย่างเดียว ปลอดภัย)
security authorizationdb read system.login.screensaver
```

### การติดตั้ง Plugin (ต้องทำด้วยความระมัดระวัง)
```bash
sudo ./Scripts/install.sh     # จะ backup กฎเดิมไว้ที่ /Library/Application Support/FaceID/backup/
sudo ./Scripts/uninstall.sh   # คืนค่าเดิม
```
- Plugin bundle ติดตั้งที่ `/Library/Security/SecurityAgentPlugins/FaceIDAuthPlugin.bundle`
- ต้อง sign ด้วย Developer ID และ owner เป็น `root:wheel`
- **ทดสอบใน VM (UTM/Parallels) ก่อนเสมอ** — ห้ามทดสอบ authorizationdb บนเครื่องหลักครั้งแรก

---

## 6. อัลกอริทึมและค่าคงที่

```swift
enum FaceIDConfig {
    static let matchThreshold: Float = 0.62          // cosine similarity — ปรับจาก FAR/FRR ที่วัดได้
    static let enrollmentSamples = 15                // ภาพหลายมุม: ตรง, ซ้าย, ขวา, ก้ม, เงย
    static let scanTimeout: Duration = .seconds(5)
    static let maxAttemptsBeforeLockout = 3          // ครบแล้วบังคับใช้รหัสผ่าน
    static let minFaceCaptureQuality: Float = 0.4
    static let requiredConsecutiveMatches = 3        // ต้อง match ติดกันหลายเฟรม
}
```

- **Matching:** เก็บ embedding หลายตัวต่อคน เทียบแบบ max similarity และต้องผ่านหลายเฟรมติดกัน
- **Liveness (ขั้นต่ำ):** ตรวจการกะพริบตาจาก Eye Aspect Ratio ของ landmarks + การขยับศีรษะเล็กน้อย
  ภาพนิ่งต้องไม่ผ่าน
  - **ตัดสินใจแล้ว (2026-10-18):** คงการ**สุ่มทิศ**หันซ้าย/ขวาไว้เพื่อกันวิดีโอที่อัดไว้ แม้ระบบบอกทิศผู้ใช้ไม่ได้
    (หน้าล็อกไม่มี UI) ผู้ใช้จึงต้อง "กะพริบตา แล้วหันซ้ายและขวาเล็กน้อย" ทุกครั้ง — ห้ามเปลี่ยนเป็นหันทางไหนก็ได้โดยไม่ถาม
- **Template update:** อัปเดต embedding ได้เฉพาะหลังยืนยันด้วยรหัสผ่านสำเร็จเท่านั้น

---

## 7. กฎความปลอดภัย (ห้ามละเมิด)

1. **ห้ามเก็บรหัสผ่านผู้ใช้** ในรูปแบบใดก็ตาม (plaintext, Keychain, UserDefaults)
2. **ห้ามบันทึกภาพใบหน้าลงดิสก์** — เก็บเฉพาะ embedding ที่เข้ารหัสแล้ว
3. **ห้าม log** ภาพ, embedding, similarity score ใน release build (debug ได้แบบ `.private`)
4. ใช้ `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — ไม่ sync iCloud
5. XPC listener ต้องตรวจ code signature ของผู้เรียก (`setCodeSigningRequirement`) ทุกครั้ง
6. Plugin ต้อง **fail closed เข้าโหมดรหัสผ่าน** — error/timeout/crash ใด ๆ = แสดงช่องรหัสผ่าน ไม่ใช่ allow
7. ห้ามแก้ `authorizationdb` นอก `install.sh` / `uninstall.sh` และต้อง backup ก่อนทุกครั้ง
8. ห้ามแนะนำให้ปิด SIP, Gatekeeper หรือ TCC
9. ผู้ใช้ต้องปิดฟีเจอร์ได้ในคลิกเดียวจาก Menu Bar

---

## 8. แนวทางการเขียนโค้ด

- Swift 6 strict concurrency: กล้องและ Vision ทำงานใน `actor` แยก, UI บน `@MainActor`
- ทุก service ต้องมี protocol (`CameraProviding`, `EmbeddingProviding`, `TemplateStoring`)
  เพื่อ mock ในเทสต์ได้ — **เทสต์ห้ามเปิดกล้องจริง**
- ใช้ `os.Logger(subsystem: "com.example.faceid", category: ...)`
- Error เป็น `enum FaceIDError: Error` ที่มีเคสชัดเจน ห้าม `fatalError` ในโค้ด plugin
- Plugin เขียนด้วย C API ของ Authorization (`AuthorizationPluginCreate`) ห่อด้วย Swift ได้ แต่ต้องไม่ block main thread ของ SecurityAgent
- คอมเมนต์ในโค้ดเป็นภาษาอังกฤษ, เอกสารสำหรับผู้ใช้เป็นภาษาไทยได้

---

## 9. การทดสอบ

- **Unit:** Matcher (threshold edge cases), QualityGate, LivenessChecker (ป้อน landmark sequence จำลอง), TemplateStore (encrypt/decrypt round-trip)
- **Integration:** XPC agent ↔ mock plugin client
- **Spoof tests (manual):** รูปพิมพ์, รูปบนจอมือถือ, วิดีโอ — ต้องไม่ผ่านทั้งหมด
- **Metrics:** วัด FAR (คนอื่นผ่าน) และ FRR (เจ้าของไม่ผ่าน) บันทึกใน `docs/metrics.md` ก่อนปรับ threshold
- **Recovery test:** ใน VM ลอง uninstall ผ่าน SSH และ Recovery Mode ให้ได้

---

## 10. Definition of Done

- [ ] `swift test` ผ่านทั้งหมด
- [ ] Enrollment ทำงานและเตือนเรื่องความปลอดภัยของกล้อง 2D
- [ ] ปลดล็อก screensaver ได้ใน VM และ fallback เป็นรหัสผ่านเมื่อไม่ match/timeout/agent ไม่ทำงาน
- [ ] รูปถ่ายนิ่งไม่ผ่าน liveness
- [ ] `uninstall.sh` คืนค่าระบบได้ 100%
- [ ] ไม่มีภาพ/embedding/รหัสผ่านหลุดลง log หรือดิสก์

---

## 11. สิ่งที่ Claude ต้องถามผู้ใช้ก่อนเสมอ

- ก่อนรันคำสั่งที่ใช้ `sudo` หรือแก้ `security authorizationdb write`
- ก่อนเปลี่ยน `matchThreshold` หรือปิด liveness
- ก่อนเปลี่ยน bundle identifier / signing team
