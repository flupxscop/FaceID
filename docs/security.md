# ความปลอดภัยและความเป็นส่วนตัวของข้อมูลชีวมิติ

เป้าหมาย: **ข้อมูลใบหน้าไม่ออกจากโปรเซส `FaceIDAgent` และไม่ออกจากเครื่อง**
ส่วนไหนที่ล้มเหลว ต้องกลับไปใช้รหัสผ่าน (fail closed)

## ข้อมูลชีวมิติอยู่ที่ไหนบ้าง

| ข้อมูล | อยู่ที่ไหน | อายุ |
|---|---|---|
| ภาพจากกล้อง | หน่วยความจำของ agent เท่านั้น | ระหว่างสแกน แล้วปล่อยทิ้ง |
| embedding ระหว่างสแกน/ลงทะเบียน | หน่วยความจำของ agent เท่านั้น | ระหว่างสแกน |
| template (embedding ที่ลงทะเบียน) | Keychain เข้ารหัส AES-GCM ด้วยคีย์ที่สร้างจาก Secure Enclave | จนกว่าผู้ใช้จะลบ |

สิ่งที่ออกจาก agent ผ่าน XPC มีเพียง: ผลลัพธ์ (ตัวเลข), สถานะ เปิด/ปิด/ลงทะเบียนแล้ว/ถูกล็อก,
และความคืบหน้าการลงทะเบียน (ท่าทางถัดไป, เปอร์เซ็นต์) **ไม่มีภาพ, embedding, template หรือคะแนน similarity**

## มาตรการ

### ไม่ให้ข้อมูลหลุดออกนอกโปรเซส
- **ลงทะเบียนใบหน้าภายใน agent** (`FaceEnroller`) แอป Menu Bar แค่สั่งเริ่มและแสดงความคืบหน้า
  ภาพและ embedding จึงไม่ข้ามโปรเซส และสิทธิ์กล้องมีแค่โปรเซสเดียว
- XPC protocol ห้ามมีชนิดข้อมูลที่พาข้อมูลชีวมิติได้ (`Data`, `[Float]`, ภาพ ฯลฯ) — บังคับด้วยเทสต์
- ทุก connection ต้องผ่าน code signing requirement ก่อนรับข้อความ
  (SecurityAgent ของ Apple + แอปของเราที่ sign ด้วย**ใบรับรองเดียวกับ agent** ตรวจด้วย SHA-1 ของใบรับรอง)
  ไม่ต้องมี Apple Developer Program ดู [local-signing.md](local-signing.md)

### เส้นทางจากหน้าล็อกถึง agent (FaceIDBroker)
- plugin ถูกโหลดใน `SecurityAgentHelper` ที่รันเป็น `_securityagent` จึงไปถึง agent ใน session ของผู้ใช้โดยตรงไม่ได้
- **FaceIDBroker** (LaunchDaemon) เปิด service ระดับระบบ 2 ช่อง: `…broker.agent` ให้ agent ลงทะเบียน และ `…broker.auth` ให้ plugin
- broker จับคู่ด้วย **audit session** ส่งต่อแค่ "สแกน/ยกเลิก" และส่งกลับแค่ผลลัพธ์ + uid ของ agent ที่ตอบ ไม่มีข้อมูลชีวมิติผ่าน broker
- broker ไม่ import กล้อง/Vision/Core ML/Keychain (บังคับด้วย `PrivacyGuardTests`) ไม่มี entitlement และรันใน sandbox ที่ห้าม network
- ตรวจลายเซ็นทุกจุด:
  - plugin → broker และ agent → broker: identifier + **cdhash** ของ broker (broker sign แบบ ad-hoc เพราะ
    host ของ plugin ประเมินความเชื่อถือใบรับรองที่ไม่ใช่ของ Apple ไม่ได้) ค่ามาจาก Info.plist ของ plugin และ `pins.plist`
  - broker → plugin: เฉพาะ host ของ Apple (`SecurityAgentHelper`)
  - broker → agent: identifier + ใบรับรองของคุณ (ค่ามาจาก `pins.plist`)
- `pins.plist` ต้องเป็นของ root และไม่มีใครอื่นเขียนได้ ไม่งั้น agent/broker ไม่เชื่อ (fail closed)
- agent เปิดให้ broker เรียกได้แค่สแกน/ยกเลิก ส่วนการลงทะเบียนใบหน้าและการลบ ทำได้จากแอป Menu Bar เท่านั้น
- ไม่มี agent ใน session นั้น / agent ไม่ตอบ / ลายเซ็นไม่ผ่าน → ตอบ error → หน้าล็อกใช้รหัสผ่าน (fail closed)

### ไม่ให้ข้อมูลหลุดออกนอกเครื่อง
- **Sandbox ระดับ kernel ห้าม network ทั้งหมด** launchd เปิด agent ผ่าน `sandbox-exec` พร้อม profile `agent.sb` (`deny network*`)
  ต่อให้มีบั๊กหรือ library ถูกเจาะ ก็ส่งข้อมูลออกเครื่องไม่ได้
