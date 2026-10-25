# โมเดล face embedding

## ที่เลือก: SFace (OpenCV Zoo) — Apache 2.0

| | |
|---|---|
| ไฟล์ต้นทาง | `face_recognition_sface_2021dec.onnx` (38,696,353 ไบต์) |
| SHA-256 | `0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79` |
| เอาต์พุต | embedding 128 มิติ (Core ML ตรงกับ ONNX: cosine 1.000000) |
| แหล่ง | https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface |
| License | Apache 2.0 ("All files in this directory are licensed under Apache 2.0 License") |
| สถาปัตยกรรม | MobileFaceNet ที่ฝึกด้วย SFace loss (Zhong et al.) |
| ความแม่นยำ (ตาม README ของ OpenCV Zoo) | 0.9940 |
| Threshold อ้างอิง (opencv_zoo `sface.py`) | cosine ≥ 0.363 |

ข้อควรรู้:
- Apache 2.0 อนุญาตใช้เชิงพาณิชย์ ต้องเก็บข้อความ license/attribution ไว้เมื่อแจกจ่าย — ดู [NOTICE](NOTICE)
- License ครอบคลุมไฟล์โมเดล แต่ข้อมูลที่ใช้ฝึก (ชุดภาพใบหน้า) อาจมีเงื่อนไขของตัวเอง ถ้าจะขายผลิตภัณฑ์ควรตรวจกับต้นทาง (github.com/zhongyy/SFace)
- เป็นโมเดลเล็ก เหมาะกับการรันบนเครื่อง แม่นยำน้อยกว่าโมเดลใหญ่ (ArcFace ResNet100)

## ตัวที่ไม่เลือก

| โมเดล | เหตุผล |
|---|---|
| InsightFace (buffalo_l / ArcFace) | โมเดลที่ฝึกแล้ว "non-commercial research purposes only" (โค้ด MIT แต่ตัวโมเดลไม่ใช่) |
| dlib `dlib_face_recognition_resnet_model_v1` | ผู้สร้างประกาศเป็น public domain แต่เป็นรูปแบบ dlib DNN ไม่มีทางแปลงเป็น Core ML ตรง ๆ |
| Apple Vision `VNGenerateImageFeaturePrintRequest` | ไม่ได้ออกแบบมาเพื่อระบุตัวบุคคลจากใบหน้า |

## วิธีแปลง

ทำบนเครื่อง build (ไม่ต้องใช้ sudo) ใน virtualenv แยก:

```bash
python3 -m venv .venv-model
```

```bash
.venv-model/bin/python -m pip install "coremltools==8.3.0" "torch==2.5.1" "onnx==1.17.0" "onnx2torch==1.5.15" "onnxruntime==1.19.2" "numpy<2" pillow
```

```bash
.venv-model/bin/python -I Models/convert_sface.py Models/downloads/face_recognition_sface_2021dec.onnx Models/FaceEmbedding.mlpackage
```

สคริปต์จะเทียบผลของ Core ML กับ onnxruntime บนภาพสุ่ม ต้องได้ cosine ≥ 0.9999 จึงยอมบันทึก
จากนั้น `Scripts/build-app.sh` จะ compile เป็น `dist/FaceEmbedding.mlmodelc` ให้ install.sh ใช้

## สัญญาของโมเดล (ฝั่ง Swift ต้องทำให้ตรง)

- อินพุต `face`: ใบหน้า **ที่จัดแนวแล้ว** 112×112 RGB ค่า 0–255 — ทำใน `Sources/FaceIDCore/Recognition/FaceAlignment.swift`
  (จุดจาก Vision landmarks, similarity transform, Core Image ปิด color management, นอกภาพเป็นสีดำ) และ `QualityGate` ไม่ส่งเฟรมที่ไม่มีจุดครบ
- การจัดแนว: similarity transform ของจุด 5 จุด (ตา 2, จมูก, มุมปาก 2) ไปยังจุดอ้างอิงของ OpenCV
  `(38.2946, 51.6963) (73.5318, 51.5014) (56.0252, 71.7366) (41.5493, 92.3655) (70.7299, 92.2041)`
- เอาต์พุต `embedding`: ยังไม่ normalize — Matcher ใช้ cosine similarity อยู่แล้ว
- ⚠️ `FaceIDConfig.matchThreshold = 0.62` เข้มกว่าค่าอ้างอิงของ SFace (0.363) มาก: ปลอดภัย (คนอื่นผ่านยากมาก)
  แต่เจ้าของอาจไม่ผ่านบ่อย ต้องวัด FAR/FRR ก่อน แล้วจึงตัดสินใจปรับ (CLAUDE.md §11)
