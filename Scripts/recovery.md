# กู้คืนเครื่องเมื่อ FaceID มีปัญหา

ฉบับติดตั้งอยู่ที่ `/Library/Application Support/FaceID/recovery.md`
**พิมพ์หรือเก็บไฟล์นี้ไว้ที่อื่น** (เช่น โทรศัพท์) ก่อนติดตั้ง plugin

FaceID แก้กฎของ macOS แค่ข้อเดียวคือ `system.login.screensaver` (ปลดล็อกหน้าจอ)
**ไม่ได้แตะการล็อกอินตอนเปิดเครื่อง และไม่ได้แตะ FileVault** การรีสตาร์ทแล้วล็อกอินด้วยรหัสผ่านจึงยังใช้ได้เสมอ

---

## เตรียมไว้ก่อนติดตั้ง plugin (สำคัญ)

- [ ] ติดตั้งใน **VM ก่อน** (UTM/Parallels) และ snapshot VM ไว้
- [ ] เปิด **Remote Login (SSH)**: การตั้งค่าระบบ › ทั่วไป › การแชร์ › การเข้าสู่ระบบระยะไกล
- [ ] มี**บัญชีผู้ดูแลอีกบัญชี** หรือรู้วิธีเข้า Recovery Mode
- [ ] ตรวจว่ามี backup ของกฎเดิม:

```bash
sudo ls "/Library/Application Support/FaceID/backup/original"
```

---

## อาการและวิธีแก้แบบเร็ว

| อาการ | ทำอะไร |
|---|---|
| สแกนใบหน้าไม่ผ่าน | พิมพ์รหัสผ่านตามปกติ |
| ใช้ใบหน้าไม่ได้ ขึ้นว่าถูกล็อก | ปลดล็อกด้วยรหัสผ่านหนึ่งครั้ง ระบบจะรีเซ็ตเอง |
| อยากปิด FaceID ทันที | Menu Bar › ปิด "ใช้ใบหน้าปลดล็อก" |
| ไฟกล้องติดค้าง | หยุด agent (ข้อ 4) |
| หน้าล็อกไม่มีช่องรหัสผ่าน / ใส่รหัสถูกแล้วไม่ผ่าน | ข้อ 1 → 2 → 3 ตามลำดับ |
| หน้าล็อกปลดล็อกโดยไม่ถามรหัสผ่าน | plugin หายหรือเสีย broker ควรคืนกฎเองภายใน ~5 วินาที ถ้ายังเป็นอยู่ ทำข้อ 1 ทันที |

---

## 1. คืนค่ากฎผ่าน SSH (เร็วที่สุด)

จากเครื่องอื่น:

```bash
ssh <ชื่อผู้ใช้>@<ชื่อเครื่องหรือ IP>
```

แล้วรัน (คืนค่าเฉพาะกฎปลดล็อกหน้าจอ ยังไม่ลบอะไร):

```bash
sudo "/Library/Application Support/FaceID/uninstall.sh" --restore-authdb-only
```

จากนั้นปลดล็อกหน้าจอด้วยรหัสผ่านได้ตามปกติ แล้วค่อยถอนการติดตั้งทั้งหมด:

```bash
sudo "/Library/Application Support/FaceID/uninstall.sh"
```

## 2. รีสตาร์ทแล้วล็อกอินด้วยรหัสผ่าน

ถ้าไม่มี SSH: กดปุ่มเปิดเครื่องค้างไว้จนเครื่องดับ แล้วเปิดใหม่
(หรือใช้ "สลับผู้ใช้" เพื่อเข้าบัญชีผู้ดูแลอีกบัญชี)

หน้าล็อกอินตอนเปิดเครื่องใช้กฎคนละข้อที่ FaceID ไม่ได้แก้ จึงล็อกอินด้วยรหัสผ่านได้
จากนั้นเปิด Terminal แล้วรัน:

```bash
sudo "/Library/Application Support/FaceID/uninstall.sh"
```

## 3. Recovery Mode (ทางสุดท้าย)

ใช้เมื่อข้อ 1 และ 2 ไม่ได้ผล

1. เข้า Recovery Mode
   - Apple silicon: ปิดเครื่อง → กดปุ่มเปิดเครื่องค้างจนขึ้น "กำลังโหลดตัวเลือกการเริ่มต้นระบบ" → ตัวเลือก
   - Intel: เปิดเครื่องแล้วกด ⌘R ค้าง
2. ถ้าเปิด FileVault อยู่: Disk Utility → เลือก "Macintosh HD - Data" → Mount → ใส่รหัสผ่าน
3. เมนู Utilities → Terminal แล้วดูชื่อ volume (มักเป็น `Data` หรือ `Macintosh HD - Data`):

```bash
ls /Volumes
```

ตั้งตัวแปรเป็นชื่อนั้น (ใน Recovery วางข้อความจากที่อื่นไม่ได้ จึงย่อคำสั่งด้วยตัวแปร):

```bash
D="/Volumes/Data"
```

4. **ทำขั้นนี้ก่อน**: ให้ macOS สร้างฐานข้อมูลกฎ authorization ใหม่จากค่าเริ่มต้นตอนบูตครั้งถัดไป
   ย้ายทั้ง `auth.db` และไฟล์ `-wal`/`-shm` ข้างกัน (ถ้าเหลือ `-wal` ไว้ อาจถูกนำกลับมาใช้กับฐานข้อมูลใหม่):

