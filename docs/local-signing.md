# Sign โค้ดโดยไม่มี Apple Developer Program

ใช้ใบรับรอง **self-signed** ที่สร้างเองบนเครื่องนี้ ฟรีและไม่ต้องส่งอะไรให้ Apple

## ทำไมต้อง sign

- Agent ยอมรับการเชื่อมต่อเฉพาะจาก SecurityAgent ของ Apple และ**แอปที่ sign ด้วยใบรับรองเดียวกับตัว agent**
  (requirement: `identifier "com.example.faceid.app" and certificate leaf = H"<SHA-1>"`)
  ถ้าไม่ sign (ad-hoc) จะต่อได้เฉพาะ SecurityAgent
- สิทธิ์กล้อง (TCC) ผูกกับลายเซ็น ถ้าใช้ ad-hoc ทุกครั้งที่ build ใหม่ สิทธิ์จะหาย

## 1. สร้างใบรับรอง (ทำครั้งเดียว ผู้ใช้ทำเอง)

1. เปิด **Keychain Access** แล้วไปที่เมนู **Keychain Access → Certificate Assistant → Create a Certificate…**
2. ตั้งค่า:
   - Name: `FaceID Local Signing`
   - Identity Type: **Self Signed Root**
   - Certificate Type: **Code Signing**
3. กด Create แล้วใบรับรองจะอยู่ใน login keychain

ตรวจสอบว่าเห็นใบรับรอง:

```bash
security find-certificate -c "FaceID Local Signing" -Z login.keychain-db
```

> 🔒 ตอน `codesign` ขอใช้กุญแจครั้งแรก ให้กด **Allow** ไม่ใช่ **Always Allow**
> เพื่อให้โปรแกรมอื่นแอบใช้กุญแจนี้ sign โค้ดปลอมโดยไม่ถามไม่ได้

## 2. Build และ sign (วิธีง่าย)

```bash
Scripts/build-app.sh
```

สคริปต์จะ build, sign ทั้ง `dist/FaceID.app` และ `dist/FaceIDAgent` ด้วยใบรับรองเดียวกัน (hardened runtime)
แล้วตรวจว่า sandbox บล็อก network ได้ ไม่ต้องใช้ sudo และไม่ติดตั้งอะไรลงเครื่อง

### หรือ sign agent เอง

```bash
swift build -c release --product FaceIDAgent
```

```bash
codesign --force --sign "FaceID Local Signing" --options runtime --entitlements Apps/FaceIDAgent/FaceIDAgent.entitlements .build/release/FaceIDAgent
```

ตรวจผล (ต้องเห็น `Authority=FaceID Local Signing` และ `flags=0x10000(runtime)`):

```bash
codesign -dv --verbose=2 .build/release/FaceIDAgent
```

แอป Menu Bar จะ sign ด้วยใบรับรองเดียวกันนี้

## 3. ตรวจว่า sandbox บล็อก network ได้

```bash
/usr/bin/sandbox-exec -f Apps/FaceIDAgent/agent.sb .build/release/FaceIDAgent --check-isolation && echo "network blocked"
```

Release build จะ**ไม่ทำงาน**ถ้าไม่ได้รันอยู่ใน sandbox นี้ (fail closed)

## 4. ไม่ต้องตั้งให้เครื่องเชื่อถือใบรับรอง

หน้าล็อกรัน plugin ใน `SecurityAgentHelper` ซึ่งประเมินความเชื่อถือของใบรับรองที่ไม่ใช่ของ Apple ไม่ได้เลย
(ยืนยันใน VM: `CSSMERR_TP_NOT_TRUSTED` แม้ตั้งให้เครื่องเชื่อถือแล้ว) จึงออกแบบให้:
- **broker sign แบบ ad-hoc** และทุกฝั่งตรวจ broker ด้วย identifier + **cdhash** (เจาะจงไฟล์ที่ build พอดี)
- plugin รู้ cdhash จาก Info.plist ของตัวเอง (ลายเซ็นคุ้มครอง), agent รู้จาก `pins.plist` ที่ install.sh เขียน (root เท่านั้นแก้ได้)
- broker (root) ตรวจ agent ด้วยใบรับรองของคุณตามปกติ

ถ้าเคยตั้งความเชื่อถือไว้ระหว่างทดลอง ถอนออกได้ (ใน Terminal ของเครื่องนั้น):

```bash
sudo security remove-trusted-cert -d ~/FaceID/dist/FaceIDLocalSigning.pem
```

## สิ่งที่ใช้ได้ / ไม่ได้ เมื่อไม่มี Developer Program

| ความสามารถ | ผล (ทดสอบบน macOS 27 เครื่องนี้) |
|---|---|
| Secure Enclave (CryptoKit) | ✅ ใช้ได้ รวมถึงใน sandbox |
| Data Protection Keychain | ❌ ต้องมี entitlement จึงใช้ login keychain แทน (template ยังเข้ารหัสด้วยคีย์ Secure Enclave) |
| บล็อก network ด้วย `sandbox_init()` ในโค้ด | ❌ macOS 27 kill โปรเซสทิ้ง |
| บล็อก network ด้วย `sandbox-exec` จาก launchd | ✅ ใช้ได้ (`connect` → `EPERM`) |
| Hardened runtime | ✅ ใช้กับใบรับรอง self-signed ได้ |
| Notarization / Gatekeeper | ไม่จำเป็น เพราะ build บนเครื่องตัวเอง (ห้ามปิด Gatekeeper) |
| Authorization plugin ที่ sign ด้วย self-signed | ✅ SecurityAgentHelper โหลดได้ (ยืนยันใน VM) |
| ตรวจลายเซ็น (ใบรับรอง self-signed) ภายใน SecurityAgentHelper | ❌ `CSSMERR_TP_NOT_TRUSTED` เสมอ → ใช้ ad-hoc + cdhash แทน |
