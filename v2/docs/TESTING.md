# Role-by-role test checklist

Prepare once, as the System administrator:

1. **Setup → Demo → Create demo data.** Expect a green message listing what was created.
2. **Employees → Add a person** for each test account (one Gmail each). Choose the **Staff type** first (it presets the role), for example:
   - Thoomai Kavalar
   - OHT Operator
   - MNP
   - Village Panchayat Secretary
   - Zonal Deputy BDO
   - Deputy BDO (Panchayats)
   - BDO (Village Panchayats)
   - District monitoring

   Optionally also an Organisation admin and an Auditor.
3. **Setup → Access:** for the Supervisor, Zonal Secretary and AD roles, tick **Demo Block (synthetic)** (and any real area). For the Field worker, tick **Demo Street 1**.
4. **Setup → Settings:** optionally allow Supervisors to create tasks.

| Role | Check |
| --- | --- |
| **Field worker** | Home shows the duty card, today's status and open tasks. **Start duty** shows a notification. **Attendance → I am at work** shows Verified or a reason. **Activity:** take 1 to 3 photos and send; it appears under "My reports". **Tasks:** Start work, Send photo proof. **Stop duty** ends the notification. The worker never sees street entry and exit times. |
| **Supervisor** | Overview figures for today. **Attendance:** demo workers and real ones in the ticked areas. **Field activities:** approve, redo or reject, with the reason shown to the worker. **Tasks:** approve submitted work. **Live monitoring:** map with workers and boundaries; tap a worker to see the route and street in/out times. **Coverage, Reports** (Copy works), **Alerts.** |
| **Zonal Secretary / AD** | As Supervisor, plus **Tasks → New task** for a street; the worker in that street sees it. |
| **District Collector** | Everything in the district, without assigning areas; no task creation unless switched on. |
| **Organisation admin** | Only their organisation's records (demo data has none, so use a real worker of that organisation). **Employees:** add a field worker to their organisation. No Live monitoring. |
| **Auditor** | Attendance, field activities, coverage and reports read-only; Audit log. No Live monitoring. |
| **System administrator** | Setup and Audit log only; no attendance or locations of real workers. |

What to expect if an AD, Zonal Secretary or Supervisor screen is empty: a yellow notice explains that **no area is assigned to the role**. Fix it in **Setup → Access**.


## Staff photo attendance (new)

- **Thoomai Kavalar:** the Attendance tab shows **09:00 and 13:00**. Take a GPS photo now; the nearest time turns **Done** if within 60 minutes, and a time 60 minutes past turns **Missed**.
- **OHT Operator:** the screen asks for a photo **when the water is opened**.
- **MNP / VP Secretary / Zonal Dy.BDO / BDO:** the menu has **My attendance** (own photos) and **Attendance → GPS photos** (staff compliance, filters for village or block staff).
- **District admin:**
  - **Setup → Messages:** send to all, or to chosen staff types. Then check it appears under **Messages** for those staff only.
  - **Setup → Areas:** add a **habitation** under a village panchayat.
  - **Setup → Boundaries → Draw on map:** tap the corners, then Save.
  - **Setup → Access:** tap a role to change areas and **staff type**.
