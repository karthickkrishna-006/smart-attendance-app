# Switching the live map to Google Maps

Until this is done the app uses **OpenStreetMap** automatically, and everything else works the same.

## Cost

- Google currently lists **map display in Android apps (Maps SDK for Android) as no-charge**. **Check the current pricing page before enabling it**, because Google can change it.
- Google still requires a **billing account with a card**. We use only map display: no search, directions or geocoding.
- **Set a budget alert anyway** (step 6), so any unexpected charge is noticed at once.

## Steps (about 15 minutes, on a computer)

1. Open **console.cloud.google.com** and choose the project **smart-attendance-v2-29607** (the same project as Firebase).
2. **Billing:** link a billing account if the project has none (Billing → Link a billing account).
3. **APIs & Services → Library**: search **"Maps SDK for Android"** → **Enable**.
4. **APIs & Services → Credentials → Create credentials → API key.** Then click the new key → **Edit**:
   - **Application restrictions:** *Android apps* → **Add**, with package name `in.cit.smartattendance.v2`. Add both SHA-1 fingerprints (one entry each):
     - `12:B6:E6:FA:43:EC:1C:4C:1D:5E:3F:D9:7D:53:1E:23:1A:0A:C5:FF`
     - `31:E3:3E:99:F4:5A:F0:3C:F1:25:BE:20:D4:68:9A:C5:D3:66:0F:AC`
   - **API restrictions:** *Restrict key* → tick only **Maps SDK for Android**.
   - **Save**, then copy the key.
5. **GitHub** → your repository → **Settings → Secrets and variables → Actions → New repository secret**:
   - Name: `MAPS_API_KEY`
   - Value: the key from step 4
6. **Billing → Budgets & alerts → Create budget:** for example ₹500 a month, with an e-mail alert at 50%.
7. **Actions → Build v2 (new app) → Run workflow.** In the log, the step **"Map configuration"** must say **"Google Maps: ON"**. Install the new APK.

The key is restricted to this app and this API, so it's useless to anyone who copies it. It's stored only as a GitHub secret, never in the code.