- ตอนเริ่มทำงาน agent ตรวจว่าเปิด socket ไม่ได้จริง ถ้า release build ไม่ได้อยู่ใน sandbox จะไม่ยอมสแกนหรือลงทะเบียนเลย
- ไม่มีโค้ด network ในโปรเจกต์ — `PrivacyGuardTests` สแกนซอร์สหา `URLSession`, `Network`, socket ฯลฯ
- Keychain: ถ้ามี entitlement จะใช้ Data Protection Keychain แบบ `WhenUnlockedThisDeviceOnly` ถ้าไม่มี (ไม่ได้สมัคร Developer Program)
  จะใช้ login keychain ของเครื่อง ทั้งสองแบบใช้ `kSecAttrSynchronizable = false` จึงไม่ขึ้น iCloud
- คีย์ Secure Enclave ใช้ได้บนเครื่องนี้เท่านั้น ต่อให้ ciphertext หลุดไปก็ถอดรหัสที่อื่นไม่ได้
- Release build **ไม่ยอมทำงานถ้าไม่มี Secure Enclave** (คีย์ software ใช้ได้เฉพาะ Debug build สำหรับทดสอบใน VM)

### ไม่ให้ข้อมูลลงดิสก์หรือ log
- ไม่มีโค้ดเขียนภาพ/ไฟล์ — บังคับด้วยเทสต์
- ห้าม `print`/`NSLog` — บังคับด้วยเทสต์; `os.Logger` ไม่ log ค่าชีวมิติแบบ public — บังคับด้วยเทสต์
- ปิด core dump (`RLIMIT_CORE = 0`) เพื่อไม่ให้หน่วยความจำ (ภาพ/embedding) ถูกเขียนลงดิสก์ตอน crash
- Hardened runtime ไม่มี `get-task-allow` → โปรเซสอื่นแนบ debugger เพื่ออ่านหน่วยความจำไม่ได้

### การลงทะเบียนและการลบ
- ก่อนบันทึก template agent เรียก LocalAuthentication ให้ระบบถามรหัสผ่านเจ้าของเครื่องเอง
  (เราไม่เห็นรหัสผ่าน) ถ้าไม่ผ่าน embedding ที่เก็บมาจะถูกทิ้งทั้งหมด
- ต้องกะพริบตาระหว่างลงทะเบียน → ลงทะเบียนด้วยรูปถ่ายไม่ได้
- ตัวอย่างทุกท่าต้องคล้ายใบหน้าตรงที่เก็บแรก → คนอื่นแทรกเข้ามากลางทางไม่ได้
- การลบ = ลบ template **และทำลายคีย์** (crypto-shredding)

### Liveness ตอนสแกน
- ต้องกะพริบตา **และ** หันศีรษะไปทางที่ระบบสุ่ม (ซ้ายหรือขวา ≥ 8°) ภายในเวลาสแกน
- ระบบบอกทิศไม่ได้ (หน้าล็อกไม่มี UI) วิธีใช้คือ "กะพริบตา แล้วหันซ้ายและขวาเล็กน้อย"
- เลือกแบบนี้โดยตั้งใจ: วิดีโอที่อัดไว้ต้องหันถูกทิศพอดีถึงจะผ่าน (โอกาสราวครึ่งหนึ่ง แทนที่จะผ่านทุกครั้ง)

### การล็อกหลังพลาดหลายครั้ง
- พลาด 3 ครั้ง → ใช้ใบหน้าไม่ได้จนกว่าจะปลดล็อกด้วยรหัสผ่าน
- ไม่มีคำสั่ง XPC ให้รีเซ็ต: agent รีเซ็ตเองเมื่อได้ยินว่าหน้าจอปลดล็อก **และ** window server ยืนยันว่า session ไม่ได้ล็อกอยู่จริง
  (notification ปลอมได้ แต่สถานะ session ปลอมไม่ได้)

## การ sign

ดู [local-signing.md](local-signing.md) (ใช้ใบรับรอง self-signed ฟรี)

## ข้อจำกัดที่ต้องรู้

- กล้อง 2D ไม่มีข้อมูลความลึก liveness แบบกะพริบตา + หันหน้า กันรูปถ่ายและวิดีโอทั่วไปได้
  แต่กันหน้ากาก 3D หรือการโจมตีที่ซับซ้อนไม่ได้
- Swift ไม่รับประกันการล้างหน่วยความจำ (zeroize) ของ array หลังใช้ ข้อมูลอาจค้างใน RAM ของ agent ชั่วคราว
  (ป้องกันด้วย hardened runtime + ปิด core dump)
- ผู้ที่รันโค้ดในบัญชีผู้ใช้ได้อยู่แล้ว (มัลแวร์) อยู่นอกขอบเขตการป้องกันของระบบนี้

- `sandbox-exec` ถูก Apple ระบุว่า deprecated แม้วันนี้ยังใช้ได้ ถ้าวันหนึ่งถูกเอาออก agent จะไม่ทำงาน
  (fail closed เพราะตรวจ isolation ไม่ผ่าน) แต่ไม่ทำงานแบบเงียบ ๆ โดยไม่มีการป้องกัน
- ผู้ที่ได้กุญแจของใบรับรอง self-signed จะ sign แอปปลอมมาเชื่อมต่อได้ ห้ามกด "Always Allow" ให้กุญแจนี้

## ต้องทดสอบใน VM

- LocalAuthentication จาก LaunchAgent, login keychain ตอนหน้าจอล็อก, การ lookup Mach service จาก SecurityAgent
- กล้อง, Vision และ Core ML ทำงานใน sandbox `deny network*` ได้ครบ (Secure Enclave ทดสอบแล้วว่าใช้ได้)
- SecurityAgent โหลด authorization plugin ที่ sign ด้วยใบรับรอง self-signed ได้หรือไม่
