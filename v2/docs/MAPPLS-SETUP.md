# Mappls map: setup and maintenance

The app's map is **Mappls (MapmyIndia)**. Mappls only works with **licence files issued for this app**, tied to:

- **Package name:** `in.cit.smartattendance.v2`
- **Signing key SHA-256:** `2F:40:5A:DB:DA:E8:92:29:6F:08:0D:08:99:E0:19:87:65:C6:BE:54:67:81:06:29:A5:41:A9:91:E3:9B:A9:EE` (the CI key that signs the APKs from "Build v2 (new app)")

## Where the licence lives

GitHub → Settings → Secrets and variables → Actions:

| Secret | Content |
|---|---|
| `MAPPLS_OLF_B64` | The `.a.olf` file, as Base64 text |
| `MAPPLS_CONF_B64` | The `.a.conf` file, as Base64 text |
| `MAPPLS_APP_ID` | The part of the file name before `.a.olf` |

The build writes the files into `android/app` only while building, never prints them, and deletes them afterwards. **If a secret is missing, the build stops with a clear message.** This is intentional: an app without a valid licence would close at start-up.

## When to update the licence

- **The signing key changes** (for example a production key for Google Play): register the new key's SHA-256 in the Mappls console, download the config files again, and update the two `_B64` secrets.
- **The app crashes at start with "Invalid Configuration … Package Name / App Fingerprint"**: the SHA-256 or package name in the Mappls console doesn't match the APK.

## Turning a file into Base64 text (Windows PowerShell)

```
$olf = [Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\to\APPID.a.olf")); $olf | Set-Clipboard
```

Paste it into the secret right away, then do the same for the `.a.conf` file.

## Cost

Usage is charged against the Mappls account wallet (it started with ₹1,000 credit). Check **Usage** and the wallet in the Mappls console every week during the pilot, and ask Mappls for a quote or government plan before district-wide use.
