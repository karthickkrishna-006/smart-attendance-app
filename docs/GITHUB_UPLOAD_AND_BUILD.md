# Beginner guide: upload to GitHub and get the APK

You don't need Flutter or Android Studio on your computer. GitHub builds the APK for you, for free.

## What you need
- The project ZIP (`smart-attendance-app.zip`)
- Your signing key file **`smartattend-release.jks`** (sent to you separately; it is *not* in the ZIP)
- The keystore password (sent to you with the key file)
- A GitHub account

---

## Step 0: Set your admin email (2 minutes)
`firestore.rules` already contains the authorised first-admin address (`krish.sep2006@gmail.com`). Nothing to change unless the admin changes; see `docs/SECURITY_SETUP.md`.

## Step 1: Unzip the project
Extract the ZIP. You should get a folder `smart-attendance-app/` containing `lib/`, `android/`, `.github/`, `pubspec.yaml`, `README.md` and more.

> The `.github` folder starts with a dot, so Windows and macOS may hide it. It **must** be uploaded, because it contains the build workflow. This is why Step 3 recommends GitHub Desktop, which never skips it.

## Step 2: Create the repository
1. Go to github.com, click **+** (top right), then **New repository**.
2. Name: `smart-attendance-app`. Visibility: **Private**.
3. **Do not** tick "Add a README". Click **Create repository**.

## Step 3: Upload the code

### Option A: GitHub Desktop (recommended)
1. Install GitHub Desktop from desktop.github.com and sign in.
2. Click **File → Add local repository** and choose the unzipped `smart-attendance-app` folder.
3. If it says "this is not a git repository", click **create a repository** and keep the defaults.
4. Write the summary "Initial upload" and click **Commit to main**.
5. Click **Publish repository** (or **Push origin**). If it asks, choose your existing `smart-attendance-app` repository and keep it **Private**.

