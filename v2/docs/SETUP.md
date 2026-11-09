# Setup

## 1. Firebase project (free Spark plan is enough)

1. Create a Firebase project, or use the existing **smart-attendance-v2-29607**.
2. **Project settings → Your apps → Add app → Android:**
   - Package: `in.cit.smartattendance.v2`
   - Add both SHA-1 fingerprints:
     - CI test key: `12:B6:E6:FA:43:EC:1C:4C:1D:5E:3F:D9:7D:53:1E:23:1A:0A:C5:FF`
     - Release key: `31:E3:3E:99:F4:5A:F0:3C:F1:25:BE:20:D4:68:9A:C5:D3:66:0F:AC`

     A key you sign with yourself needs its own SHA-1 added.
3. Download `google-services.json` and put it in `v2/android/app/`.
4. **Authentication → Sign-in method:** enable **Google** and **Email/Password**.
5. **Firestore Database → Create database:** location `asia-south1` (Mumbai), production mode.
6. **Firestore → Rules:** paste `v2/firestore.rules` and **Publish**.
   - Publish only a version whose rules tests passed in CI.
   - **Publish again every time `firestore.rules` changes.**
7. **Indexes (optional):** the app works without them. Area + day queries fall back to area-only queries filtered on the phone. For speed with many records, create them with the Firebase CLI (`firebase deploy --only firestore:indexes` from `v2/`), or click the link Firestore shows in the logs.

## 2. Build the app

### A. GitHub Actions (no tools on your computer)

Push the repository. **Actions → Build v2 (new app)** runs the analyzer, unit tests and Firestore rules tests, then builds signed APKs.

- Download **V2-PHONE-INSTALL-arm64** from the run's Artifacts.
- The build needs the four CI signing secrets already configured in the repository: `CI_DEBUG_KEYSTORE_BASE64`, `CI_DEBUG_KEYSTORE_PASSWORD`, `CI_DEBUG_KEY_ALIAS`, `CI_DEBUG_KEY_PASSWORD`.

### B. Locally

Requires Flutter 3.27.x, Android SDK 34 and JDK 17.

```
cd v2
flutter pub get
flutter analyze --no-fatal-infos
flutter test
flutter run            # phone connected with USB debugging
```

A local debug build is signed with your own debug key. Add its SHA-1 in Firebase (step 1.2), otherwise Google sign-in fails with `ApiException: 10`. Get it with:

```
keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android
```

### Rules tests locally (optional)

Requires Node 20 and Java 17.

```
cd v2/tests/rules
npm install
npx firebase emulators:exec --only firestore --project demo-field-monitor --config ../../firebase.json "npm test"
```

## 3. First use

1. Sign in with `krish.sep2006@gmail.com`. It becomes the System administrator (only the first time).
2. **Setup → Areas:** add the district, blocks, zones, panchayats and streets (official names).
3. **Setup → Boundaries:** draw circles or import official GeoJSON for each street or panchayat.
4. **Setup → Organisations:** add the department and each third-party firm.
5. **Employees:** add each person by sign-in e-mail with their role, areas and organisation. They get access when they first sign in.
6. **Setup → Access:** check each officer's areas. **AD, Zonal Secretary and Supervisor see only the areas ticked here.**
7. Optional: **Setup → Demo → Create demo data** for realistic screens. For an AD, Zonal Secretary or Supervisor to see it, tick **Demo Block (synthetic)** for them in Access. **Remove demo records** when finished.
