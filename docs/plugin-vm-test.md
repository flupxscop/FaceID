# ทดสอบ FaceIDAuthPlugin ใน VM

> ⛔ **ห้ามติดตั้ง plugin บนเครื่องหลัก**จนกว่าทุกข้อในเอกสารนี้จะผ่านใน VM
> (`install.sh --with-plugin` จะปฏิเสธเองถ้าไม่ได้อยู่ใน VM)

## สิ่งที่ยังไม่รู้ (เหตุผลที่ต้องทดสอบ)

| # | คำถาม | ทำไมยังไม่แน่ใจ |
|---|---|---|
| E1 | หน้าล็อกเรียก SecurityAgent ไหม เมื่อเปลี่ยนกฎจาก `use-login-window-ui` | Apple เขียนไว้แค่ในคอมเมนต์ของกฎ |
| E2 | SecurityAgent โหลด plugin ที่ sign ด้วยใบรับรอง self-signed ได้ไหม | SecurityAgent มี `clear-library-validation` จึง*น่าจะ*ได้ |
| E3 | plugin ใน SecurityAgent มองเห็น Mach service ของ LaunchAgent ฝั่งผู้ใช้ไหม | SecurityAgent รันเป็นผู้ใช้ไม่ระบุตัวตน (anonymous) |
| E4 | กฎ `k-of-n` อ้างชื่อ **right** (`com.example.faceid.face`) ได้ไหม | Apple ใช้ชื่อ **rule** ในรายการ เช่น `is-root` |
| E5 | `Deny` ทำให้ไปขั้นรหัสผ่านต่อได้ไหม (หรือต้องใช้ `Undefined`) | header บอกว่า Undefined = "ไม่ลองใหม่ใน session นี้" |
| E7 | plugin host (`_securityagent`) อยู่ใน audit session เดียวกับ agent ของผู้ใช้ไหม | ✅ ยืนยันแล้ว: ทั้งคู่ 100183 |
| E6 | เมื่อได้ `Allow` หน้าจอปลดล็อกจริงไหม และต้องตั้ง context `username`/`uid` ไหม | builtin:authenticate ตั้งค่าเหล่านี้ไว้ ของเราตั้งเลียนแบบ |

ถ้าข้อไหนไม่ผ่าน **อย่าแก้บนเครื่องหลัก** ให้บันทึกผลแล้วกลับมาแก้แบบใน repo

## เตรียม VM

1. VM macOS เวอร์ชันเดียวกับเครื่องจริง (UTM หรือ Parallels)
2. เปิด SSH ใน VM: การตั้งค่าระบบ › ทั่วไป › การแชร์ › การเข้าสู่ระบบระยะไกล
3. สร้างใบรับรอง "FaceID Local Signing" ใน VM ตาม [local-signing.md](local-signing.md)
4. **Snapshot VM** ก่อนทำต่อ
5. Build แบบ debug ใน VM (VM ไม่มี Secure Enclave และ release build จะไม่ยอมทำงาน):

```bash
BUILD_CONFIGURATION=debug Scripts/build-app.sh
```

```bash
Scripts/test-plugin.sh
```

> 📷 กล้องใน VM: Parallels แชร์กล้องของเครื่องจริงให้ VM ได้ ส่วน UTM (Apple Virtualization)
> อาจไม่มีกล้อง ถ้าไม่มีกล้องจะทดสอบได้เฉพาะทาง "ไม่ผ่าน → รหัสผ่าน" (E1–E5, F1–F4) ข้อ E6 กับ S1–S3 ต้องมีกล้อง

## สิ่งที่พบระหว่างทดสอบ (2026-10-18)

- plugin ถูกโหลดใน **`SecurityAgentHelper-arm64`** (identifier `com.apple.SecurityAgentHelper.arm64`) ไม่ใช่ `SecurityAgent`
  → เพิ่ม helper ทั้งสองสถาปัตยกรรมใน requirement ของ agent แล้ว
