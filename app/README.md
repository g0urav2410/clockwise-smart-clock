# Clockwise App

Flutter (Android) app for Clockwise — the smart-clock controller for the
Ajanta OLC-501 wall clock.

It talks to the clock over its **local HTTP/JSON API** on your WiFi — no MQTT
broker, no cloud, no browser. MQTT/Home Assistant is still supported, but it's
now an optional extra the clock handles itself, not something the app needs.

> **Status:** confirmed working end-to-end against the real clock hardware —
> discovery, connect, live polling, config writes, commands and in-app OTA are
> all verified on a real phone. WiFi setup is done through the clock's own
> browser portal, not the app.

## Setup on a new PC

1. Install Flutter SDK: https://docs.flutter.dev/get-started/install
2. Install Android Studio (for the Android SDK + a device/emulator)
3. In this folder:

```
flutter pub get
flutter run
```

## Build APK

```
flutter build apk --release
```
APK lands at `build/app/outputs/flutter-apk/app-release.apk`

## How it's laid out

Two tabs and a settings gear — deliberately minimal.

- **Home** — device name, online state, brightness, presence, WiFi signal,
  uptime, MQTT state, last NTP sync + "sync now". Polls `/api/state` every 4s
  while foregrounded, and stops when the app is backgrounded.
- **Automations** — a master toggle. ON shows the day/night brightness
  schedule (levels, times, fade duration, "preview night mode"); OFF replaces
  it with a plain manual brightness slider. Never both at once.
- **Settings** (gear, top right)
  - **Appearance** — theme: System / Light / AMOLED dark
  - **Device** — name, address, IP, firmware, chip ID, last sync; rename,
    sync, reboot, and in-app OTA
  - **Advanced** — address + App PIN, and the optional MQTT / Home Assistant
    broker settings (written to the clock, which connects on its own)
  - **My clocks** — device switcher, add/remove

Connection state is always explicit on Home (searching / PIN required /
unreachable, tap to retry) rather than silently showing stale values.

## Adding a clock

**Already on your WiFi:** Settings → My clocks → Add, or the "Add a clock"
button on an empty Home. The app finds it by mDNS (`clockwise-<chipid>.local`),
and falls back to sweeping the phone's /24 for anything answering `/api/info`
— Android's mDNS is unreliable on some ROMs, so the sweep is the safety net.
You can also just type the IP.

**Brand-new clock (no saved WiFi):** it opens its own network,
`Clockwise-Setup`, with a built-in browser setup page — the app is not involved
in first-time WiFi setup.
1. Join `Clockwise-Setup` from your phone's WiFi settings.
2. A setup page opens automatically (or browse to any site). Pick your WiFi,
   and optionally set an App PIN there — the PIN can *only* be set here.
3. Once the clock is on your network, come back to the app and scan to add it.

## App PIN

If the clock has a PIN set (`cfg.apiToken`), the app sends it as the
`X-Auth-Token` header on every API call, and as HTTP Basic auth (`admin` +
PIN) for OTA. With no PIN the API is open to anyone on the same WiFi.

## OTA firmware update (in-app, no browser)

**Settings → Device → Choose firmware file (.bin)**, confirm, and the app
uploads it to `http://<clock>/update`. The clock reboots into the new build.

## Toolchain notes

- `android/settings.gradle.kts` pins **AGP 8.7.3 / Kotlin 2.2.0** and
  `android/app/build.gradle.kts` sets `compileSdk = 35`. These are pinned on
  purpose: the newest auto-generated AGP 9 / Kotlin 2.3 combo breaks plugins
  that still self-apply the Kotlin Gradle plugin. Don't bump them without
  re-testing a full build.
- Uses `file_selector` (Flutter-team maintained) rather than `file_picker` —
  the latter hadn't kept up with the Kotlin toolchain and wouldn't build.
- `res/xml/network_security_config.xml` permits cleartext HTTP. The clock
  speaks plain HTTP on the LAN and Android blocks that by default since API
  28, which would break every API call. A `domain-config` can't express "any
  private IP" (no CIDR support), hence app-wide.
- Builds emit yellow warnings that plugins would prefer `compileSdk = 36`.
  Harmless; the app builds and runs on 35.

## Testing without hardware

`/api/*` can be mocked with a small HTTP server returning the same JSON as
`firmware/src/main.cpp`. Run it on a PC on the same WiFi and add that PC's
IP as a device — discovery, polling, config writes and commands then exercise
the real code paths. This is how the current build was verified.

## Project structure

```
lib/
  main.dart                      — entry, theme mode, providers, 2-tab shell
  services/
    clock_api.dart               — typed wrapper over the clock's /api/* endpoints
    clock_controller.dart        — selected device, live state, polling, writes
    device_store.dart            — saved devices (keyed by chipId) in SharedPreferences
    discovery_service.dart       — mDNS scan + /24 subnet sweep fallback
  theme/
    app_theme.dart               — glassmorphism light + AMOLED dark themes
  screens/
    home_screen.dart             — status, brightness, presence, sync, connection banner
    automations_screen.dart      — day/night schedule vs manual brightness
    settings_screen.dart         — Appearance / Device / Advanced / My clocks + OTA
    add_device_screen.dart       — scan for clocks on WiFi, or add by address
  widgets/
    clock_card.dart              — shared GlassCard, StatChip, OnlinePill, GradientBar
```

## Local API used

| Endpoint | Method | Purpose |
|---|---|---|
| `/api/info`   | GET  | name, fw, ip, chipId, authRequired (no PIN needed) |
| `/api/state`  | GET  | brightness, presence, lastSync, rssi, uptime, mqttConnected |
| `/api/config` | GET  | persisted config (brightness schedule + MQTT broker) |
| `/api/config` | POST | partial config update |
| `/api/name`   | POST | rename the device |
| `/api/cmd`    | POST | `sync` / `reboot` |
| `/update`     | POST | OTA firmware upload (multipart) |

## Dependencies

- `provider` — state management
- `http` — the local API and multipart OTA upload
- `shared_preferences` — saved devices, selected device, theme, automations toggle
- `multicast_dns` — mDNS discovery of `clockwise-<chipid>.local`
- `network_info_plus` — current WiFi IP, for the subnet-sweep discovery fallback
- `file_selector` — pick the OTA `.bin` file
