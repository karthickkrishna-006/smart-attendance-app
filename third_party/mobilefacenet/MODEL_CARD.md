# Face embedding model: provenance and specification

| Item | Value |
|---|---|
| File in this project | `assets/models/mobilefacenet.tflite` (bundled; not downloaded at build time) |
| Obtained from | GitHub `MCarlomagno/FaceRecognitionAuth`, path `assets/mobilefacenet.tflite` |
| Pinned commit | `82372440f26d699e13996014a01805f925dbcdbb` |
| Pinned URL | `https://github.com/MCarlomagno/FaceRecognitionAuth/raw/82372440f26d699e13996014a01805f925dbcdbb/assets/mobilefacenet.tflite` |
| Size | 5,233,552 bytes |
| SHA-256 | `be4bc7cfc53f7bc336d0f28b1ab92535f618c913a422b683210750f6b5354854` (also in `assets/models/mobilefacenet.sha256`; verified in CI) |
| Format | TFLite flatbuffer, identifier `TFL3`, schema version 3, description "TOCO Converted", 370 tensors |
| Input tensor | `input`: float32 `[1, 112, 112, 3]` (RGB) |
| Output tensor | `embeddings`: float32 `[1, 192]` |
| Pre-processing (matches source project) | `(pixel − 128) / 128` per channel |
| Post-processing (this app) | L2-normalise, then compare by cosine similarity |

The tensor names, shapes and types above were read directly from the file's flatbuffer, not taken from documentation. At runtime the app checks the input and output shapes and reports the face service as **unavailable** if they don't match.

## Licences
- The redistributing repository (`FaceRecognitionAuth`) is **BSD 3-Clause** (© 2020 Marcos Carlomagno). A copy is in `LICENSE-FaceRecognitionAuth-BSD-3-Clause.txt`.
- The MobileFaceNet architecture's best-known TensorFlow implementation, `sirius-ai/MobileFaceNet_TF` (checked at commit `f0bae598`), is **Apache-2.0**. A copy is in `LICENSE-MobileFaceNet_TF-Apache-2.0.txt`.

## ⚠️ Provenance gap (must be resolved before production)
The source repository does **not** document which checkpoint or training dataset this `.tflite` was converted from. Public MobileFaceNet weights are commonly trained on MS-Celeb-1M / MS1M-derived datasets, which carry their own licensing and ethical restrictions. Because of this:
- The model is suitable for **academic demonstration only**.
- Accuracy, demographic bias and the verification threshold (default 0.60 cosine) have **not** been evaluated for this population.
- Before deployment, the AI implementation team must supply an approved model with documented training data, licence and a calibrated threshold (Product Report §5.3).

## Biometric data handling in this app
- No face photo is ever uploaded or stored; selfies stay as temporary files on the device.
- Only the 192-number embedding (the "template") is stored, in `face_templates/{uid}`. Under the security rules, **only that user can read it**; administrators can delete it but can't read it.
- Each verification attempt logs only the outcome and similarity score (`verifications`), not the image or the embedding.
