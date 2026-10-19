# FaceID for macOS

ปลดล็อกหน้าจอล็อก / Screensaver ของ Mac ด้วยใบหน้า ผ่านกล้อง FaceTime หรือกล้องภายนอก

> ⚠️ **คำเตือนด้านความปลอดภัย**
> กล้องของ Mac เป็นกล้อง 2D ไม่มีเซนเซอร์วัดความลึกแบบ TrueDepth ของ iPhone
> ระบบนี้จึงปลอดภัยน้อยกว่า Face ID ของ Apple และอาจถูกหลอกได้ด้วยวิธีที่ซับซ้อน
> รหัสผ่านยังใช้ได้เสมอ และ**ใช้ปลดล็อก FileVault ตอนบูตเครื่องไม่ได้**

## สถานะ

| ส่วน | สถานะ |
|---|---|
| `FaceIDCore` (Swift Package) | ✅ มีโค้ดและ unit test แล้ว |
| `FaceIDAgent` (LaunchAgent + XPC) | ✅ มีโค้ดและเทสต์แล้ว แต่ยังไม่ได้ติดตั้ง/ทดสอบใน VM |
| `FaceIDApp` (Menu Bar / Enrollment) | ✅ มีโค้ดและเทสต์แล้ว ยังไม่ได้ลองกับ agent จริง |
| `FaceIDAuthPlugin` | 🧪 prototype พร้อมทดสอบใน VM ([docs/plugin-vm-test.md](docs/plugin-vm-test.md)) ห้ามติดตั้งบนเครื่องหลัก |
| `Scripts/install.sh` / `uninstall.sh` / `recovery.md` | ✅ เขียนแล้ว ยังไม่เคยรัน (ต้องใช้ sudo; ทดสอบใน VM ก่อน) |
| `pam_faceid` | ⏳ ทางเลือก |
| โมเดล embedding (`Models/`) | ⏳ ยังไม่ได้เลือก ต้องตรวจ license ก่อน |

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
