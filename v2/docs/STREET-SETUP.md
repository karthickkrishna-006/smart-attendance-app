# Real street setup: automatic check-in/check-out

Example: **Sri Ram Nagar** has 8 zones to clean. A Thoomai Kavalar enters at 09:30, cleans the zones, and leaves for the next street at 10:03. The dashboard shows:

> karthick · Sri Ram Nagar · In 09:30 · Out 10:03 (33 min) · Zones 8/8 · **Completed**

## One-time setup (district admin, in the app)

1. **Setup → Areas → Add area**
   - **Level:** `location` (a street)
   - **Inside which area?** The habitation (or village panchayat)
   - **Name:** `Sri Ram Nagar`
2. **Setup → Boundaries → Draw on map**
   - Choose **Sri Ram Nagar**.
   - Tap the corners of the street area, about 20–30 m on each side of the street, then **Save**.
3. **Setup → Boundaries → tap "Sri Ram Nagar boundary"** (the pin icon on the right)
   - Tap inside the street at each cleaning zone: **Zone 1 … Zone 8** appear as numbered circles of 25 m.
4. **Assign the worker**
   - **New person:** **Employees → Add a person**, with **Staff type** *Thoomai Kavalar* and areas *Sri Ram Nagar* (and their other streets, up to 15) or their **habitation**.
   - **Already signed in:** **Setup → Access**, then tap their role and tick the streets.

## Every day (worker)

1. **Home → Phone setup for tracking** (once per phone).
2. **Start duty.** The notification *"Field duty in progress"* appears.
3. Walk into Sri Ram Nagar.
   - **After 1 minute inside:** checked in, with the time they **entered**, for example 09:30.
   - Attendance is also marked if this is the first street of the day.
4. Clean the zones. Each zone is ticked when the worker reaches it (within 25 m, with good GPS). The duty card shows *"Sri Ram Nagar: 5 of 8 zones cleaned"*; **no times are shown to the worker**.
5. Walk to the next street.
   - **After 2 minutes outside:** checked out, with the time they **left**, for example 10:03.
   - The next street's check-in starts automatically.
6. **Stop duty** at the end of the day: the last street is checked out and attendance is checked out.

## Watching it (officers)

- **Street check-in/out:** every visit, with in, out, minutes and zones, as 🟠 **In progress**, ✅ **Completed** or 🔴 **Left incomplete**. **Copy table** gives CSV for Excel or WhatsApp.
- **Live monitoring:** workers as moving dots; streets coloured by today's status; zone circles turn green when cleaned. Tap a worker for their route and visits.
- **Overview:** today's totals: in progress, completed, left incomplete.

## Accuracy notes

- Phone GPS is usually accurate to 5–15 m outdoors. Draw street boundaries generously, and don't place zones closer than about 30 m apart.
- Check-in waits **1 minute** and check-out **2 minutes**, so walking past a street or a short GPS jump doesn't count. The recorded times are still the real entry and exit times.
