# Beginner guide: upload to GitHub and get the APK

You don't need Flutter or Android Studio on your computer. GitHub builds the APK for you, for free.

## What you need
- The project ZIP (`smart-attendance-app.zip`)
- Your signing key file **`smartattend-release.jks`** (sent to you separately; it is *not* in the ZIP)
- The keystore password (sent to you with the key file)
- A GitHub account

---

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
4. Check that `.github/workflows/build-apk.yml` is visible in the repository. If it's missing, create it manually: **Add file → Create new file**, name it `.github/workflows/build-apk.yml`, and paste in the contents of that file from the ZIP.

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
3. Wait about 10–15 minutes. A green tick means success.

## Step 6: Download and install the APK
1. Open the repository's **Releases** (right-hand side of the main page) and download `SmartAttendance-v1.0.N.apk`.
   You can also get it from **Actions → (the run) → Artifacts → SmartAttendance-APK**, which downloads a ZIP containing the APK.
2. Send the APK to your phone, open it and allow "Install unknown apps" when Android asks.

## Step 7: Publish the Firestore security rules (once)
In Firebase console, go to **Firestore Database → Rules**, replace the text with the contents of `firestore.rules`, and click **Publish**. Without this, the app shows "Permission denied".

---

## If the build fails (red ✗)
Click the failed run, then the red step, and read the last lines.

| Message | Fix |
|---|---|
| `KEYSTORE_BASE64 is missing` | Add the secrets (Step 4). Names must match exactly. |
| `Keystore SHA-1 does not match` | You uploaded a different key file or a wrong base64. Redo Step 4 with `smartattend-release.jks`. |
| `keystore password was incorrect` | Fix `KEYSTORE_PASSWORD` / `KEY_PASSWORD`. |
| `Face model download failed` | Temporary network issue; click **Re-run jobs**. |
| Dart/Gradle compile errors | This project has **not yet been compiled** (see `docs/STATUS.md`). Copy the error lines and ask for a fix; the fix is usually a small code change. |
