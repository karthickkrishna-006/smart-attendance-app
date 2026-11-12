# Staff types, monitoring roles and GPS photo attendance

Set the **staff type** when adding a person (**Employees → Add a person**). It presets the right monitoring role, and the admin can still change both later in **Setup → Access**.

## Village panchayat staff

Assign them to **habitations** (or the whole village panchayat).

| Staff type | App | GPS photo attendance |
| --- | --- | --- |
| Thoomai Kavalar | Field worker app: duty tracking, tasks, photo reports | 2 photos: **09:00 and 13:00** (±60 min) |
| OHT Operator | Field worker app | 1 photo **when the water is opened** |
| Makkal Nala Paniyalar (MNP) | Monitoring of their panchayat or habitations (oversees Thoomai Kavalars), reviews work | **at least 3** at any time |
| Village Panchayat Secretary | Monitoring of their panchayat (oversees all VP staff), reviews work | **4**: 10:00, 13:00, 15:00, 18:00 |

## Block panchayat staff

| Staff type | App | GPS photo attendance |
| --- | --- | --- |
| Zonal Deputy BDO | Monitoring of their zone (5–12 village panchayats: give the zone area or up to 15 panchayats); creates tasks | **at least 4** |
| Deputy BDO (Panchayats) | Worker app (assign the block) | **2**: 10:00 and 18:00 |
| Deputy BDO (Regular) | Worker app (assign the block) | **2**: 10:00 and 18:00 |
| BDO (Village Panchayats) | Monitoring of the whole block: all staff, live map, coverage, reports, tasks | own attendance (1+) |
| BDO (Block Panchayat) | Monitoring of the whole block | own attendance (1+) |

## District

| Login | What it does |
| --- | --- |
| District monitoring | Whole-district monitoring: dashboards, live map, attendance, photos, coverage, reports |
| District admin (System administrator) | Adds staff and **assigns roles and staff types**, **sends messages** (Setup → Messages), **fixes boundaries** (Setup → Boundaries: draw on map, circle or GeoJSON) for panchayats, habitations and blocks. Sees no operational data. |

## Area structure

District → Block → (Zone) → Village panchayat → **Habitation** → (street or site)

- The **habitation is the unit** panchayat staff are assigned to.
- Boundaries can be drawn for any level: habitation and panchayat boundaries for village staff, block boundaries for block staff.

## How photo attendance counts

- Each photo counts for at most one scheduled time: the nearest one within 60 minutes.
- A time is **missed** once 60 minutes have passed without a photo.
- The day is **complete** when the minimum number of photos is reached and every scheduled time is done.
- The first photo of the day also marks the day's attendance, so all dashboards count the person as present.
- Monitors see this under **Attendance → GPS photos**, filtered by incomplete, village panchayat staff or block staff.
