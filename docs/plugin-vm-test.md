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

> 📷 กล้องใน VM: VM ที่เป็น macOS บน Mac ชิป Apple (ทั้ง UTM และ Parallels) **ไม่มีกล้อง** — Virtualization framework
> ไม่รองรับการส่งกล้อง/USB เข้า guest (ยืนยันแล้ว 2026-10-20 บน Parallels 27) ข้อ S1–S3 จึงทดสอบบนเครื่องหลักแทน
> ส่วน E6 ใช้ "โหมดบังคับ match" ด้านล่าง

### โหมดบังคับ match (สำหรับ E6 เท่านั้น)

E6 ทดสอบว่า**เมื่อ plugin ได้ `Allow` แล้วหน้าจอปลดล็อกจริง** ไม่ได้ทดสอบกล้อง โหมดนี้ทำให้ agent ตอบ `match`
โดยไม่สแกน และจะทำงานก็ต่อเมื่อครบ**ทั้งสามข้อ**:

1. เป็น **debug build** (`ForcedMatchTestMode.swift` อยู่ใน `#if DEBUG`; `build-app.sh` ไม่ยอม build release ที่มีโค้ดนี้)
2. รันอยู่ใน **VM** (`kern.hv_vmm_present` = 1; `install.sh` ไม่ยอมติดตั้ง debug build นอก VM แม้ใส่ `--allow-host`)
3. มีไฟล์ `/Library/Application Support/FaceID/force-match-vm-test` ที่ **root เป็นเจ้าของ** และคนอื่นเขียนไม่ได้

agent เช็กทั้งสามข้อใหม่ทุกครั้งที่สแกน และ log ระดับ fault `FACEID-FORCED-MATCH-VM-TEST` ทุกครั้งที่ตอบ match แบบนี้
สวิตช์ "ใช้ใบหน้าปลดล็อก" ยังมีผลเหมือนเดิม — ปิดอยู่ = ไม่ match

เปิด (ใน VM เท่านั้น):

```bash
sudo install -o root -g wheel -m 644 /dev/null "/Library/Application Support/FaceID/force-match-vm-test"
```

VM ไม่มีกล้องจึงลงทะเบียนใบหน้าไม่ได้ และแอปจะไม่ให้เปิดสวิตช์ ให้เปิดสวิตช์ด้วยคำสั่งนี้แทน (บัญชีผู้ใช้ใน VM ไม่ต้อง sudo):

```bash
defaults write com.example.faceid enabled -bool true
```

ปิดหลังทดสอบเสร็จ (`uninstall.sh` ก็ลบไฟล์นี้ให้ด้วย):

```bash
sudo rm "/Library/Application Support/FaceID/force-match-vm-test"
```

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
- (2026-10-25) ภาพพักหน้าจอมี grace period 5 นาที (`lock screen immediate == NO ... delay of: 300`) ปลดล็อกภายใน 5 นาทีจะไม่ผ่านกฎ — ทดสอบด้วย ⌃⌘Q หรือรอเกิน 5 นาที
- (2026-10-25) สั่งจากเครื่องหลักได้: `prlctl exec macOS` (root ผ่าน Parallels Tools), ⌃⌘Q = `prlctl send-key-event macOS --key` 115 (⌘) + 37 (⌃) + 24 (Q), Return = 36, ภาพหน้าจอ `prlctl capture`
- (2026-10-25) หลังปลดล็อกโดยไม่ใช้รหัสผ่าน macOS อาจขอรหัสผ่านบัญชี Apple ใน การตั้งค่าระบบ
- notification `com.apple.screenIsUnlocked` มาถึงก่อนที่ window server จะอัปเดตสถานะ → agent เช็กซ้ำได้นานสุด 3 วินาทีแล้ว

## ✅ (แก้แล้ว) ปัญหาความปลอดภัยที่พบ (2026-10-25): plugin หาย = ปลดล็อกได้โดยไม่ต้องใส่รหัสผ่าน

ทดสอบ R3 (ย้าย `FaceIDAuthPlugin.bundle` ออกโดยไม่คืนค่ากฎ) แล้วล็อกหน้าจอ กด Return ช่องรหัสผ่านว่าง → **ปลดล็อก**
log ของ SecurityAgent: `Plugin FaceIDAuthPlugin filepath not found` → `AgentMechanism invoked [builtin:no-op]` →
authd `Succeeded authorizing right 'system.login.screensaver'`