- helper มี entitlement `com.apple.private.xpc.launchd.per-user-lookup` จึงควรค้นหา Mach service ของผู้ใช้ได้ (E3)
- ใน helper `NSBundle bundleWithIdentifier:` หา plugin ไม่เจอ และอ่านใบรับรองจากลายเซ็นไม่ได้
  → plugin หา bundle ด้วย `dladdr` และใช้ SHA-1 ของใบรับรองที่ฝังใน `Info.plist` ตอน build (ถูกคุ้มครองโดยลายเซ็น)
- helper รันเป็นผู้ใช้ **`_securityagent`** จึงค้นหา Mach service ของ LaunchAgent ใน `gui/501` ไม่เจอ (`NSCocoaErrorDomain 4099`)
  ทั้งที่ agent ทำงานอยู่ → ต้องเปลี่ยนเส้นทาง plugin → agent → เพิ่ม **FaceIDBroker** (LaunchDaemon) เป็นตัวกลาง ใช้เฉพาะ API สาธารณะ
- E7 ✅ agent ลงทะเบียนกับ broker ที่ audit session เดียวกับ plugin (100183)
- plugin ตรวจลายเซ็น broker ไม่ผ่าน (4102) ทั้งแบบใบรับรองและ cdhash: `SecStaticCodeCheckValidity` = `CSSMERR_TP_NOT_TRUSTED`
  แม้ตั้งให้ VM เชื่อถือใบรับรองแล้ว → broker แบบ ad-hoc + cdhash ผ่าน (ทดลองแล้ว: `finished: no match`, ไม่มี 4102)
- notification `com.apple.screenIsUnlocked` มาถึงก่อนที่ window server จะอัปเดตสถานะ → agent เช็กซ้ำได้นานสุด 3 วินาทีแล้ว

## ขั้นตอน

เปิดหน้าต่างดู log ค้างไว้ (ผ่าน SSH ก็ได้):

```bash
log stream --predicate 'subsystem == "com.example.faceid"' --level debug
```

1. ติดตั้งแบบยังไม่มี plugin แล้วลงทะเบียนใบหน้าจากแอป Menu Bar และเปิดใช้งาน:

```bash
sudo Scripts/install.sh
```

2. ติดตั้ง plugin:

```bash
sudo Scripts/install.sh --with-plugin
```

3. ดูกฎที่ติดตั้งแล้ว:

```bash
security authorizationdb read system.login.screensaver
```

```bash
security authorizationdb read com.example.faceid.face
```

4. ล็อกหน้าจอ (⌃⌘Q) แล้วทดสอบตามตาราง

## ตารางผล (กรอกระหว่างทดสอบ)

