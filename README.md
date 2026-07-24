# Clockwise

**A smart-clock brain for a 7-segment wall clock.** Clockwise replaces the guts
of a cheap wall clock with a Wemos **D1 Mini (ESP8266)**, turning a dumb display
into a network clock with automatic time, adaptive brightness, presence sensing,
a phone app, and full Home Assistant integration — all running **locally**, no
cloud.

Built and proven on the **Ajanta Quartz OLC-501**, and a clean reference for any
ESP 7-segment clock. Support for more boards is planned.

> ### ⚡ [Flash it from your browser →](https://g0urav2410.github.io/clockwise-smart-clock/)
> No toolchain needed — plug in a D1 Mini and flash from Chrome/Edge. The same
> site hosts the full docs.

---

## Features

- 🕐 **Always-right time** — WiFi + NTP, with an **SD3078 RTC** keeping time
  through power cuts. Location-aware, handles daylight saving itself.
- 🔆 **Adaptive brightness** — three modes: **Manual**, **Schedule** (day/night),
  and **Sun** (ramps with real sunrise/sunset for your location).
- 👋 **Presence sensing** — an **HLK-LD2402 24 GHz mmWave radar** reports
  presence, motion vs. still, and distance. Optional **dim-when-empty**.
- 📶 **Easy setup** — first boot opens a **captive-portal** WiFi setup page (scan,
  pick network, set an optional PIN, timezone auto-detected in the browser).
- 📱 **Companion app** — a Flutter app (Android) with a native clock-face
  widget (matches the HA card pixel-for-pixel), full control, and sensor tuning.
- 🏠 **Home Assistant** — MQTT **auto-discovery** builds the whole device; plus an
  optional custom **Lovelace card** that recreates the 7-segment face live.
- 🩺 **Device health & debug tools** — free memory/loop-rate/reset-cause in the
  app, an optional scheduled restart, and a small event log + debug console
  over WiFi (no USB cable needed).
- 🔒 **Secured** — PIN-protected HTTP API, authenticated **OTA** updates.
- 💡 Logo LED, physical reset button (WiFi reset / factory reset), and more.

---

## How it works

The original clock is a 7-segment LED display driven by shift-register LED
drivers. Clockwise drives those drivers directly from the D1 Mini (serial data +
latch) and controls overall brightness with a PWM signal on the drivers'
output-enable (OE) pin. An SD3078 RTC on I²C keeps time; the mmWave radar sits on
the hardware UART. Everything — scheduling, sun math, the web API, MQTT — runs on
the ESP8266 itself, so the clock keeps working even if your network or Home
Assistant is down.

See [`hardware/`](hardware/) for the reverse-engineering notes and segment map.

---

## Repository layout

| Folder | What's inside |
|---|---|
| [`firmware/`](firmware/) | The ESP8266 firmware (PlatformIO). This is what runs on the clock. |
| [`app/`](app/) | The Flutter companion app. |
| [`homeassistant/`](homeassistant/) | The custom Lovelace card + a Home Assistant setup guide. |
| [`hardware/`](hardware/) | Display reverse-engineering notes and the segment map. |
| [`MANUAL.md`](MANUAL.md) | End-user manual (setup, everyday use, troubleshooting). |

The mmWave driver is its own reusable library:
**[LD2402](https://github.com/g0urav2410/LD2402)**.

---

## Hardware

**Core parts**

- Ajanta Quartz **OLC-501** clock (the donor display)
- **Wemos D1 Mini** (ESP8266)
- **SD3078** RTC module (I²C)
- **HLK-LD2402** 24 GHz mmWave presence sensor (optional)
- A 5 V supply; the D1 Mini runs off its onboard regulator (feed 5 V to Vin)

**Pin map** (from [`firmware/src/main.cpp`](firmware/src/main.cpp))

| Signal | D1 Mini pin | GPIO |
|---|---|---|
| LED driver data (SDI) | D7 | 13 |
| LED driver clock (CLK) | D6 | 12 |
| LED driver latch (LE) | D1 | 5 |
| LED driver brightness (OE, PWM) | D5 | 14 |
| RTC I²C data (SDA) | D3 | 0 |
| RTC I²C clock (SCL) | D4 | 2 |
| Reset button (hold to reset WiFi/factory) | D2 | 4 |
| mmWave radar | hardware UART | TX/RX (1/3) |

---

## Build & flash the firmware

Uses [PlatformIO](https://platformio.org/).

```bash
cd firmware
pio run                 # build
pio run -t upload       # flash over USB
```

After the first flash, connect to the **`Clockwise-Setup`** WiFi network the clock
broadcasts and follow the setup page to join your WiFi and set an optional PIN.

Later updates can go over the air (OTA) instead of USB — see the manual.

---

## The app

An Android app built with [Flutter](https://flutter.dev/).

> **[⬇ Download the latest APK](https://github.com/g0urav2410/clockwise-smart-clock/releases/tag/app-v1.0.0)**
> — or build it yourself:

```bash
cd app
flutter pub get
flutter build apk --release      # output in build/app/outputs/flutter-apk/
```

It auto-discovers the clock on your network. Full control lives here: brightness
modes, location/timezone, the presence sensor and its per-gate tuning, MQTT, and
display tuning.

---

## Home Assistant

The clock speaks MQTT with **auto-discovery**, so Home Assistant builds the whole
device by itself — no YAML. There's also an optional custom card that recreates
the 7-segment face with live controls.

Full instructions: [`homeassistant/README.md`](homeassistant/README.md).

---

## Roadmap

What's next, roughly in order:

- [ ] **LDR light sensor** — a full ambient-light brightness mode, plus a
  "don't dim below this floor" option for Sun mode.
- [ ] **Real photos** — the finished clock, the opened case/wiring, and a short
  demo video/GIF.
- [ ] **A wiring diagram** — a visual version of the pin map above.
- [ ] **A step-by-step build guide** — turning the raw
  [reverse-engineering log](hardware/REVERSE_ENGINEERING.md) into an actual
  "do this yourself" walkthrough, backed by the photos above.
- [ ] **A bill of materials** — one clear parts list with sourcing.
- [ ] **App & Home Assistant card screenshots** in their respective guides.
- [ ] **A CHANGELOG** tracking what shipped in each [release](https://github.com/g0urav2410/clockwise-smart-clock/releases).
- [ ] **Support for other boards / reduced-feature builds** (e.g. no radar) —
  the clock reporting its capabilities so the app adapts automatically.

Have a clock, board, or feature you'd like supported? Open an issue.

---

## License & credits

- Firmware, app, and docs: **GPL v3** — see [LICENSE](LICENSE).
- Timezone/location data from **GeoNames** (geonames.org), licensed CC BY 4.0.
- "Ajanta OLC-501" is used only as a hardware descriptor; not affiliated.