macOS แทน mechanism ที่หา plugin ไม่เจอด้วย `builtin:no-op` (สำเร็จเสมอ) right `com.example.faceid.face` เป็น
`evaluate-mechanisms` ที่มี mechanism เดียว จึงผ่าน และเพราะกฎเป็น k-of-n = 1 หน้าจอจึงปลดล็อก
**ขัดกับ CLAUDE.md §7 ข้อ 6 (fail closed)**
ลองแก้แล้ว (2026-10-25, ผ่าน install.sh ใน VM) — **ไม่มีแบบไหนแก้ได้**:

| แบบที่ลอง | bundle หาย | binary เสีย |
|---|---|---|
| `evaluate-mechanisms` (แบบเดิม) | ❌ ปลดล็อก (`builtin:no-op`) | ❌ ปลดล็อก (`requires unsupported architecture`) |
| `class user` + `authenticate-user` + `session-owner` | ❌ ปลดล็อก — loginwindow ใส่ตัวตนเจ้าของ session ใน context ให้แล้ว authd จึงได้ credential โดย plugin ไม่ต้องทำงาน | ไม่ได้ลอง |
| mechanism แบบ `,privileged` (authorizationhost) | ❌ ปลดล็อก (`filepath not found`) | ไม่ได้ลอง |

สรุป: macOS ถือว่า mechanism ของ plugin ที่โหลดไม่ได้ = สำเร็จ (น่าจะเพื่อกันผู้ใช้ถูกล็อกออก) right ที่ตัดสินด้วย plugin
อย่างเดียวจึง fail closed ไม่ได้เมื่อ plugin โหลดไม่ขึ้น

**แก้แล้ว (2026-10-25, commit 05c2d9d):** broker เฝ้า plugin (`PluginWatchdog.swift`) ทุก 5 วินาทีและเมื่อโฟลเดอร์ plugin เปลี่ยน
ถ้า bundle หาย ลายเซ็นเสีย หรือไม่มีสถาปัตยกรรมของเครื่อง ขณะที่กฎยังใช้ plugin → เรียก `uninstall.sh --restore-authdb-only`
(CLAUDE.md §7 ข้อ 7) ผลใน VM (debug build, Parallels):

| # | ทำอะไร | ผล |
|---|---|---|
| W1 | ย้าย bundle ออก | ✅ broker คืนกฎภายใน 0.2 วินาที (`restoring the original rule` → `original screen-unlock rule restored`) กฎเป็น `use-login-window-ui` และลบ right แล้ว; ล็อก + Return ช่องว่าง → ไม่เรียก plugin, `Evaluate denied`, ยังล็อกอยู่ |
| W2 | เขียนทับ binary ของ plugin (bundle ยังอยู่) | ✅ broker คืนกฎภายใน 2 วินาที (จากตัวจับเวลา) |
| W3 | `install.sh --with-plugin` ซ้ำขณะ broker ทำงาน | ✅ broker ไม่คืนกฎกลางคัน กฎยังใช้ plugin หลังติดตั้ง และไม่มีไฟล์ `state/maintenance` ค้าง |
| E6 / E6b / F2 | ทำซ้ำบน build ใหม่ | ✅ เหมือนเดิม (match → ปลดล็อก; no match / ไม่มี agent → รหัสผ่าน, ช่องว่างถูกปฏิเสธ) |

ข้อจำกัดที่เหลือ: ถ้า broker ไม่ทำงาน (เช่น ใน Recovery Mode หรือถูก root หยุด) จะไม่มีใครคืนกฎ — recovery.md ข้อ 3
จึงให้ย้าย `auth.db` **ก่อน**ลบ plugin