### Option B: Web browser upload
1. Open your empty repository and click **uploading an existing file**.
2. Open the unzipped folder, turn on "show hidden files" (Windows: View → Show → Hidden items; macOS: Cmd+Shift+.), select **everything inside it, including `.github`**, and drag it onto the page.
3. Click **Commit changes**.
4. Check that `.github/workflows/build-apk.yml` and `android/gradlew` are visible in the repository. (Browser uploads drop the "executable" flag on `gradlew`; the workflow restores it with `chmod +x`, so that's fine.) If the workflow file is missing, create it manually: **Add file → Create new file**, name it `.github/workflows/build-apk.yml`, and paste in the contents of that file from the ZIP.

## Step 4: Add the 4 signing secrets
GitHub signs the APK with your key. The key is stored as an encrypted secret, never as a file in the repository.

In your repository, go to **Settings → Secrets and variables → Actions → New repository secret**. Create these four:

| Name | Value |
|---|---|
| `KEYSTORE_BASE64` | your `.jks` file converted to text (see below) |
| `KEYSTORE_PASSWORD` | the keystore password |
| `KEY_ALIAS` | `smartattend` |
| `KEY_PASSWORD` | the same password as the keystore |

**Converting the `.jks` file to text (base64):**
- **Windows (PowerShell):** open PowerShell in the folder containing the key, then run
  ```powershell
  [Convert]::ToBase64String([IO.File]::ReadAllBytes("$PWD\smartattend-release.jks")) | Set-Clipboard
  ```
  The text is now copied; paste it as the value of `KEYSTORE_BASE64`.
- **macOS / Linux:**
  ```bash
  base64 -i smartattend-release.jks | tr -d '\n' | pbcopy     # macOS
  base64 -w0 smartattend-release.jks                           # Linux (copy the output)
  ```

## Step 5: Run the build
1. Open the **Actions** tab. If asked, click **I understand my workflows, go ahead and enable them**.
2. Choose **Build Android APK**, then **Run workflow**, then **Run workflow**. Every later push to `main` also builds automatically.
3. Wait about 10–15 minutes. Two jobs run: **rules-test** (security rules) and **build** (APK). Both need a green tick.

> **Making `gradlew` executable in git (GitHub Desktop / command line):** the ZIP stores it as executable and `.gitattributes` keeps Unix line endings. If you commit from Windows, run this once in the project folder: `git update-index --chmod=+x android/gradlew`, then commit. The CI also runs `chmod +x`, so the build works either way.

## Step 6: Download and install the APK
1. Open the repository's **Releases** (right-hand side of the main page) and download `SmartAttendance-v1.0.N.apk`.
   You can also get it from **Actions → (the run) → Artifacts → SmartAttendance-APK**, which downloads a ZIP containing the APK.
2. Send the APK to your phone, open it and allow "Install unknown apps" when Android asks.

## Step 7: Publish the Firestore security rules (once)
Only after the **rules-test** job is green: in Firebase console, go to **Firestore Database → Rules**, paste your edited `firestore.rules` and click **Publish**. Then sign in **first** with your admin Gmail. Other users will see "Awaiting approval" until you activate them. Full procedure: `docs/SECURITY_SETUP.md`.

---

## If the build fails (red ✗)
Click the failed run, then the red step, and read the last lines.

| Message | Fix |
|---|---|
| `KEYSTORE_BASE64 is missing` | Add the secrets (Step 4). Names must match exactly. |
| `Keystore SHA-1 does not match` | You uploaded a different key file or a wrong base64. Redo Step 4 with `smartattend-release.jks`. |
| `keystore password was incorrect` | Fix `KEYSTORE_PASSWORD` / `KEY_PASSWORD`. |
| `mobilefacenet.tflite: FAILED` (checksum) | The model file was corrupted during upload. Re-upload `assets/models/mobilefacenet.tflite` from the ZIP. |
| `Gradle wrapper validation failed` | Re-upload `android/gradle/wrapper/gradle-wrapper.jar` from the ZIP; don't edit it. |
| `rules-test` job fails | A security rule doesn't behave as the test expects. Copy the failing test name and error and ask for a fix. Don't publish those rules until it passes. |
| `flutter analyze` reports warnings | Analysis warnings now fail the build on purpose. Copy them and ask for a fix. |
| Dart/Gradle compile errors | This project has **not yet been compiled** (see `docs/STATUS.md`). Copy the error lines and ask for a fix. |

## CI debug APK signing (separate from release signing)

The **Build Debug APK** workflow signs with a dedicated, stable debug keystore. This key is separate from `smartattend-release.jks` and the four release secrets above. Do not commit the keystore or its passwords.

Create one keystore on a trusted machine with Java `keytool` available (Android Studio and Flutter are not needed). Keep the generated file in a secure location and back it up securely:

```text
keytool -genkeypair -v -keystore smartattendance-ci-debug.jks -storetype JKS -keyalg RSA -keysize 2048 -validity 10000 -alias smartattendance-ci-debug
```

Set the four following repository secrets under **Settings → Secrets and variables → Actions**. Use the same keystore and values for all debug builds so the signing fingerprint stays stable:

| Secret name | Value |
|---|---|
| `DEBUG_KEYSTORE_BASE64` | Base64 encoding of `smartattendance-ci-debug.jks` |
| `DEBUG_KEYSTORE_PASSWORD` | Keystore password chosen during key creation |
| `DEBUG_KEY_ALIAS` | `smartattendance-ci-debug` (or the alias chosen during key creation) |
| `DEBUG_KEY_PASSWORD` | Password for that key alias |

For PowerShell, copy the Base64 value without writing it into the repository:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("$PWD\smartattendance-ci-debug.jks")) | Set-Clipboard
```

For macOS, encode the file and paste the output directly into the `DEBUG_KEYSTORE_BASE64` secret:

```bash
base64 -i smartattendance-ci-debug.jks | tr -d '\n'
```

For Linux:

```bash
base64 -w0 smartattendance-ci-debug.jks
```

Before building, the workflow checks the debug keystore, alias and both passwords, reads the key's **SHA-1** (a public fingerprint, not a secret) and **stops the build** if that SHA-1 is not registered for `in.cit.smartattendance` in `android/app/google-services.json`. The error message shows the SHA-1. To fix it: in Firebase Console open **Project settings → General → Your apps**, select Android app `in.cit.smartattendance`, add that SHA-1 under **SHA certificate fingerprints** (keep the release SHA-1 too), download the refreshed `google-services.json`, replace `android/app/google-services.json` and run the build again.

After the build, every APK is checked again: it must be signed with exactly that CI debug key, or the build fails and no APK is uploaded. Passwords are never printed. The keystore is deleted at the end of every run, including failed runs.

| Debug build error | Meaning / fix |
|---|---|
| `Required GitHub Actions secret DEBUG_… is missing or empty` | Add the named secret (table above). |
| `keystore, key alias or keystore password is invalid` | Check `DEBUG_KEYSTORE_BASE64`, `DEBUG_KEYSTORE_PASSWORD`, `DEBUG_KEY_ALIAS`. |
| `DEBUG_KEY_PASSWORD does not open the key` | Fix `DEBUG_KEY_PASSWORD`. |
| `CI debug key's SHA-1 (…) is not registered` | Register that SHA-1 in Firebase and replace `google-services.json` (see above). |
| `android/key.properties must not exist …` | Delete `android/key.properties` / `android/app/release.jks` from the repository; production signing belongs only to the release workflow. |
| `build.gradle does not read …` | Upload the current `android/app/build.gradle`. |
| `… is signed with SHA-1 …, not the CI debug key` | The APK was signed with a different key; the build was stopped and nothing was uploaded. |

Profile access failures also produce a `[profile-diagnostic]` log entry with the operation, Firebase project ID, authenticated UID, `users/{uid}` path, and Firebase error code. It does not log passwords, tokens, email addresses, or exception messages.
