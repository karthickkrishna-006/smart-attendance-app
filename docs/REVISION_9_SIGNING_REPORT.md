# Revision 9 report: CI signing integration

Base: Revision 8 package (GitHub `main` is still at `559712a`).
Nothing was deployed, and billing is unchanged. The production signing configuration and workflow are unchanged.

**Status:** the integration was checked by reading `build.gradle` and both workflows together, and by **executing the workflow's signing scripts** locally with real `keytool` (JDK 17) and real `jq` 1.7.1. It is **not yet proven by a GitHub Actions run**. Gradle itself was not run, because Gradle and the Android SDK cannot be downloaded in the preparation environment.

## 1. Finding on the reported issue

The reported problem ("Gradle does not read the CI environment variables") does **not** apply to `android/app/build.gradle` on GitHub (`559712a`) or in Revision 8: both define `ciDebug` from `CI_DEBUG_KEYSTORE_PATH`, `CI_DEBUG_KEYSTORE_PASSWORD`, `CI_DEBUG_KEY_ALIAS` and `CI_DEBUG_KEY_PASSWORD`.

A local copy that lacks this would explain the report: `build.gradle` was not in the Revision 5–8 zip, because it had not changed. It is included now, and the workflow refuses to build with an outdated `build.gradle`.

`key.properties` is deliberately not generated for test builds. In `build.gradle`, its presence selects **production** signing (`signingConfigs.release`), so using it for test builds would mix the two. Environment variables also keep passwords off the disk.

## 2. Which key signs what (traced from `build.gradle`, with each workflow's inputs)

| Situation | Debug APK | Release APK |
|---|---|---|
| `build-debug-apk.yml`, secrets set | CI debug key | CI debug key |
| `build-debug-apk.yml`, one secret empty | build stops | build stops |
| `build-debug-apk.yml`, all secrets empty | build stops (new) | build stops (new) |
| `build-apk.yml` (production) | — | production key (`key.properties`) |
| Local PC build | Android default debug key | Android default debug key |

## 3. Tests executed (real tools; the workflow's own scripts extracted from the YAML)

**Staging step: real JKS test keystore, store password ≠ key password**

| Case | Expected | Result |
|---|---|---|
| Valid key, SHA-1 registered | pass, export SHA-1 | PASS |
| Empty secret | fail | PASS |
| Wrong keystore password | fail | PASS |
| Wrong alias | fail | PASS |
| Wrong key password | fail | PASS |
| Corrupt keystore | fail | PASS |
| SHA-1 not registered in Firebase | fail | PASS |
| Password visible in output | never | 0 occurrences in all 7 cases |
| Keystore file permissions | 600 | 600 |

**APK verification step** (`apksigner`/`aapt2` are stand-ins with the same output format; the real tools are only on Google's servers)

| Case | Expected | Result |
|---|---|---|
| All APKs signed with the registered CI key | pass | PASS |
| One APK signed with another key | fail | PASS |
| CI key SHA-1 not provided | fail | PASS |
| `apksigner verify` fails | fail | PASS |
| Unreadable certificate line | fail | PASS (validation added after this test exposed it) |

Upload steps have no `if: always()`, so a failed check means nothing is uploaded.

**Guard and cleanup steps**

| Case | Expected | Result |
|---|---|---|
| Current `build.gradle`, no production material | pass | PASS |
| `android/key.properties` present | fail | PASS |
| `android/app/release.jks` present | fail | PASS |
| `build.gradle` from GitHub `559712a` | fail (must upload the new one) | PASS |
| Very old `build.gradle` | fail | PASS |
| Cleanup removes the keystore, certificate dumps and signing intermediates, and keeps the APKs | yes | PASS |
| Cleanup works when the build never started | yes | PASS |

YAML parsed; all step scripts pass `bash -n`.

## 4. Not verified yet

- A real GitHub Actions run (Gradle, the real `apksigner`, the real secrets).
- That the real `DEBUG_KEYSTORE_*` secrets match SHA-1 `12b6e6fa…` (the CI debug fingerprint registered in `google-services.json`). If they don't, the new check stops the build and shows the SHA-1 to register.
- Everything listed as incomplete in `docs/REVISION_8_REPORT.md` still applies: rules tests, `flutter analyze`/`flutter test`, the APK build and device tests have not been run.
