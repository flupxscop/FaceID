# FaceID for macOS

ปลดล็อกหน้าจอล็อก / Screensaver ของ Mac ด้วยใบหน้า ผ่านกล้อง FaceTime หรือกล้องภายนอก

> ⚠️ **คำเตือนด้านความปลอดภัย**
> กล้องของ Mac เป็นกล้อง 2D ไม่มีเซนเซอร์วัดความลึกแบบ TrueDepth ของ iPhone
> ระบบนี้จึงปลอดภัยน้อยกว่า Face ID ของ Apple และอาจถูกหลอกได้ด้วยวิธีที่ซับซ้อน
> รหัสผ่านยังใช้ได้เสมอ และ**ใช้ปลดล็อก FileVault ตอนบูตเครื่องไม่ได้**

## สถานะ

| ส่วน | สถานะ |
|---|---|
| `FaceIDCore` (Swift Package) | ✅ โค้ด + unit test |
| `FaceIDAgent` (LaunchAgent + XPC) | ✅ ทดสอบบนเครื่องหลัก (release, ไม่มี plugin) และใน VM |
| `FaceIDApp` (Menu Bar / Enrollment) | ✅ ลงทะเบียนและสแกนบนเครื่องหลักได้ |
| `FaceIDBroker` (LaunchDaemon) | ✅ ส่งต่อคำขอ plugin → agent และเฝ้า plugin (ดูด้านล่าง) |
| `FaceIDAuthPlugin` | 🧪 ผ่านการทดสอบใน VM ([docs/plugin-vm-test.md](docs/plugin-vm-test.md)) ยังไม่ได้ปลดล็อกด้วยใบหน้าจริงบนเครื่องหลัก |
| `Scripts/install.sh` / `uninstall.sh` / `recovery.md` | ✅ ทดสอบใน VM ครบ รวม Recovery Mode |
| โมเดล embedding | ✅ SFace (Apache 2.0) ดู [Models/README.md](Models/README.md) |
| `pam_faceid` | ⏳ ทางเลือก |
| FAR/FRR (`docs/metrics.md`) | ⏳ ยังไม่ได้วัด — `matchThreshold` จะไม่เปลี่ยนจนกว่าจะวัด |

## ใช้งานที่หน้าล็อก (เมื่อติดตั้ง plugin)

1. ปลุกจอ แล้ว**กด Return** ที่หน้าล็อก (ช่องรหัสผ่านว่างไว้ได้) — macOS เริ่มตรวจกฎปลดล็อกเมื่อกดเข้าสู่ระบบเท่านั้น
   ไม่ได้เริ่มเองตอนปลุกจอ
2. มองกล้อง กะพริบตา แล้วหันซ้ายและขวาเล็กน้อย (ระบบสุ่มทิศเพื่อกันวิดีโอที่อัดไว้ แต่หน้าล็อกบอกทิศไม่ได้)
3. ไม่ผ่าน / หมดเวลา / agent ไม่ทำงาน → ช่องรหัสผ่านขึ้น พิมพ์รหัสผ่านตามปกติ
4. ไม่ผ่าน 3 ครั้งติดกัน → ใช้รหัสผ่านอย่างเดียวจนกว่าจะปลดล็อกด้วยรหัสผ่านหนึ่งครั้ง

ปิดฟีเจอร์ได้ทันทีจาก Menu Bar › "ใช้ใบหน้าปลดล็อก"

## ข้อจำกัดที่ควรรู้

- **plugin หายหรือเสีย = macOS ถือว่าผ่าน** (ยืนยันใน VM) `FaceIDBroker` จึงเฝ้า plugin ทุก 5 วินาที และคืนกฎปลดล็อกเดิม
  ทันทีที่พบ (ทดสอบแล้ว: 0.2 วินาทีเมื่อ bundle หาย, 2 วินาทีเมื่อ binary เสีย) ถ้า broker ไม่ทำงานด้วย จะไม่มีใครคืนกฎ
  — อย่าลบไฟล์ของ FaceID เอง ให้ใช้ `uninstall.sh` (ดู [Scripts/recovery.md](Scripts/recovery.md))
- หลังปลดล็อกด้วยใบหน้า macOS อาจขอรหัสผ่านบัญชี Apple ใน การตั้งค่าระบบ เพราะไม่ได้ใช้รหัสผ่าน
- กล้อง 2D: ยังทดสอบการหลอกไม่ครบ (รูปบนมือถือไม่ผ่าน ✅; รูปพิมพ์และวิดีโอยังไม่ได้ทดสอบ)

## Build และทดสอบ

```bash
swift build
swift test
```

เทสต์ทั้งหมดใช้ mock และไม่เปิดกล้องจริง

Build และ sign แอปกับ agent ลงใน `dist/` (ต้องสร้างใบรับรองตาม [docs/local-signing.md](docs/local-signing.md) ก่อน):

```bash
Scripts/build-app.sh
```

## ข้อมูลที่ระบบเก็บ

- เก็บเฉพาะ face embedding ที่เข้ารหัสแล้ว (AES-GCM โดยใช้คีย์จาก Secure Enclave) ไว้ใน Keychain
  แบบ `WhenUnlockedThisDeviceOnly` และไม่ sync ขึ้น iCloud
- ไม่เก็บภาพใบหน้า ไม่เก็บรหัสผ่าน
- ภาพและ embedding อยู่ในหน่วยความจำของ `FaceIDAgent` เท่านั้น ไม่ส่งผ่าน XPC ไม่ออกจากเครื่อง
- Release build ต้องมี Secure Enclave

ดูรายละเอียดได้ใน [docs/security.md](docs/security.md) และ [CLAUDE.md](CLAUDE.md)