```bash
cd "$D/private/var/db"
```

```bash
for f in auth.db auth.db-wal auth.db-shm; do mv $f $f.faceid-broken; done
```

> ⚠️ ขั้นนี้รีเซ็ตกฎ authorization **ทุกข้อ** กลับเป็นค่าเริ่มต้น ถ้าเครื่องถูกจัดการด้วย MDM
> หรือมีโปรแกรมอื่นแก้กฎไว้ จะต้องตั้งค่าของโปรแกรมนั้นใหม่
> ✅ ทดสอบใน VM แล้ว (2026-10-25, macOS 27.0.1): บูตแล้วล็อกอินได้ กฎกลับเป็นค่าเริ่มต้น

5. แล้วค่อยลบ plugin และ LaunchAgent:

```bash
rm -rf "$D/Library/Security/SecurityAgentPlugins/FaceIDAuthPlugin.bundle"
```

```bash
rm -f "$D/Library/LaunchAgents/com.example.faceid.agent.plist"
```

> ⛔ **ห้ามลบ plugin โดยไม่คืนค่ากฎ** (ห้ามหยุดหลังขั้น 5 โดยไม่ได้ทำขั้น 4): macOS ถือว่า plugin ที่หายไป = ผ่าน
> หน้าล็อกจะปลดล็อกโดยไม่ถามรหัสผ่าน ปกติ broker จะคืนกฎให้เอง แต่ใน Recovery Mode broker ไม่ได้ทำงาน

6. รีสตาร์ท ล็อกอินด้วยรหัสผ่าน แล้วรัน `uninstall.sh` เพื่อลบส่วนที่เหลือ

## 4. หยุด agent (ไฟกล้องติดค้าง / ทำงานผิดปกติ)

ไม่ต้องใช้ sudo:

```bash
launchctl bootout gui/$(id -u)/com.example.faceid.agent
```

เมื่อ agent ไม่ทำงาน การปลดล็อกจะกลับไปใช้รหัสผ่าน (fail closed)

## 5. ไม่มีไฟล์ backup ของกฎเดิม

ดึงกฎค่าเริ่มต้นของ macOS เวอร์ชันนี้จากไฟล์ระบบ:

```bash
/usr/libexec/PlistBuddy -x -c "Print :rights:system.login.screensaver" /System/Library/Security/authorization.plist > /tmp/screensaver-default.plist
```

ตรวจว่าไม่มีคำว่า FaceIDAuthPlugin:

```bash
cat /tmp/screensaver-default.plist
```

แล้วเขียนกลับ:

```bash
sudo security authorizationdb write system.login.screensaver < /tmp/screensaver-default.plist
```

บน macOS 27 ค่าเริ่มต้นคือ `"rule" = "use-login-window-ui"`

## 6. ลบเฉพาะข้อมูลใบหน้า

ใช้ปุ่ม "ลบข้อมูลใบหน้า" ในแอป Menu Bar ซึ่งจะลบ template และทำลายกุญแจเข้ารหัส
ถ้าแอปใช้ไม่ได้ ลบจาก keychain โดยตรง:

```bash
security delete-generic-password -s com.example.faceid -a template
```

```bash
security delete-generic-password -s com.example.faceid -a template-key.secure-enclave
```

---

## รายการทดสอบการกู้คืนใน VM (Definition of Done)

ทำหลังติดตั้งด้วย `--with-plugin` ใน VM แต่ละข้อเริ่มจาก snapshot ที่ติดตั้งแล้ว

- [x] `uninstall.sh --restore-authdb-only` ผ่าน SSH แล้วปลดล็อกด้วยรหัสผ่านได้
- [x] หยุด agent แล้วล็อกหน้าจอ → ปลดล็อกด้วยรหัสผ่านได้
- [x] ลบ plugin bundle ทิ้งโดยไม่คืนค่ากฎ → ภายใน ~5 วินาที broker คืนกฎเดิมเอง (log `restoring the original rule`) → ล็อกหน้าจอแล้วต้องถามรหัสผ่าน
- [x] ทำ binary ของ plugin เสีย (bundle ยังอยู่) → broker คืนกฎเดิมเองภายใน ~5 วินาที
- [x] ระหว่าง `install.sh --with-plugin` ซ้ำ broker ไม่คืนกฎกลางคัน (มี `state/maintenance`) และหลังติดตั้งกฎยังใช้ plugin
- [x] Recovery Mode: ย้าย `auth.db` (+ `-wal`/`-shm`) แล้วลบ plugin → บูตแล้วล็อกอินได้ และกฎกลับเป็นค่าเริ่มต้น
- [x] หลัง `uninstall.sh` กฎ `system.login.screensaver` ตรงกับ `backup/original` ทุกตัวอักษร (ยกเว้นวันที่แก้ไข)
- [x] หลัง `uninstall.sh` ไม่มีไฟล์ใน `/Library/Application Support/FaceID` ยกเว้น `backup/` และไม่มีข้อมูลใบหน้าใน keychain (keychain: ยังต้องตรวจบนเครื่องหลัก)
