# Clockwise + Home Assistant

The clock speaks MQTT with **auto-discovery**, so Home Assistant builds the
whole device by itself — no YAML for the entities. This folder adds an optional
custom **card** that recreates the clock's 7-segment face with live data and
controls.

> `clock_helpers.yaml` here is the **old** manual-helper approach and is now
> **superseded** by auto-discovery — you don't need it. Kept only for reference.

---

## 1. One-time setup

1. **Broker** — install the **Mosquitto broker** add-on in HA
   (Settings → Add-ons → Add-on store → Mosquitto broker → Install → Start).
2. **MQTT integration** — Settings → Devices & Services → Add → **MQTT**
   (it usually auto-detects Mosquitto; accept the defaults).
3. **Point the clock at it** — in the Clockwise app: Settings → Advanced → MQTT
   → enter Home Assistant's **IP address**, port **1883**, and the Mosquitto
   username/password if you set one → Save.

Within a few seconds a **Clockwise** device appears under
Settings → Devices & Services → MQTT, with all the entities:

| Entity | |
|---|---|
| `binary_sensor.clockwise_presence` / `_moving` / `_still` | radar |
| `sensor.clockwise_distance` | metres |
| `number.clockwise_brightness` | 0–100 |
| `select.clockwise_mode` | manual / schedule / sun |
| `switch.clockwise_logo` / `_dim` | logo LED, dim-when-empty |
| `button.clockwise_sync` / `_reboot` | |
| `sensor.clockwise_rssi` / `_uptime` / `_freeheap` / `_resetreason` / `_online` | diagnostics |
| `sensor.clockwise_time` / `_date` / `_dow` | what the display shows (for the card) |

That alone is enough to use the clock in automations and a normal dashboard.

---

## 2. The clock-face card (optional but nice)

Recreates the real display — days column, live time (colon blinks 1s on / 1s
off like the real clock), red logo dot, amber bar, D/M/Y — with the controls
tucked below. A **connection dot** (green Connected / red Offline) reflects HA
reachability via the `online` entity, and the Sync/Reboot buttons flash a brief
confirmation when tapped.

1. Copy **`clockwise-card.js`** into your HA config's **`www/`** folder
   (so it's at `<config>/www/clockwise-card.js`). Create `www/` if missing.
2. **Register it:** Settings → Dashboards → (top-right ⋮) → **Resources** →
   **Add Resource**
   - URL: `/local/clockwise-card.js`
   - Type: **JavaScript Module**
   (If you don't see "Resources", enable Advanced Mode on your user profile.)
3. **Add the card** to any dashboard (Edit dashboard → Add Card → bottom:
   "Manual"), with:
   ```yaml
   type: custom:clockwise-card
   ```
   That's it — no other config in the common case.

### If the entities aren't found

The card **auto-detects** the entity names, so it works even if your device was
renamed (e.g. entities are `testing_unit_displayed_time` instead of
`clockwise_time`). It finds the set with a live time value and matches both the
short keys and HA's longer display-name slugs (`displayed_time`, `day_of_week`,
`logo_led`, `dim_when_empty`, `wifi_signal`). No config needed in the normal case.

If you run **two clocks** and want to pin the card to a specific one, set the
prefix (the part of the entity_id between the domain and the last word):

```yaml
type: custom:clockwise-card
prefix: clockwise        # e.g. number.clockwise_brightness
```

Check an entity's exact id under Settings → Devices & Services → Entities.

> **Cache tip:** after editing the card file, HA serves the old cached copy.
> Bump the resource URL (`/local/clockwise-card.js?v=2`, then `?v=3`…) and do a
> hard refresh (`Ctrl+Shift+R`).

---

## Notes

- The card is self-contained (no HACS needed) and updates live as the clock
  publishes — the time stays in sync with the physical display.
- Everything degrades gracefully: if the broker is down, the clock keeps running
  its last settings; the HA device just shows unavailable until it's back.
- The raw 32 energy gates and per-gate thresholds are **not** exposed to HA on
  purpose (they'd be noisy) — tune those in the app. HA gets the useful signals.
