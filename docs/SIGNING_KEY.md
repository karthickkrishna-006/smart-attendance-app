# Android release signing key: keep it safe

The APK is signed with **`smartattend-release.jks`** (alias `smartattend`).

| Fingerprint | Value (registered in Firebase) |
|---|---|
| SHA-1 | `31:E3:3E:99:F4:5A:F0:3C:F1:25:BE:20:D4:68:9A:C5:D3:66:0F:AC` |
| SHA-256 | `64:2F:26:E4:DB:07:F5:6A:7E:63:05:FC:FD:44:8C:7F:B1:78:F8:7F:17:74:AD:C5:23:E2:75:EC:04:04:2E:8A` |

## Why it matters
- **Google Sign-In** only works for APKs signed with a key whose SHA-1 is registered in Firebase.
- **Updates:** Android installs a new version over the old one only if both are signed with the same key. If you lose the key, users must uninstall and reinstall the app, and you have to register a new SHA-1 in Firebase.

## How to store it
1. Keep **at least two copies** of `smartattend-release.jks` in different places, for example Google Drive (private) and a USB drive.
2. Store the password **separately** from the file, for example in a password manager. Don't keep it in the same folder or in the repository.
3. **Never** commit the `.jks` file or `android/key.properties` to GitHub. `.gitignore` already blocks both.
4. The four GitHub secrets are encrypted and can't be read back, even by you. GitHub is not a backup; your own copies are.

## Check a key file's fingerprint (requires Java)
```bash
keytool -list -v -keystore smartattend-release.jks -alias smartattend
```
The SHA-1 must equal the value above. The CI workflow performs this check automatically and stops the build if the key doesn't match.

## If the key is lost
1. Generate a new key:
   ```bash
   keytool -genkeypair -v -keystore new.jks -alias smartattend -keyalg RSA -keysize 2048 -validity 10000
   ```
2. In Firebase: Project settings → your Android app → **Add fingerprint**, and add the new SHA-1 and SHA-256.
3. Download the new `google-services.json` into `android/app/`.
4. Update the four GitHub secrets, and replace the expected SHA-1 in `.github/workflows/build-apk.yml` (it appears twice).
5. Users must uninstall the old app before installing the new one.