(ผู้ที่ลบ bundle ได้ต้องเป็น root อยู่แล้ว แต่การถอนการติดตั้งไม่ครบ, เครื่องมือล้างเครื่อง หรือทำ recovery ข้อ 3 ไม่ครบ จะทำให้หน้าล็อกไม่ป้องกันอะไรเลย)

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
| E6 | เปิด**โหมดบังคับ match** (ด้านบน) แล้วล็อกหน้าจอ | ปลดล็อกได้เองโดยไม่ต้องใส่รหัสผ่าน; log มี `FACEID-FORCED-MATCH-VM-TEST` และ `face mechanism finished: match` | ✅ 2026-10-25 macOS 27.0.1 (Parallels 27): ปลดล็อกโดยไม่ใส่รหัสผ่าน — log: `FACEID-FORCED-MATCH-VM-TEST` → `face mechanism finished: match` ไม่ต้องตั้ง context เพิ่ม ⚠️ กฎทำงานเมื่อ**กด Return** ที่หน้าล็อก (ช่องรหัสผ่านว่างได้) ไม่ใช่ตอนปลุกจอ |
| E6b | ลบไฟล์เปิดโหมดแล้วล็อกหน้าจอ | ขึ้นช่องรหัสผ่าน (กลับไปสแกนจริง → ไม่มีกล้อง → Deny) | ✅ 2026-10-25: Return ช่องว่าง → `face mechanism finished: no match` → `builtin:authenticate` → `Evaluate denied` (ยังล็อกอยู่); ใส่รหัสผ่านจริง → `Succeeded authorizing right 'system.login.screensaver'` |
| F1 | ปิดกล้อง/หันหนี | ภายใน 7 วินาที ช่องรหัสผ่านขึ้น | |
| F2 | `launchctl bootout gui/$(id -u)/com.example.faceid.agent` แล้วล็อก | ช่องรหัสผ่านขึ้นทันที | ✅ 2026-10-25: broker `no agent registered` → `no match` → รหัสผ่านว่างถูกปฏิเสธ, รหัสผ่านจริงปลดล็อกได้ |
| F3 | สแกนไม่ผ่าน 3 ครั้ง | ครั้งที่ 4 ไปรหัสผ่านทันที; หลังใช้รหัสผ่านแล้ว ใบหน้าใช้ได้อีก | ⏭ ทำใน VM ไม่ได้ (ไม่มีกล้อง/ไม่ได้ลงทะเบียน → `notEnrolled` ไม่นับเป็นครั้งที่ล้มเหลว) ต้องทดสอบบนเครื่องหลัก |
| F4 | ระหว่างสแกนกดยกเลิก/เริ่มพิมพ์รหัสผ่าน | ไฟกล้องดับ | ⏭ ทำใน VM ไม่ได้ (ไม่มีกล้อง) ต้องทดสอบบนเครื่องหลัก |
| S1 | รูปถ่ายพิมพ์ | ไม่ผ่าน | |
| S2 | รูปบนจอมือถือ | ไม่ผ่าน | ✅ 2026-10-18 (MacBook Air, ทดสอบสแกนจากแอป): ไม่ผ่านทั้งถือนิ่ง/หมุน และแบบกะพริบตาก่อนแล้วยกรูป (หลังแก้การผูก liveness กับหน้าที่ match) |
| S3 | วิดีโอเจ้าของเครื่อง | ไม่ผ่าน (ถ้าทิศหันไม่ตรงที่สุ่ม) | |
| R1–R6 | รายการทดสอบการกู้คืนใน [Scripts/recovery.md](../Scripts/recovery.md) | ผ่านทุกข้อ | 2026-10-25: R1 ✅ (`--restore-authdb-only` ผ่าน `prlctl exec` แทน SSH → กฎเป็น `use-login-window-ui`, ล็อกแล้วไม่เรียก plugin, รหัสผ่านว่างถูกปฏิเสธ), R2 ✅ (= F2), R3 ✅ (broker คืนกฎเอง ดูด้านบน), R5 ✅, R6 ⚠️ ไฟล์ ✅ แต่ keychain ตรวจใน VM ไม่ได้ (ไม่เคยลงทะเบียน และเพิ่มรายการทดสอบไม่ได้: `User interaction is not allowed`) ต้องตรวจบนเครื่องหลัก, R4 ⏳ |
| U1 | `sudo "/Library/Application Support/FaceID/uninstall.sh"` | กฎตรงกับ `backup/original` และไม่มี right `com.example.faceid.face` | ✅ 2026-10-25: กฎตรงกับ `backup/original` ทุกตัวอักษร (ไม่นับ created/modified), ไม่มี right, เหลือแค่ `backup/`, ไม่มี plugin/LaunchAgent/LaunchDaemon/แอป, ไม่มี job หรือ process ค้าง |

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