| # | ทำอะไร | ผลที่ต้องได้ | ผลจริง |
|---|---|---|---|
| E1 | ล็อกหน้าจอ | log มี `FaceIDAuthPlugin loaded` | ✅ 2026-10-18 macOS 27 (UTM): plugin ถูกเรียกตอนปลดล็อก |
| E2 | (ข้อเดียวกัน) | log ไม่มี error เรื่องโหลด bundle | ✅ โหลดใน `SecurityAgentHelper-arm64` ได้ (ใบรับรอง self-signed) |
| E3b | (ผ่าน broker) ล็อกหน้าจอ | log ของ broker: `accepted plugin connection ... audit session N` และ `agent registered for audit session N` **เลข N ตรงกัน**; plugin: `face mechanism finished: no match` | ✅ 2026-10-18: session 100183 ทั้งสองฝั่ง, ไม่มี 4102, plugin ได้คำตอบจาก agent (`no match` เพราะยังปิดฟีเจอร์) |
| E3 | หน้าตรงกล้อง | log `face mechanism finished: match` (ไม่ใช่ `xpc error`) | ❌ `xpc error 4099` และ agent ไม่เห็นการเชื่อมต่อ: helper รันเป็น `_securityagent` มองไม่เห็น Mach service ใน `gui/<uid>` |
| E4/E5 | ปิด "ใช้ใบหน้าปลดล็อก" แล้วล็อกหน้าจอ | ช่องรหัสผ่านขึ้นทันที และรหัสผ่านใช้ได้ | ✅ plugin ตอบ `Deny` → ขึ้นช่องรหัสผ่าน และปลดล็อกได้ |
| E6 | หน้าตรงกล้อง กะพริบตา หันตามที่ระบบสุ่ม | ปลดล็อกภายใน ~2 วินาที | ⏳ VM (UTM) ไม่มีกล้อง; บนเครื่องหลักการสแกน (ไม่ผ่านหน้าล็อก) จำหน้าได้ ✅ |
| F1 | ปิดกล้อง/หันหนี | ภายใน 7 วินาที ช่องรหัสผ่านขึ้น | |
| F2 | `launchctl bootout gui/$(id -u)/com.example.faceid.agent` แล้วล็อก | ช่องรหัสผ่านขึ้นทันที | |
| F3 | สแกนไม่ผ่าน 3 ครั้ง | ครั้งที่ 4 ไปรหัสผ่านทันที; หลังใช้รหัสผ่านแล้ว ใบหน้าใช้ได้อีก | |
| F4 | ระหว่างสแกนกดยกเลิก/เริ่มพิมพ์รหัสผ่าน | ไฟกล้องดับ | |
| S1 | รูปถ่ายพิมพ์ | ไม่ผ่าน | |
| S2 | รูปบนจอมือถือ | ไม่ผ่าน | ✅ 2026-10-18 (MacBook Air, ทดสอบสแกนจากแอป): ไม่ผ่านทั้งถือนิ่ง/หมุน และแบบกะพริบตาก่อนแล้วยกรูป (หลังแก้การผูก liveness กับหน้าที่ match) |
| S3 | วิดีโอเจ้าของเครื่อง | ไม่ผ่าน (ถ้าทิศหันไม่ตรงที่สุ่ม) | |
| R1–R6 | รายการทดสอบการกู้คืนใน [Scripts/recovery.md](../Scripts/recovery.md) | ผ่านทุกข้อ | |
| U1 | `sudo "/Library/Application Support/FaceID/uninstall.sh"` | กฎตรงกับ `backup/original` และไม่มี right `com.example.faceid.face` | |

ตรวจ U1 (สองคำสั่งแรกต้องแสดงค่าเดียวกัน บน macOS 27 คือ `use-login-window-ui`):

```bash
security authorizationdb read system.login.screensaver 2>/dev/null | plutil -extract rule.0 raw -
```

```bash
sudo plutil -extract rule.0 raw "/Library/Application Support/FaceID/backup/original/system.login.screensaver.plist"
```

คำสั่งนี้ต้องขึ้นว่าไม่พบ right:

```bash
security authorizationdb read com.example.faceid.face
```

## ถ้าข้อไหนไม่ผ่าน

| ข้อ | ทางเลือกที่จะลองต่อ (แก้ใน repo แล้ว build ใหม่) |
|---|---|
| E1 | หน้าล็อกไม่ผ่าน SecurityAgent → แนวทางนี้ใช้ไม่ได้กับ macOS เวอร์ชันนั้น |
| E2 | ลอง sign plugin โดยไม่มี hardened runtime / ตรวจ log ของ `SecurityAgent` |
| E3 | ให้ agent ลงทะเบียน Mach service ในระดับที่ SecurityAgent มองเห็น (ต้องออกแบบใหม่) |
| E4 | ใช้ชื่อ rule แทน right (ต้องหาวิธีเขียน rule ที่ปลอดภัย) |
| E5 | เปลี่ยน `kNotAcceptedResult` ใน `FaceIDAuthPlugin.m` |
| E6 | สลับ `kSetSessionOwnerContext` แล้วทดสอบใหม่ |
