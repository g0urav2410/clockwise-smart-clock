# Clockwise — manual

An Ajanta OLC-501 wall clock with the original controller replaced by a Wemos D1
Mini (ESP8266). It keeps time from an SD3078 RTC, corrects itself from NTP,
dims itself, and is controlled from an Android app over plain HTTP on your own
WiFi — no cloud, no account, no broker required.

- [Hardware](#hardware)
- [How brightness works](#how-brightness-works)
- [Brightness curves](#brightness-curves)
- [PWM frequency and flicker](#pwm-frequency-and-flicker)
- [Brightness modes](#brightness-modes)
- [Sun mode](#sun-mode)
- [Time and the RTC](#time-and-the-rtc)
- [HTTP API](#http-api)
- [Config reference](#config-reference)
- [Serial commands](#serial-commands)
- [Updating firmware](#updating-firmware)
- [Location and timezone](#location-and-timezone)
- [Resetting the clock](#resetting-the-clock)
- [Troubleshooting](#troubleshooting)

---

## Hardware

| Part | Detail |
|---|---|
| Display | Ajanta OLC-501, 112 LED segments via shift registers, constant-current drivers |
| Controller | Wemos D1 Mini (ESP8266) |
| RTC | SD3078 over I²C at address `0x32` |
| Presence | HLK-LD2402 24GHz mmWave radar, on the ESP's hardware UART — engineering mode, full data. Driver: the standalone [LD2402](https://github.com/g0urav2410/LD2402) library |

### Pins

| Signal | GPIO | Notes |
|---|---|---|
| `PIN_SDI` | 13 | shift register data |
| `PIN_CLK` | 12 | shift register clock |
| `PIN_LE` | 5 | latch enable |
| `PIN_OE` | 14 | output enable — **active low**, PWM'd for brightness |
| `PIN_SDA` | 0 | I²C to RTC |
| `PIN_SCL` | 2 | I²C to RTC |
| `PIN_BUTTON` | 4 (D2) | reset button — see below |
| UART RX/TX | 3 / 1 | HLK-LD2402 radar (TX→RX, RX→TX), 115200 8N1 |

**The UART is the radar's alone — there is no serial command console.** The
sensor's binary data would otherwise be misread as console commands (it blanked
the display). USB *flashing* still works normally.

Brightness is **only** ever changed by PWM on `PIN_OE`. Because OE is active
low, the firmware writes `1023 - duty`: a larger duty means a brighter display.

The button wires between **D2 and GND**, the ordinary way: the internal
pull-up holds it HIGH when idle and pressing pulls it LOW. No external resistor.

D2 is one of the five ESP8266 pins with no boot-time role (the mmWave sensor is
on the hardware UART, not D2). The button was previously on D0, which
sits in the RTC domain, can read HIGH around reset, and has a pull-**down** that
only exists under `INPUT_PULLDOWN_16` — plain `INPUT` left it floating, and
floating noise here reads as a reset. **D0 is now spare.**

---

## How brightness works

Three numbers are involved, and confusing them causes most of the head-scratching:

- **Percent (0–100)** — what you set in the app, what the API speaks, what gets
  stored in config.
- **Duty (0–1023)** — the actual PWM value on the pin. This is what the LEDs
  respond to.
- **The curve** — how percent maps onto duty. This is where the interesting
  behaviour lives.

The mapping is deliberately *not* a straight line, because your eye isn't
linear. Going from duty 10 to 20 doubles the light and is obvious; going from
500 to 510 is invisible. A good curve makes each 1% step *look* like the same
size change.

Transitions between levels are faded in **duty** space, not percent, and
throttled to ~50 Hz. Fading in percent was too coarse at the dim end — 2% to 1%
is only two steps to move through, which is a jump with extra ceremony. In duty
those same levels are ten steps apart.

---

## Brightness curves

Set in the app under **Settings → Advanced → Display tuning**. Four options
(`gamma`: 100 Linear, 180 Standard, 220 Strong, 0 Even):

### Duty produced at each slider percent

| pct | Linear | Standard | Strong | Even |
|---|---|---|---|---|
| 1 | 10 | 1 | 1 | 1 |
| 2 | 20 | 1 | 1 | 2 |
| 3 | 31 | 2 | 1 | 3 |
| 4 | 41 | 3 | 1 | 5 |
| 5 | 51 | 5 | 1 | 6 |
| 10 | 102 | 16 | 6 | 12 |
| 20 | 205 | 56 | 30 | 31 |
| 30 | 307 | 117 | 72 | 64 |
| 50 | 512 | 294 | 223 | 188 |
| 75 | 767 | 610 | 543 | 494 |
| 100 | 1023 | 1023 | 1023 | 1023 |

### Distinct levels — how many slider positions actually change anything

| Range | Linear | Standard | Strong | Even |
|---|---|---|---|---|
| 1–5% | 5/5 | 4/5 | **1/5** | 5/5 |
| 1–10% | 10/10 | 9/10 | 6/10 | 10/10 |
| 1–20% | 20/20 | 19/20 | 16/20 | 20/20 |
| 1–100% | 100/100 | 99/100 | 96/100 | 100/100 |

### What each one is

**Linear** (`gamma: 100`) — duty tracks percent directly. Every position is
distinct, but the step *sizes* are wrong: 1%→2% doubles the light while
99%→100% is imperceptible. This is what makes the dim end feel steppy.

**Standard** (`gamma: 180`) — a power curve. Evens the steps out, costs one
level at the very bottom.

**Strong** (`gamma: 220`) — a stronger power curve. It collapses **1–5% onto a
single duty value**. It appears smooth down there only because nothing is
changing — four of those five slider positions do nothing at all.

**Even** (`gamma: 0`) — the CIE 1931 lightness curve, which is what human
brightness perception actually follows. The only option that keeps every percent
a distinct level *and* keeps the steps perceptually even. Lands exactly on duty
1 at 1% and duty 1023 at 100%, so nothing falls off either end.

**Recommended: Even.** It is what Strong is trying to be, without the dead zone.

### The floor nobody can beat

All four curves share the same worst-case jump: **2×**, at the very bottom,
where the only step available is duty 1 → duty 2. That is a hardware limit of
10-bit PWM, not a curve problem. `dutyFloor` (default 1) sets the lowest
non-zero duty; raise it if very short pulses shimmer.

---

## PWM frequency and flicker

`oeFreq` sets the PWM frequency (100–40000 Hz, default 1000).

**Higher is not better.** Higher frequency means shorter pulses, and the
ESP8266's PWM is generated in software — WiFi interrupts jitter the timing by
roughly a microsecond. When a pulse is only a couple of microseconds long, a
microsecond of jitter is a large fraction of it, and you see flicker.

Pulse width at 1 kHz:

| pct | Linear | Standard | Strong | Even |
|---|---|---|---|---|
| 1% | 9.8 µs | 1.0 µs | 1.0 µs | 1.0 µs |
| 2% | 19.6 µs | 1.0 µs | 1.0 µs | 2.0 µs |
| 5% | 49.9 µs | 4.9 µs | 1.0 µs | 5.9 µs |
| 10% | 99.7 µs | 15.6 µs | 5.9 µs | 11.7 µs |

Any curve other than Linear sits near 1 µs at the dim end.

**The flicker had a root cause, and it is fixed.** ESP8266 modem sleep suspends
and wakes the radio periodically, and every wake is a burst of interrupts — the
jitter that stretches short pulses. It used to flicker visibly at 10–20 kHz.
With `WIFI_NONE_SLEEP` set, 20 kHz on the Even curve at 2% brightness stayed
steady through 3,779 requests in two minutes (~31/sec), which is the worst case
in every dimension at once: shortest pulses, highest frequency, heaviest radio
traffic.

So the old "keep it at 1 kHz" rule no longer applies. The default remains 1000
because it has the most margin and nothing needs more, but 20 kHz is a tested,
supported choice.

If the dim end ever shimmers again, in order of preference:

1. Check `WIFI_NONE_SLEEP` is still being set after WiFi connects — this was the
   original cause
2. Drop `oeFreq` to 1000, then 500 — doubles every pulse width
3. Raise `dutyFloor` to 3 — never produce a pulse shorter than ~3 µs
4. Use the Linear curve — much longer pulses, at the cost of steppiness

---

## Brightness modes

Set in the app under **Automations**. Exactly one is active at a time, and
**each mode remembers its own levels** — changing brightness in one does not
affect the others.

| Mode | `mode` | Stores | Behaviour |
|---|---|---|---|
| Manual | 0 | `manual` | Stays where you put it. Restored on boot. |
| Schedule | 1 | `full`, `night` | Two levels by clock time, with a timed ramp between. |
| Sun | 2 | `sunFull`, `sunNight` | Follows the real sun for your location. |

**Schedule** uses `nightStart`/`nightEnd` (whole hours, wraps past midnight) and
`transition` minutes to ramp rather than switch.

All automatic changes run from the RTC on the device itself. **No WiFi, phone,
or broker is needed** — if the network is down the clock still dims correctly.

---

## Sun mode

Brightness follows the sun's height for your location, computed on the ESP from
its own RTC date/time plus the configured latitude and longitude. There is no
external data source and no network dependency; it is pure astronomy, the same
NOAA approximation used everywhere.

The curve is scaled to **each day's own peak** rather than a fixed angle:

```
t = (sin(elevation) - sin(twilight floor)) / (sin(peak today) - sin(twilight floor))
brightness = sunNight + (sunFull - sunNight) * t
```

Scaling to the day's own peak matters because the sun's maximum height changes
with latitude and season. An earlier version ramped between two fixed angles,
which meant brightness sat pinned at maximum for about ten hours a day in summer
and under five in winter. Scaling to the peak is self-adjusting and needs no
tuning. `sunHigh` is what used to set that ceiling; it is still stored but
nothing reads it.

Subtracting the twilight floor matters too, and its absence was a real bug: the
formula used to be `sin(elevation) / sin(peak)`, and sine of a *negative*
elevation is negative, so everything after sunset clamped to zero. Brightness
dropped to the night level the instant the sun crossed the horizon and the dusk
setting could never do anything.

### Twilight

Two settings, one for each end of the day, because the sun is symmetric but the
use of a clock isn't — you are awake in the evening and asleep before dawn.

| Setting | Range | Effect |
|---|---|---|
| `sunDawn` | −24° to +20° | Positive waits until the sun is properly up before brightening; negative starts before sunrise |
| `sunDusk` | −24° to +20° | Negative keeps light after sunset |

Stored as angles rather than minutes because angles are the real definition of
twilight and behave sensibly at any latitude — "30 minutes after sunset" stops
meaning anything far north, where in summer the sun barely sets. The app shows
the resulting offset in minutes, so you never have to think in degrees.

The cost is a small seasonal drift: measured at 33°N, an angle worth 32 minutes
in July gives 28–33 across the year. That's under a minute of change per three
weeks.

Roughly, at 33°N: −6° ≈ 32 min, −12° ≈ 66 min, −24° ≈ 143 min, +10° ≈ 51 min
after sunrise, +20° ≈ 101 min.

### The day curve

The app draws the whole day as a filled curve — height is brightness, daylight
warm and night cool, with sunrise, peak, sunset and daylight length underneath at
one-minute resolution. It replaced a row of shaded blocks, which couldn't show
the middle hours differing because the eye can't rank opacity that finely.

The day's sun positions are computed once and cached, so the twilight sliders can
show the time an angle produces on every frame of a drag.

### Testing sun mode without waiting for dusk

`firmware/tools_fake_sun.py` shifts the clock's longitude to fake a
different sun position, leaving the RTC untouched:

```
py tools_fake_sun.py --host 192.168.0.50 25        aim sun mode at 25%
py tools_fake_sun.py --host 192.168.0.50 restore   put the real longitude back
```

While faking, the app's day strip will disagree with reality — it is drawn from
the same fake longitude. Always restore when finished.

---

## Time and the RTC

The SD3078 runs in **12-hour mode**. The hour register packs flags into its top
bits, so a raw dump does not read as a decimal hour:

```
0x27  =  0 0 1 0 0 1 1 1
         │ │ │ └───────┘
         │ │ │     └── BCD hour = 7
         │ │ └──────── bit5 = 1 → PM
         │ └────────── bit6 unused
         └──────────── bit7 = 0 → 12-hour mode
```

`0x27` is therefore **7 PM**, not hour 27. The other registers (minutes, date,
month, year) have no flag bits, so their hex digits read as decimal.

Internally the firmware passes 24-hour integers and the API reports 24-hour
strings — both are just unambiguous formats. The display itself shows 12-hour.

**NTP** runs at boot, on demand from the app, and daily at 03:00 if `autoSync`
is on. It only writes the RTC when drift exceeds **2 seconds**, so repeated
syncs do not wear the chip.

Leading zeros are deliberately blanked: on the hour both minute digits go dark,
and `:01`–`:09` drops the tens digit. This is a design choice, not a fault.

---

## HTTP API

Plain HTTP on port 80. If an API token is set, requests need Basic auth.

| Method | Path | Purpose |
|---|---|---|
| GET | `/api/info` | name, firmware version, IP, chip ID, whether auth is required |
| GET | `/api/state` | live values — see below |
| GET | `/api/config` | all persisted settings |
| POST | `/api/config` | patch any subset of settings; **saves to flash** |
| POST | `/api/name` | rename the clock |
| POST | `/api/brightness` | `{"v": 0-100}` — live preview, **not** persisted |
| POST | `/api/cmd` | `{"cmd": "sync"}` or `{"cmd": "reboot"}` |
| POST | `/update` | OTA firmware upload |

`/api/state` returns:

```json
{"time":"19:24:13","date":"2026-07-18","dow":6,"rtcOk":true,
 "sunElev":17.83,"sunPct":15,"brightness":15,"presence":false,
 "lastSync":"2026-07-18 19:21:51 Sat","rssi":-65,"uptime":90,
 "mqttConnected":false}
```

`/api/brightness` sets the light immediately without saving, and holds off the
scheduler for a few seconds so a preview isn't instantly overwritten. Use it for
slider drags; persist the final value with `/api/config`.

**The server handles one connection at a time.** Clients should serialise
requests rather than firing them in parallel.

---

## Config reference

Every key below is readable from `GET /api/config` and settable by posting a
subset to `POST /api/config`.

| Key | Default | Meaning |
|---|---|---|
| `name` | `Clockwise` | display name |
| `mode` | 0 | 0 manual · 1 schedule · 2 sun |
| `manual` | 100 | Manual mode's level |
| `full` | 100 | Schedule daytime level |
| `night` | 0 | Schedule night level |
| `nightStart` | 23 | night begins, whole hour |
| `nightEnd` | 6 | night ends, whole hour |
| `transition` | 30 | ramp length in minutes |
| `sunFull` | 100 | Sun mode midday level |
| `sunNight` | 0 | Sun mode night level |
| `lat` / `lon` | 20.59 / 78.96 | location for sun maths |
| `tz` | `IST-5:30` | POSIX TZ rule, set from Settings → Device → Location & timezone. Carries the region's DST rule, which newlib applies on every NTP resync — set once, correct forever |
| `sunDawn` | −6 | morning twilight floor, −24 to +20 |
| `sunDusk` | −6 | evening twilight floor, −24 to +20 |
| `sunLow` | −6 | legacy alias — reads as both, served as `sunDusk` |
| `sunHigh` | 25 | legacy, nothing reads it |
| `fade` | 1500 | fade duration in ms |
| `gamma` | 100 | 0 = Even (CIE) · 100–300 = power curve |
| `dutyFloor` | 1 | lowest non-zero PWM duty |
| `oeFreq` | 1000 | PWM frequency in Hz |
| `logo` | true | logo LED |
| `autoSync` | true | daily 03:00 NTP check |
| `timeout` | 300 | presence timeout, seconds |
| `mqttHost` / `mqttPort` / `mqttUser` | — | optional broker |

`sched` is a legacy boolean kept for older MQTT clients. Sending it alone forces
Manual or Schedule; sending `mode` in the same payload takes precedence.

---

## Serial console — behind a toggle

The hardware UART is normally the HLK-LD2402 radar's; the sensor's binary data
would be misread as commands (it blanked the display), so the serial console is
**off by default**. Everything the old console did is now done through the app /
`/api/*` and OTA.

If you do need the console (bench work, a repair), there's a persisted toggle —
**Settings → Presence sensor → USB serial debug** (`serialDebug` in
`/api/config`). How it behaves, simply:

- **Off (default):** UART is the sensor's; no console.
- **On + sensor still plugged in:** the sensor keeps working; the console stays
  **asleep**. Flipping the toggle can't break anything.
- **On + sensor unplugged:** ~2 s after the stream stops, the console **wakes
  up** — the same command set listed in
  [firmware/SERIAL_COMMANDS.md](firmware/SERIAL_COMMANDS.md).

USB *flashing* works regardless of the toggle. Turn it off to return to normal.

## Presence sensor (HLK-LD2402)

On the hardware UART, engineering mode — full data. Controlled from
**Settings → Presence sensor** in the app, over these endpoints:

| Endpoint | Purpose |
|---|---|
| `GET /api/sensor` | live: presence, moving/still, distance, 32 energy gates (16 motion + 16 micro) |
| `GET /api/sensor/config` | firmware, max distance, disappearance delay, power-interference status |
| `POST /api/sensor/config` | set max distance / delay / mode / thresholds (`save:true` also commits to the sensor's flash) |
| `GET /api/sensor/thresholds` | all 16 motion + 16 micro per-gate thresholds |
| `POST /api/sensor/calibrate` | auto-generate thresholds for the room |
| `POST /api/sensor/autogain` | correct a saturated front-end |

Gates are ~0.7 m distance slices, gate 0 nearest. Each has a motion threshold
(moving targets) and a micro threshold (still / breathing). Presence-based
auto-dim ("dim when empty") is on the same screen. See the standalone
[LD2402](https://github.com/g0urav2410/LD2402) library for the protocol.

---

## Updating firmware

Over the air, no cable:

```
cd firmware_pio
pio run
curl -F "firmware=@.pio/build/d1_mini/firmware.bin" http://<clock-ip>/update
```

It reboots itself and comes back in about 15 seconds. If a PIN is set, add
`-u admin:<pin>`. An interrupted upload leaves the old firmware intact.

---

## Location and timezone

One setting, in **Settings → Device → Location & timezone**, because the two
have to agree: the timezone decides what time is displayed, the coordinates
decide when the sun rises and sets for sun mode. It sits next to the NTP sync
row rather than under sun mode, since it governs the clock's core job.

Three ways it gets set, in order of accuracy:

1. **Use my location** — GPS. Exact coordinates and the phone's own zone.
2. **Search** — 15,088 cities and states worldwide. A city is exact; a state
   is its population-weighted centre, up to ~100km out, which moves sunrise
   about four minutes. Invisible in a half-hour brightness ramp.
3. **Nothing** — a brand-new clock picks it up from the browser during WiFi
   setup, so it is correct out of the box anywhere in the world.

### Daylight saving

Handled entirely by the clock. The stored `tz` is a POSIX rule such as
`EST5EDT,M3.2.0,M11.1.0`, which carries the region's whole DST rule; newlib
re-resolves it against the current date on every NTP sync. Set the place once
and the nightly 03:00 sync keeps it right through every future transition,
forever, with the app never involved again.

India has no daylight saving, so `IST-5:30` never changes.

### The drift warning on Home

Compares what the clock's RTC reports against universal time plus the clock's
*own* timezone offset — not against the phone's clock. A clock deliberately
set to London is meant to read 4h30 behind an Indian phone; that is not drift.

The warning means the RTC has genuinely wandered, which points at the nightly
NTP sync failing: auto-sync switched off, NTP blocked on the network, or a
failing RTC backup battery. "Sync now" in Settings → Device forces a fetch.

The offset comes from the clock itself: `/api/state` reports `tzOff`, the
device's current offset with daylight saving already applied. So this works on
a fresh app install, or a second phone, with nothing configured — the app no
longer needs its own record of where the clock is.

It stays silent only against firmware too old to report `tzOff` on a phone that
also has no saved zone for the clock. With neither, the app would be comparing
against *its own* timezone, which is exactly the false alarm above.

---

## Resetting the clock

Two physical controls, both requiring the case to be open (or extended out of
it):

- **RST button** (built into the D1 Mini) — plain reboot, same as power-cycling.
- **Reset button on D2** — hold it and the display stops showing the time and
  starts counting, telling you what letting go would do:

  | Display | Let go here |
  |---|---|
  | `1`, `2` | Nothing happens |
  | `3 rE` … `7 rE`, with `Con` on the year digits | **WiFi reset.** Clears the saved network and reboots into the `Clockwise-Setup` portal, same as first-time setup |
  | `8 Fr`, with `CLr` on the year digits | **Factory reset.** Also wipes every setting (brightness, schedule, sun location, PIN) back to defaults |
  | `15 no` | Nothing — cancelled |

  The rest of the display goes dark while you hold it, so there's no chance of
  misreading the time as the count. The reset fires on release, and the time
  comes straight back if you release below `3`.

  **Changed your mind?** Keep holding. At 15 seconds the display reads `no` and
  releasing does nothing at all. This is also why a button jammed by the case
  or a mounting screw can't quietly factory-reset the clock — it sails past 8,
  reaches `no`, and stops there.

Plain reboot is also available from the app or `/api/cmd` (see
[HTTP API](#http-api)) without touching the clock. WiFi reset and factory
reset are physical-button-only for now — there's no app/API equivalent yet.

---

## Troubleshooting

**The clock shows `no` and `Con` where the date and year go.** It has lost
WiFi. The notice alternates with the real date and year every 5 seconds, and
clears itself the moment the network is back. The timing is adjustable over
serial with `a <on> <off>` (seconds, saved to flash); `a 0 0` switches the
notice off altogether. The time is unaffected — the RTC keeps
running perfectly without a network, so nothing is wrong with the clock itself;
it just can't reach NTP to check itself against, or be controlled from the app.

**The app says it can't reach the clock.** Check `uptime` in `/api/state` — if
it keeps climbing, the clock never rebooted and it is a network problem.
ESP8266 modem sleep was the cause of long unreachable periods; `WIFI_NONE_SLEEP`
fixes it.

**The display flickers.** Lower `oeFreq` (try 1000, then 500). Flicker comes
from short PWM pulses plus interrupt jitter, and higher frequencies make it
worse, not better.

**The dim end has visible steps.** Use the Even curve. If it still steps at
1–2%, that is the duty 1 → 2 hardware floor.

**Brightness changed by itself.** Check which mode is active. Schedule and Sun
both move brightness on their own, from the RTC, with no network involved.

**The display looks brighter as the room gets darker.** There is no light
sensor; output is constant while your eyes adapt.

**Sun mode seems wrong.** Look at the day curve. If it is flat, the midday and
night levels are too close together. If the shape looks right but the timing
doesn't, check the twilight settings — they move each end independently.

**Times are wrong.** Check Settings → Device → Location & timezone. That one
setting carries both the timezone and the sun position, and the clock applies
that region's daylight saving itself from then on, so setting it once fixes it
for good. If the clock is deliberately set somewhere else, it is *supposed* to
show that place's time.

**Forgot the WiFi password / need to switch networks.** Use the D2 reset
button — hold until the 3rd flash, then let go. See
[Resetting the clock](#resetting-the-clock).

---

For hardware internals and how the display was reverse-engineered, see
[hardware/](hardware/).
