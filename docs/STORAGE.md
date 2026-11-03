# Evidence images and biometric data: storage design

## Design
| Data | Where | Who can read |
|---|---|---|
| Field evidence photos | **Cloud Storage for Firebase**, `evidence/{uid}/{activityId}/{0-2}.jpg` (JPEG ≤ 1.5 MB, max 3 per activity) | the uploading worker, plus admin/supervisor/auditor (`storage.rules`) |
| Activity record | Firestore `activities/{id}`; the `images` field holds **object paths only** | owner, plus staff/auditor |
| Face template (192-number embedding) | Firestore `face_templates/{uid}` | **owner only** |
| Face photos / selfies | **Never stored.** Captured to a temporary file, processed on the device, then deleted | nobody |

Additional controls:
- Uploads are write-once: no overwrite or delete, so evidence can't be swapped.
- Images are read through the Firebase SDK (`getData`), so the security rules are checked on every read. Public "download URLs" are **not** used, because they are bearer links that bypass the rules.
- Photos are resized to at most 1280 px and re-encoded on the device, which strips the original EXIF metadata. Location is recorded separately in the activity record.

## ⚠️ Billing requirement
Since **October 2024**, creating a Cloud Storage bucket for Firebase requires the **Blaze (pay-as-you-go) plan**. Blaze still includes a no-cost usage quota, but a billing account (card) must be linked.

- **Without Blaze (Spark plan):** leave *Settings → Enable photo evidence uploads* **off** (the default). Activities are still recorded with text, measurement and GPS, and the form clearly says photos are disabled. No images are stored anywhere.
- **With Blaze:**
  1. Firebase console → **Storage → Get started** (choose a location, e.g. `asia-south1`).
  2. **Storage → Rules**: paste `storage.rules` and click **Publish**.
  3. In the app, as Admin: *Settings → Enable photo evidence uploads* → **Save rules**.
  4. Set a **budget alert** in Google Cloud Billing (for example ₹100/month) to avoid surprises.

## Retention (to be approved by the project, Report §11)
Suggested policy:
- **Evidence photos:** keep for the audit period (e.g. 1 year). Remove them with a Cloud Storage lifecycle rule (console → Storage → Lifecycle).
- **Face templates:** delete when a worker leaves, using *Worker → Delete face reference* (admin); the deletion is audited.
- **Verification logs:** contain only outcomes and similarity scores, no images or templates.
