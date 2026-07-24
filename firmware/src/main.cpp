/*
  Clockwise -- smart controller for the Ajanta OLC-501 (D1 Mini / ESP8266)
  ──────────────────────────────────────────────────────
  Renders time + date + month + year + day-of-week from the SD3078 RTC using
  the complete segment map. WiFi (custom captive portal), NTP, MQTT (optional), local
  HTTP/JSON API + mDNS, and OTA are all wired in.

  Pins: SDI=D7(13) CLK=D6(12) LE=D1(5) OE=D5(14)  SDA=D3(0) SCL=D4(2)

  Serial (hardware UART0, 115200) is shared between the USB debug console and
  the HLK-LD2402 presence radar's RX/TX -- both can be wired at once. Incoming
  bytes are routed by their leading byte: 'O'/'d' (the radar's own "OFF" /
  "distance : NN" text) or 0xF4 (an engineering binary frame) go to the radar
  parser; everything else -- digits and the letters below -- is a typed debug
  command, exactly as before. The two never collide because no debug command
  starts with 'O', 'd' or a non-ASCII byte. See the full command list printed
  at boot.

  Serial testing tools (all @115200) -- kept for future hardware debugging,
  not just the original bring-up:
    number  = light exactly one of the 112 raw outputs (e.g. "42") -- verify a
              single segment/wire is soldered and mapped correctly
    n / p   = step the "one output" selection forward/backward -- walk the
              whole chain without retyping numbers
    cN      = light chip N's (0-6) even-numbered outputs, ADDING to whatever's
              already lit -- combine chips (x, then c2, c3, c6, ...) to check
              for cross-chip issues like the ghosting bug this was built for
    x       = clear the manual test frame (all outputs dark)
    r       = leave manual test mode, resume the live clock display
    fNNN    = set the OE PWM (brightness) frequency live, 100-40000Hz -- for
              retesting brightness/flicker behavior if the hardware changes
    w       = force a hardcoded known date/time onto the RTC, no WiFi needed --
              quick display sanity check independent of NTP
    t       = print the RTC's decoded date/time (human-readable)
    v       = print the RTC's raw register bytes in hex -- cross-check against
              the SD3078 datasheet directly when something looks wrong
    l       = toggle the once-a-second clock tick log on/off
*/

#include <Arduino.h>
#include <Wire.h>
#include <ESP8266WiFi.h>
#include <DNSServer.h>
#include <time.h>
#include <LittleFS.h>
#include <ArduinoJson.h>
#include <PubSubClient.h>
#include <ESP8266WebServer.h>
#include <ESP8266HTTPUpdateServer.h>
#include <ESP8266mDNS.h>
#include <ESP8266HTTPClient.h>
#include "LD2402.h"

#define FW_VERSION "0.2.0"

// WiFi credentials live in cfg.json now, set by the custom setup portal
// (runSetupPortal). The ESP SDK also keeps its own copy in a separate flash
// area, so an install upgraded from the old WiFiManager build reconnects via
// WiFi.begin() with no args before these are ever populated.

// Brightness modes.
//   MANUAL   -- whatever was last set; the clock never changes it on its own
//   SCHEDULE -- two levels, day and night, with a timed ramp between them
//   SUN      -- follows the actual sun for the configured location
#define MODE_MANUAL   0
#define MODE_SCHEDULE 1
#define MODE_SUN      2

// Default twilight floor, tunable at runtime per end of the day (see
// cfg.sunDawnDeg / cfg.sunDuskDeg). -6 degrees is civil twilight, the point
// where it's meaningfully getting light.
const float SUN_TWILIGHT_DEG = -6.0f;
const float SUN_FULL_DEG     = 25.0f;

// ── persisted config (survives reboot) — MQTT broker + brightness schedule ──
struct Config {
    char mqttHost[64]  = "";
    int  mqttPort      = 1883;
    char mqttUser[32]  = "";
    char mqttPass[32]  = "";
    int  fullPct       = 100;
    int  dimPct        = 10;
    int  nightPct      = 0;
    int  nightStart    = 23;
    int  nightEnd      = 6;
    int  fadeMs        = 1500;
    char deviceName[32] = "Clockwise";
    char apiToken[17]   = "";   // local API PIN -- empty = open until user sets one
    bool schedEnabled  = false; // day/night brightness scheduler (runs off the RTC, no network needed)
    bool autoSync      = true;  // once-a-day NTP check (still skips the write unless drifted)
    // OE PWM frequency. 1kHz, not the old 20kHz: analogWrite on the ESP8266 is
    // software PWM driven by timer interrupts, and WiFi activity delays those
    // by ~a microsecond. That jitter was invisible against the old linear
    // mapping (12% brightness = ~6us pulse at 20kHz) but very visible once the
    // gamma curve shortened low-brightness pulses (12% = ~2.2us at 10kHz) --
    // the display flickered whenever the app was polling. At 1kHz every pulse
    // is 10-20x longer, so the same jitter doesn't show. Still far above the
    // eye's flicker-fusion threshold. Confirmed on hardware: flickers at
    // 10kHz, clean at 1kHz.
    int  oeFreq        = 1000;
    bool logoOn        = true;  // logo LED -- was session-only via the 'g' command
    int  transitionMin = 30;    // minutes spent ramping between day and night levels
    // Linear. A gamma curve was tried to even out the dimming steps, but the
    // difference was not perceptible on this display, and it cost two bugs:
    // it drove 1-3% to fully dark, and it shortened low-brightness pulses
    // until WiFi jitter showed as flicker. Not worth it here.
    int  gammaX100     = 100;   // 0 = CIE lightness curve; 100-300 = power curve
    // Smallest non-zero PWM duty. 1 is the hardware minimum and gives the finest
    // dim steps; raise it if very short pulses shimmer under WiFi interrupt jitter.
    int  dutyFloor     = 1;
    int  mode          = MODE_MANUAL;  // manual / schedule / sun
    // Placeholder only: sun mode needs some lat/lon before one is set, and
    // (0,0) is the Atlantic -- a visibly wrong sun curve. This is 0°N on the
    // prime meridian's more useful neighbour, near London, as a neutral
    // default. Only the APP's location flow (GPS or the city list) ever
    // overwrites it -- the browser WiFi setup portal does NOT; it sends a
    // timezone rule but never coordinates. A clock that's only ever been
    // through the portal is silently still sitting on this placeholder, which
    // makes Sun mode compute sunrise/sunset for London while displaying it in
    // the real timezone -- a large, nonsensical-looking shift. The app warns
    // for exactly this (see LocationWarningBanner) instead of the portal
    // guessing coordinates via unreliable in-portal browser geolocation.
    float lat          = 51.48f;       // near Greenwich -- NOT set by the WiFi portal
    float lon          = 0.0f;
    // Separate twilight floors for dawn and dusk. How far below the horizon the
    // sun may be while the display is still above its night level.
    float sunDawnDeg   = SUN_TWILIGHT_DEG;
    float sunDuskDeg   = SUN_TWILIGHT_DEG;
    float sunHighDeg   = SUN_FULL_DEG;   // unused since the curve scales to the day's peak
    // Sun mode gets its own brightness pair. Sharing fullPct/nightPct with the
    // scheduler meant editing one mode silently edited the other.
    int  sunFullPct    = 100;
    int  sunNightPct   = 0;
    // Manual mode's level, likewise its own. Restored at boot.
    int  manualPct     = 100;
    // POSIX TZ rule string (e.g. "IST-5:30", or "EST5EDT,M3.2.0,M11.1.0" for
    // a DST-observing region), set once from the app's city picker. newlib's
    // configTzTime()/localtime_r() apply the DST rule automatically on every
    // NTP resync from then on -- no ongoing app involvement needed.
    char tzPosix[48] = "IST-5:30";
    // WiFi credentials, set by the setup portal. Empty on a fresh clock, which
    // is what opens the portal. 32-char SSID + null, 63-char WPA2 pass + null.
    char wifiSsid[33] = "";
    char wifiPass[65] = "";
    // True once we've adopted the SDK's own stored credentials (the one-time
    // migration from the WiFiManager build). Without this, a WiFi reset clears
    // cfg but the untouched SDK copy gets re-adopted on the next boot, so the
    // clock rejoins instead of opening the setup portal.
    bool wifiMigrated = false;
    // "no Con" notice while WiFi is down: seconds shown, then seconds of real
    // date/year, alternating. onS = 0 turns the notice off entirely, for anyone
    // who would rather the clock just stayed a clock.
    int  wifiAlertOnS  = 5;
    int  wifiAlertOffS = 5;
    // HLK-LD2402 presence radar, wired to hardware Serial. Only the ESP-side
    // preference lives here -- calibration/thresholds live on the sensor's own
    // flash (set via /api/sensor, saved with its own save command), not
    // duplicated here.
    //
    // Full data by default: presence + distance + all 32 energy gates
    // (motion + micro-motion). The switch into this mode was previously
    // broken by a malformed setOutputMode command (missing the 2-byte command
    // value -- see LD2402::setOutputMode), which is what made engineering mode
    // silence the sensor. With that fixed the switch is clean, so full data is
    // the default the user actually wants. endConfig() also retries now, so a
    // missed exit-config ACK can't leave the sensor stuck/muted.
    bool sensorEngineering = true;   // true = full data (distance + energy gates), false = presence + distance only
    // Presence dimming overlay -- off by default, works on top of any mode.
    // See applyPresenceOverlay().
    bool presenceDimEnabled  = false;
    int  presenceAwayPct     = 0;
    int  presenceTimeoutMin  = 5;
    // The one UART is either the radar's or a USB debug console's -- never both
    // (the sensor's binary bytes get executed as console commands otherwise,
    // which blanked the display). One toggle picks the role:
    //   false (default) -> radar owns Serial: sensor works, no console, quiet TX
    //   true            -> debug console: command parser + logs on, radar paused
    // Use debug mode with the sensor physically unplugged (USB is on the same
    // two pins). Persisted so it stays where you leave it; the app shows which.
    bool serialDebug = false;
    // Optional scheduled restart -- resets heap fragmentation to 0 rather than
    // trying to eliminate it in code (not realistically fixable: any web
    // request handling does some varying-sized temporary allocation). Off by
    // default -- this is an experiment the user opted into, not a default
    // behavior. intervalDays is free-form (the app offers day/week/month
    // presets: 1/7/30) so it can be tuned. lastAutoRebootDayCount anchors the
    // schedule and is persisted so a reboot doesn't forget where it was, and
    // so flipping the toggle on doesn't fire an immediate surprise restart --
    // it's set to "today" whenever the schedule is (re)armed, not left at 0.
    bool autoRebootEnabled       = false;
    uint8_t autoRebootIntervalDays = 7;
    uint8_t autoRebootHour         = 4;   // after the 3am NTP sync, before anyone's usually looking
    long autoRebootAnchorDay       = 0;
} cfg;

const char *CFG_PATH = "/cfg.json";

void loadConfig() {
    if (!LittleFS.begin()) { Serial.println("LittleFS mount failed"); return; }
    File f = LittleFS.open(CFG_PATH, "r");
    if (!f) { Serial.println("No saved config, using defaults"); return; }
    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, f);
    f.close();
    if (err) { Serial.println("Config parse failed, using defaults"); return; }
    strlcpy(cfg.mqttHost, doc["mqttHost"] | "", sizeof(cfg.mqttHost));
    cfg.mqttPort    = doc["mqttPort"]    | 1883;
    strlcpy(cfg.mqttUser, doc["mqttUser"] | "", sizeof(cfg.mqttUser));
    strlcpy(cfg.mqttPass, doc["mqttPass"] | "", sizeof(cfg.mqttPass));
    cfg.fullPct     = doc["full"]        | 100;
    cfg.dimPct      = doc["dim"]         | 10;
    cfg.nightPct    = doc["night"]       | 0;
    cfg.nightStart  = doc["nightStart"]  | 23;
    cfg.nightEnd    = doc["nightEnd"]    | 6;
    cfg.fadeMs      = doc["fade"]        | 1500;
    strlcpy(cfg.deviceName, doc["name"] | "Clockwise", sizeof(cfg.deviceName));
    strlcpy(cfg.apiToken, doc["apiToken"] | "", sizeof(cfg.apiToken));
    cfg.schedEnabled = doc["sched"]    | false;
    cfg.autoSync     = doc["autoSync"] | true;
    cfg.oeFreq       = doc["oeFreq"]   | 1000;
    cfg.logoOn       = doc["logo"]     | true;
    cfg.transitionMin = doc["transition"] | 30;
    cfg.gammaX100     = doc["gamma"]     | 100;
    cfg.dutyFloor     = doc["dutyFloor"] | 1;
    // Migrate the old boolean: a saved sched=true means schedule mode.
    cfg.mode = doc["mode"] | (cfg.schedEnabled ? MODE_SCHEDULE : MODE_MANUAL);
    cfg.lat  = doc["lat"] | 51.48f;
    cfg.lon  = doc["lon"] | 0.0f;
    // Migration: configs written before dawn and dusk were separate carry the
    // single sunLow forward into both, so an existing clock behaves identically.
    const float legacyLow = doc["sunLow"] | SUN_TWILIGHT_DEG;
    cfg.sunDawnDeg = doc["sunDawn"] | legacyLow;
    cfg.sunDuskDeg = doc["sunDusk"] | legacyLow;
    cfg.sunHighDeg = doc["sunHigh"] | SUN_FULL_DEG;
    // Migration: configs written before sun mode had its own levels carry the
    // shared pair forward, so an existing clock keeps the brightness it had.
    cfg.sunFullPct  = doc["sunFull"]  | cfg.fullPct;
    cfg.sunNightPct = doc["sunNight"] | cfg.nightPct;
    cfg.manualPct   = doc["manual"]   | cfg.fullPct;
    strlcpy(cfg.tzPosix, doc["tz"] | "IST-5:30", sizeof(cfg.tzPosix));
    cfg.wifiAlertOnS  = doc["wifiAlertOn"]  | 5;
    cfg.wifiAlertOffS = doc["wifiAlertOff"] | 5;
    strlcpy(cfg.wifiSsid, doc["wifiSsid"] | "", sizeof(cfg.wifiSsid));
    strlcpy(cfg.wifiPass, doc["wifiPass"] | "", sizeof(cfg.wifiPass));
    cfg.wifiMigrated = doc["wifiMigrated"] | false;
    cfg.sensorEngineering = doc["sensorEng"] | true;
    cfg.presenceDimEnabled = doc["presenceDim"]     | false;
    cfg.presenceAwayPct    = doc["presenceAway"]    | 0;
    cfg.presenceTimeoutMin = doc["presenceTimeout"] | 5;
    cfg.serialDebug        = doc["serialDebug"]     | false;
    cfg.autoRebootEnabled     = doc["autoReboot"]       | false;
    cfg.autoRebootIntervalDays = doc["autoRebootDays"]  | 7;
    cfg.autoRebootHour        = doc["autoRebootHour"]   | 4;
    cfg.autoRebootAnchorDay   = doc["autoRebootAnchor"] | 0;
}

void saveConfig() {
    JsonDocument doc;
    doc["mqttHost"]   = cfg.mqttHost;
    doc["mqttPort"]   = cfg.mqttPort;
    doc["mqttUser"]   = cfg.mqttUser;
    doc["mqttPass"]   = cfg.mqttPass;
    doc["full"]       = cfg.fullPct;
    doc["dim"]        = cfg.dimPct;
    doc["night"]      = cfg.nightPct;
    doc["nightStart"] = cfg.nightStart;
    doc["nightEnd"]   = cfg.nightEnd;
    doc["fade"]       = cfg.fadeMs;
    doc["name"]       = cfg.deviceName;
    doc["apiToken"]   = cfg.apiToken;
    doc["sched"]      = cfg.schedEnabled;
    doc["autoSync"]   = cfg.autoSync;
    doc["oeFreq"]     = cfg.oeFreq;
    doc["logo"]       = cfg.logoOn;
    doc["transition"] = cfg.transitionMin;
    doc["gamma"]      = cfg.gammaX100;
    doc["dutyFloor"]  = cfg.dutyFloor;
    doc["mode"]       = cfg.mode;
    doc["lat"]        = cfg.lat;
    doc["lon"]        = cfg.lon;
    doc["sunDawn"]    = cfg.sunDawnDeg;
    doc["sunDusk"]    = cfg.sunDuskDeg;
    doc["sunLow"]     = cfg.sunDuskDeg;   // legacy alias, kept so old clients keep working
    doc["sunHigh"]    = cfg.sunHighDeg;
    doc["sunFull"]    = cfg.sunFullPct;
    doc["sunNight"]   = cfg.sunNightPct;
    doc["manual"]     = cfg.manualPct;
    doc["tz"]         = cfg.tzPosix;
    doc["wifiAlertOn"]  = cfg.wifiAlertOnS;
    doc["wifiAlertOff"] = cfg.wifiAlertOffS;
    doc["wifiSsid"]     = cfg.wifiSsid;
    doc["wifiPass"]     = cfg.wifiPass;
    doc["wifiMigrated"] = cfg.wifiMigrated;
    doc["sensorEng"]     = cfg.sensorEngineering;
    doc["presenceDim"]      = cfg.presenceDimEnabled;
    doc["presenceAway"]     = cfg.presenceAwayPct;
    doc["presenceTimeout"]  = cfg.presenceTimeoutMin;
    doc["serialDebug"]      = cfg.serialDebug;
    doc["autoReboot"]       = cfg.autoRebootEnabled;
    doc["autoRebootDays"]   = cfg.autoRebootIntervalDays;
    doc["autoRebootHour"]   = cfg.autoRebootHour;
    doc["autoRebootAnchor"] = cfg.autoRebootAnchorDay;
    File f = LittleFS.open(CFG_PATH, "w");
    if (!f) { Serial.println("Config save failed (open)"); return; }
    serializeJson(doc, f);
    f.close();
    Serial.println("Config saved to LittleFS");
}

WiFiClient espClient;
PubSubClient mqtt(espClient);
ESP8266WebServer httpServer(80);
ESP8266HTTPUpdateServer httpUpdater;
String lastSyncStr = "Never";
String mdnsHost;



#define PIN_SDI 13
#define PIN_CLK 12
#define PIN_LE  5
#define PIN_OE  14
#define PIN_SDA 0
#define PIN_SCL 2
#define SD3078_ADDR 0x32
#define NUM_OUTPUTS 112

// D2, freed by moving the mmWave sensor to its own node. One of the five
// ESP8266 pins with no boot-time role, so the button wires the ordinary way:
// between D2 and GND, held HIGH by the internal pull-up, reading LOW when
// pressed. No external resistor.
//
// This was D0 (GPIO16), which was the only pin left at the time and is a bad
// fit three ways: it sits in the RTC domain and can read HIGH around reset, it
// has a pull-DOWN rather than a pull-up so the button had to go to 3V3, and
// that pull-down needs INPUT_PULLDOWN_16 -- plain INPUT leaves the pin
// floating. A floating input here means random resets, and 3 seconds of noise
// is a WiFi reset while 8 is a factory reset. D0 is now spare.
#define PIN_BUTTON 4

// ── segment maps: index order a,b,c,d,e,f,g  (-1 = not populated) ──
const int H2seg[7] = {77, 76, 74, 73, 72, 71, 75};
const int M1seg[7] = {80, 86, 85, 83, 82, 81, 84};
const int M2seg[7] = {91, 93, 94, 95, 89, 90, 92};
const int H1_b = 65, H1_c = 66;                 // tens-hour "1"

const int D1seg[7] = {34, 35, 36, 37, 38, -1, 47};   // date tens (blank/1/2/3), f absent
const int D2seg[7] = {46, 45, 43, 42, 41, 40, 44};   // date units
const int O1_b = 102, O1_c = 101;                    // month tens "1"
const int O2seg[7] = {109, 108, 107, 103, 104, 105, 106}; // month units

// year 4 digits (always 20XX) — TENTATIVE, verify by test
const int Y1seg[7] = {16, 22, -1, 19, 18, -1, 20};   // thousands "2"
const int Y2seg[7] = {29, 28, 27, 23, 24, 25, -1};   // hundreds "0" (b=28)
const int Y3seg[7] = {0, 5, 4, 3, 2, 1, 6};          // tens "2"
const int Y4seg[7] = {15, 14, 9, 13, 12, 11, 10};    // units

// day-of-week: 2 outputs each, index 0=Mon..6=Sun
const int DOW[7][2] = {{62,48},{61,49},{60,50},{59,51},{58,52},{57,53},{56,54}};

const int LED_D = 110, LED_M = 111, LED_Y = 8, LED_LOGO = 79;
const int COLON_OUT = 67;   // colon cathode wired to spare output 67

// digit font: bit0=a..bit6=g
const uint8_t font[10] = {0x3F,0x06,0x5B,0x4F,0x66,0x6D,0x7D,0x07,0x7F,0x6F};

bool frame[NUM_OUTPUTS];
int  brightness = 40;
bool manualMode = false;   // when true, show one output; don't auto-render clock
int  manualPos  = 0;
// Seconds on the reset button past which nothing fires -- see the release
// handler in loop(). Up here because renderButtonHold() needs it too.
const int BTN_ABORT = 15;

// Small in-RAM log of notable events (NTP sync, calibration, radar recovery,
// boot reason) for the app's debug log screen -- a lightweight stand-in for a
// serial monitor when there's no USB plugged in. Ring buffer, oldest entries
// simply age out; lost on reboot, which is fine since it's for "what's it
// doing right now/recently", not a persistent history.
const int LOG_CAP = 40;
String logBuf[LOG_CAP];
int logHead = 0, logCount = 0;
void logAdd(const String &s) {
    char ts[12]; snprintf(ts, sizeof(ts), "%lus: ", millis() / 1000);
    logBuf[logHead] = String(ts) + s;
    logHead = (logHead + 1) % LOG_CAP;
    if (logCount < LOG_CAP) logCount++;
}

// Sampled once/sec from a free-running counter incremented at the top of
// loop() -- a rough "how busy is the main loop" proxy, since there's no real
// scheduler/CPU-load concept on this chip to report instead.
unsigned long loopCounter = 0;
unsigned long lastLoopHz  = 0;

bool colonOn    = true;    // on for 800ms then a brief 200ms blank each
                           // second -- one clear flash per second (easy to
                           // count), rather than a 50/50 on/off that only
                           // completes one cycle every two seconds
// True during the 3s of each 20s cycle that the "no Con" notice is up. Set on
// the once-a-second tick, read by renderAll().
bool wifiAlertActive = false;
// OE PWM frequency and the logo LED now live in cfg (persisted) -- see cfg.oeFreq / cfg.logoOn
// HLK-LD2402 presence radar, on hardware Serial (RX/TX) -- see LD2402.h.
LD2402 radar;
bool presenceDetected = false;   // mirrors radar.presence(), updated every loop()
// The once-a-second tick log. Only ever prints when cfg.serialDebug is on
// (the console mode) -- in sensor mode the UART's TX must stay quiet (it's the
// sensor's RX). Defaults true so debug mode shows ticks immediately; 'l'
// toggles it within a debug session.
bool tickLogEnabled = true;

static uint8_t bcdToDec(uint8_t v) { return ((v >> 4) * 10) + (v & 0x0F); }
static uint8_t decToBcd(uint8_t v) { return ((v / 10) << 4) | (v % 10); }

// Day-of-week computed from the date itself (Sakamoto's algorithm), not read from
// the RTC's own day-of-week register -- that register only gets rewritten on boot,
// so if it doesn't auto-increment correctly at midnight it can get stuck for days.
// Returns 0=Sun..6=Sat, matching both struct tm's tm_wday and the RTC's own register format.
int dowSun0FromDate(int yr4, int mo1, int dd) {
    static const int t[] = {0,3,2,5,0,3,5,1,4,6,2,4};
    int y = yr4;
    if (mo1 < 3) y -= 1;
    return (y + y/4 - y/100 + y/400 + t[mo1-1] + dd) % 7;
}
// Same, but in the 1=Mon..7=Sun scale the DOW[] LED array and display use.
int dowFromDate(int yr4, int mo1, int dd) {
    int wdaySun0 = dowSun0FromDate(yr4, mo1, dd);
    return (wdaySun0 == 0) ? 7 : wdaySun0;
}


int lastDutyWritten = -1;

// Brightness curve, computed live so it can be compared without reflashing.
//
// gammaX100 = 100 is linear (duty tracks percent directly). Higher values bend
// the curve so equal slider movements look like equal brightness changes,
// which the eye wants -- but they also shorten low-brightness pulses, and short
// pulses are what let WiFi's interrupt jitter show up as flicker. That
// trade-off is the whole reason this is adjustable rather than baked in.
// gammaX100 == 0 selects the CIE 1931 lightness curve instead of a power curve.
//
// Why a separate curve rather than another gamma value: a power curve tuned to
// spread the dim end (2.2, say) sends the first few percent below duty 1, so
// 1-3% render as fully dark and those slider positions are wasted. CIE lands
// exactly on duty 1 at 1% and rises by roughly one duty unit per percent from
// there -- the finest steps the hardware can produce -- while still reaching
// 1023 at 100%. Same 100 slider positions, distributed where the eye can
// actually see the difference.
//
// The floor is the flicker guard: at 1kHz, duty 1 is a ~1us pulse and WiFi's
// interrupt jitter is about the same size, which is what made the display
// flicker before. Raise cfg.dutyFloor if the dim end shimmers.
uint16_t dutyForPct(int pct) {
    if (pct <= 0) return 0;
    if (pct >= 100) return 1023;

    float lum;
    if (cfg.gammaX100 == 0) {
        // CIE 1931: Y = ((L+16)/116)^3 above L=8, linear below the knee.
        const float L = (float)pct;
        lum = (L > 8.0f) ? powf((L + 16.0f) / 116.0f, 3.0f) : L / 903.3f;
    } else {
        const float g = constrain(cfg.gammaX100, 100, 300) / 100.0f;
        lum = powf(pct / 100.0f, g);
    }

    int duty = (int)lroundf(lum * 1023.0f);
    const int floorDuty = constrain(cfg.dutyFloor, 1, 50);
    return constrain(duty, floorDuty, 1023);   // never let a non-zero percent go dark
}

// The actual PWM write. Everything that changes the light ends up here.
void setDuty(int duty) {
    duty = constrain(duty, 0, 1023);
    // Only touch the PWM when the duty actually changes. analogWrite restarts
    // the ESP8266's waveform generator, so redundant writes show up as flicker.
    if (duty == lastDutyWritten) return;
    lastDutyWritten = duty;
    analogWrite(PIN_OE, 1023 - duty);   // OE is active-low
}

void setBrightness(int pct) {
    brightness = constrain(pct, 0, 100);
    setDuty(dutyForPct(brightness));
}

// ── physical button (D2): long-holds reset, see renderButtonHold() ──
// Clears both credential stores: ours in cfg.json, and the SDK's own copy in
// its separate flash area (WiFi.disconnect(true)) -- otherwise WiFi.begin()
// with no args would silently reconnect the "forgotten" network on next boot.
void doWifiReset() {
    Serial.println("Button: WiFi reset -- clearing saved network, rebooting to setup");
    cfg.wifiSsid[0] = '\0'; cfg.wifiPass[0] = '\0';
    cfg.wifiMigrated = true;            // don't re-adopt the SDK's old copy on reboot
    saveConfig();
    WiFi.disconnect(true);
    delay(200);
    ESP.restart();
}

void doFactoryReset() {
    Serial.println("Button: factory reset -- clearing WiFi + all settings, rebooting to setup");
    WiFi.disconnect(true);
    cfg = decltype(cfg)();
    cfg.wifiMigrated = true;            // portal on reboot, not a silent re-adopt
    saveConfig();
    delay(200);
    ESP.restart();
}

// ── day/night brightness scheduler ────────────────────────────────────
// Runs entirely off the RTC: no WiFi, no MQTT, no app. If the network is down
// the clock still dims itself at night, which is the whole point of keeping
// the config on the device.
// Fades interpolate in *duty* (0-1023), not percent. Percent is far too coarse
// at the dim end: 2% to 1% is only two steps to move through, so a "fade" there
// was really a jump with extra ceremony. The same pair is duty 20 to 10 -- ten
// steps -- and at the bright end percent was always fine anyway. fadeToPct is
// kept so the fade lands on an exact percent and `brightness` stays truthful.
int  fadeFromDuty = -1, fadeToDuty = -1, fadeToPct = -1;   // -1 = no fade
unsigned long fadeStart = 0;
int  lastAutoSyncDay = -1;            // day-of-month of the last daily NTP check

void cancelFade() { fadeFromDuty = fadeToDuty = fadeToPct = -1; }

void beginFade(int to) {
    if (to == fadeToPct) return;       // already heading there
    // Start from the duty actually on the pin, not from dutyForPct(brightness):
    // if a fade is already in flight those differ, and using the percent would
    // snap backwards before fading forwards.
    fadeFromDuty = (lastDutyWritten >= 0) ? lastDutyWritten : dutyForPct(brightness);
    fadeToDuty   = dutyForPct(to);
    fadeToPct    = to;
    fadeStart    = millis();
    if (cfg.fadeMs <= 0) { setBrightness(to); cancelFade(); }
}

// Night wraps past midnight (e.g. 23 -> 6), so the comparison flips depending
// on whether the window crosses 00:00.
bool isNightHour(int h24) {
    if (cfg.nightStart == cfg.nightEnd) return false;
    return (cfg.nightStart < cfg.nightEnd)
        ? (h24 >= cfg.nightStart && h24 < cfg.nightEnd)
        : (h24 >= cfg.nightStart || h24 < cfg.nightEnd);
}

// Days-since-a-fixed-epoch, for the scheduled-restart interval (Howard
// Hinnant's civil_from_days algorithm, well-known and exact across leap
// years/month lengths -- unlike yr*365+dayOfYear, which drifts). Only needs
// to be monotonic and consistent day-to-day, not calendar-meaningful.
long daysFromCivil(int y, int m, int d) {
    y -= m <= 2;
    long era = (y >= 0 ? y : y - 399) / 400;
    unsigned yoe = (unsigned)(y - era * 400);
    unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + (long)doe - 719468;
}

// While the user is dragging a slider in the app we hold the scheduler off.
// Otherwise the once-a-second tick re-applies day-or-night brightness and
// stomps on the preview within a second -- dragging "night brightness" during
// the day would snap straight back, which felt broken.
unsigned long previewHoldUntil = 0;
const unsigned long PREVIEW_HOLD_MS = 4000;

// ── sun tracking ──────────────────────────────────────────────────────
//
// How high the sun is, in degrees above the horizon. Negative means below it.
// Standard NOAA approximation -- accurate to a minute or so, which is far more
// than a wall clock's brightness needs. Cross-checked against an independent
// implementation: at lat 20.59 lon 78.96 (the point this was validated
// against) on 2026-07-18 this gives sunrise 05:47 and sunset 18:54.
int dayOfYear(int yr, int mo, int dd) {
    static const int cum[] = {0,31,59,90,120,151,181,212,243,273,304,334};
    int n = cum[constrain(mo,1,12) - 1] + dd;
    bool leap = (yr % 4 == 0 && yr % 100 != 0) || (yr % 400 == 0);
    if (leap && mo > 2) n++;
    return n;
}

// The system clock (kept live by the SNTP client configTzTime() starts)
// already knows today's correct UTC offset for cfg.tzPosix, DST included --
// newlib resolves the rule against the current date every time this runs. So
// the sun maths never need their own DST logic, just this.
//
// This newlib has neither tm_gmtoff nor timegm(), so the offset is derived
// the indirect way: read the UTC calendar fields for right now, then ask
// mktime() to reinterpret those same fields AS LOCAL time (tm_isdst = -1
// tells it to resolve DST for that date itself, rather than assuming
// standard time). The gap between that result and the real "now" is exactly
// the current offset.
float currentTzOffsetHours() {
    time_t now = time(nullptr);
    struct tm tmUtc;
    gmtime_r(&now, &tmUtc);
    tmUtc.tm_isdst = -1;
    time_t asIfLocal = mktime(&tmUtc);
    return (float)(now - asIfLocal) / 3600.0f;
}

// [morning], when given, reports whether this moment is before solar noon --
// free here, since true solar time is computed on the way to the elevation.
// Needed because dawn and dusk have separate twilight settings, and elevation
// alone can't tell the two apart: the same height happens twice a day.
float solarElevation(int yr, int mo, int dd, int h24, int minute,
                     bool *morning = nullptr) {
    const float tzHours = currentTzOffsetHours();
    const int   N       = dayOfYear(yr, mo, dd);
    const float hour    = h24 + minute / 60.0f;

    const float g = 2.0f * PI / 365.0f * (N - 1 + (hour - 12.0f) / 24.0f);
    const float eqtime = 229.18f * (0.000075f + 0.001868f * cosf(g)
                       - 0.032077f * sinf(g) - 0.014615f * cosf(2*g)
                       - 0.040849f * sinf(2*g));
    const float decl = 0.006918f - 0.399912f * cosf(g) + 0.070257f * sinf(g)
                     - 0.006758f * cosf(2*g) + 0.000907f * sinf(2*g)
                     - 0.002697f * cosf(3*g) + 0.00148f * sinf(3*g);

    const float timeOffset = eqtime + 4.0f * cfg.lon - 60.0f * tzHours;
    const float tst = hour * 60.0f + timeOffset;
    if (morning) *morning = (tst < 720.0f);   // 720 min of true solar time = solar noon
    const float ha  = radians(tst / 4.0f - 180.0f);
    const float la  = radians(cfg.lat);

    float cosz = sinf(la) * sinf(decl) + cosf(la) * cosf(decl) * cosf(ha);
    cosz = constrain(cosz, -1.0f, 1.0f);
    return degrees(asinf(cosz));
}

// Highest the sun gets on this specific day, in degrees -- the reference point
// sunPct() scales against so "full brightness" lands at solar noon and
// adjusts itself for the season automatically. The hour term in solarElevation
// drops out at exactly solar noon (ha=0, cos(ha)=1), so this only needs the
// declination, not the full time-of-day calculation.
float solarPeakElevation(int yr, int mo, int dd) {
    const int N = dayOfYear(yr, mo, dd);
    const float g = 2.0f * PI / 365.0f * (N - 1);
    const float decl = 0.006918f - 0.399912f * cosf(g) + 0.070257f * sinf(g)
                     - 0.006758f * cosf(2*g) + 0.000907f * sinf(2*g)
                     - 0.002697f * cosf(3*g) + 0.00148f * sinf(3*g);
    const float la = radians(cfg.lat);
    float cosz = sinf(la) * sinf(decl) + cosf(la) * cosf(decl);
    cosz = constrain(cosz, -1.0f, 1.0f);
    return degrees(asinf(cosz));
}

// Brightness that follows the sun: dark through the night, easing up through
// dawn, brightest around midday, easing back down at dusk.
//
// The ramp is scaled against *this day's own peak* (in sine space, which is
// how daylight brightness actually behaves), not a fixed degree ceiling.
// cfg.sunHighDeg used to be that ceiling (e.g. "25 degrees = full brightness")
// but that's flat-out wrong except around one specific time of year: in
// midsummer the sun clears 25 degrees quickly and stays flat at max for ~10
// hours, while in midwinter at higher latitudes it may barely reach 25 at
// all (ISSUES.md #6). Scaling to the actual peak means "full at solar noon,
// easing down toward morning/evening" always holds, any season, any latitude.
// cfg.sunHighDeg is kept (still saved/loaded) for compatibility but no longer
// used here.
int sunPct(int yr, int mo, int dd, int h24, int minute) {
    bool morning = false;
    const float elev = solarElevation(yr, mo, dd, h24, minute, &morning);
    // Dawn and dusk have their own floors: the sun is symmetric, but the use of
    // the clock isn't -- you're awake in the evening and asleep before dawn.
    const float low = morning ? cfg.sunDawnDeg : cfg.sunDuskDeg;
    if (elev <= low) return cfg.sunNightPct;   // below the twilight floor -- still night
    const float peak = solarPeakElevation(yr, mo, dd);
    // Ramp from the twilight floor to the peak, not from the horizon. Dividing
    // by sin(peak) alone looks right but silently breaks below the horizon:
    // sin of a negative elevation is negative, so every value after sunset
    // clamped to zero and the dusk setting could never do anything.
    const float sLow  = sinf(radians(low));
    const float sPeak = sinf(radians(peak));
    float t = (sPeak > sLow + 0.001f)
        ? (sinf(radians(elev)) - sLow) / (sPeak - sLow)
        : 1.0f;
    t = constrain(t, 0.0f, 1.0f);
    return cfg.sunNightPct + (int)lroundf((cfg.sunFullPct - cfg.sunNightPct) * t);
}

// Brightness for a given time of day, ramping gradually across the day/night
// boundaries rather than snapping.
//
// Working in minutes-since-boundary (mod a day) makes the midnight wrap fall
// out for free: whichever boundary we passed most recently is the state we're
// in, and if we passed it less than transitionMin ago we're mid-ramp.
int targetPctForTime(int h24, int minute) {
    const int now = h24 * 60 + minute;
    const int sinceStart = (now - cfg.nightStart * 60 + 1440) % 1440;
    const int sinceEnd   = (now - cfg.nightEnd   * 60 + 1440) % 1440;
    const int t = constrain(cfg.transitionMin, 0, 240);

    if (t > 0 && sinceStart < t) {   // ramping down into night
        return cfg.fullPct + (cfg.nightPct - cfg.fullPct) * sinceStart / t;
    }
    if (t > 0 && sinceEnd < t) {     // ramping back up into day
        return cfg.nightPct + (cfg.fullPct - cfg.nightPct) * sinceEnd / t;
    }
    return (sinceStart < sinceEnd) ? cfg.nightPct : cfg.fullPct;
}

// What brightness the active mode currently wants, regardless of presence.
// Shared by updateSchedule() (the normal per-tick apply) and the presence
// overlay below (which needs to know what to snap back to when someone
// returns -- e.g. Sun mode's *current* afternoon level, not a stale one).
int modeTargetPct(int h24, int minute, int yr, int mo, int dd) {
    if (cfg.mode == MODE_SUN)      return sunPct(yr, mo, dd, h24, minute);
    if (cfg.mode == MODE_SCHEDULE) return targetPctForTime(h24, minute);
    return cfg.manualPct;
}

// ── presence dimming overlay state -- declared here (ahead of both
// updateSchedule() and applyPresenceOverlay()) since updateSchedule() needs
// to check presenceDimActive to know when to yield control. See
// applyPresenceOverlay() below for what actually drives it. ──
unsigned long lastPresenceMs = 0;
bool presenceDimActive = false;

// Called once a second with the RTC's time (fade=true: smooth automatic
// day/night transitions), and once right after a user changes a setting
// (fade=false: apply the corrected brightness instantly -- a user action
// should never sit through a multi-second fade toward "what the schedule
// already thinks is correct").
void updateSchedule(int h24, int minute, int yr, int mo, int dd, bool fade) {
    if (cfg.mode == MODE_MANUAL) return;
    if (millis() < previewHoldUntil) return;   // user is previewing; leave it alone
    if (presenceDimActive) return;             // presence overlay has the wheel right now
    // Fade rather than snap: both modes already spread the change over many
    // minutes, so each once-a-second step is normally tiny, but that broke down
    // at the dim end -- 2% to 1% halves the light output in one step. cfg.fadeMs
    // is short enough not to lag behind the schedule, and stepFade() is already
    // throttled (~50Hz) against flicker.
    const int want = modeTargetPct(h24, minute, yr, mo, dd);
    if (want == brightness) return;
    if (fade) beginFade(want);
    else { cancelFade(); setBrightness(want); }
}

// ── presence dimming overlay -- works on top of any brightness mode,
// Manual included, since it is an explicit opt-in rather than the mode's own
// behavior. Off by default (cfg.presenceDimEnabled = false): nothing changes
// for anyone who hasn't turned it on.
//
// Edge-triggered on purpose: only fires a fade when presence actually flips,
// not every tick, so it doesn't fight a user's live brightness drag (which
// already gets a previewHoldUntil window) or repeatedly re-fade to the same
// target. lastPresenceMs starts at boot time (set in setup()), so an empty
// room at boot dims after one full timeout rather than staying bright forever
// waiting for a presence event that may never come.
void applyPresenceOverlay(int h24, int minute, int yr, int mo, int dd) {
    if (!cfg.presenceDimEnabled) { presenceDimActive = false; return; }
    if (radar.presence()) lastPresenceMs = millis();
    if (millis() < previewHoldUntil) return;   // user is previewing; leave it alone

    const bool timedOut = (millis() - lastPresenceMs) >=
        (unsigned long)cfg.presenceTimeoutMin * 60000UL;
    if (timedOut == presenceDimActive) return;   // already in the right state
    presenceDimActive = timedOut;

    const int target = timedOut ? cfg.presenceAwayPct
                                 : modeTargetPct(h24, minute, yr, mo, dd);
    beginFade(target);
}

// Called often from loop() -- steps an in-progress fade, non-blocking.
// Steps an in-progress fade. Throttled to ~50Hz: this used to run on every
// loop iteration, and each call means an analogWrite, which restarts the
// ESP8266's PWM waveform generator. Thousands of restarts a second made the
// display visibly flicker during fades.
unsigned long lastFadeStep = 0;

void stepFade() {
    if (fadeToPct < 0) return;
    if (millis() - lastFadeStep < 20) return;
    lastFadeStep = millis();

    // el as a signed long, and fadeMs cast to long in the division below, so
    // this whole expression stays signed arithmetic. It used to mix a signed
    // (fadeTo - fadeFrom), which is negative for a downward fade, with el as
    // unsigned long -- C++ silently converts the signed side to unsigned for
    // that multiplication, turning a small negative number into a huge
    // wrapped-around one. constrain() in setBrightness() then clamped that
    // garbage to 100, which is exactly the "briefly goes to full brightness"
    // bug seen fading to a lower value (never fading to a higher one, since
    // only a negative difference triggers the sign-to-unsigned conversion).
    long el = (long)(millis() - fadeStart);
    if (el >= (long)cfg.fadeMs) {
        setBrightness(fadeToPct);   // land on the exact percent, not a rounded duty
        cancelFade();
        return;
    }
    setDuty(fadeFromDuty +
            (int)((long)(fadeToDuty - fadeFromDuty) * el / (long)cfg.fadeMs));
}

void shiftFrame() {
    digitalWrite(PIN_LE, LOW);
    for (int i = NUM_OUTPUTS - 1; i >= 0; i--) {
        digitalWrite(PIN_SDI, frame[i] ? HIGH : LOW);
        digitalWrite(PIN_CLK, HIGH); digitalWrite(PIN_CLK, LOW);
    }
    digitalWrite(PIN_LE, HIGH); digitalWrite(PIN_LE, LOW);
}
void clearFrame() { for (int i = 0; i < NUM_OUTPUTS; i++) frame[i] = false; }
void setSeg(int out) { if (out >= 0 && out < NUM_OUTPUTS) frame[out] = true; }
void showOne(int p) { clearFrame(); setSeg(p); shiftFrame(); }   // manual: light one output
void putDigit(const int seg[7], int d) {
    if (d < 0 || d > 9) return;
    for (int s = 0; s < 7; s++) if (font[d] & (1 << s)) setSeg(seg[s]);
}

// Letters, same bit order as font[]: bit0=a .. bit6=g. Only the ones that are
// actually legible on seven segments -- K, M, V, W, X, Z have no honest form.
//
// Not every position can show every letter: this dial is missing segments on
// the date tens (no f), year thousands (no c, no f) and year hundreds (no g).
// setSeg() ignores the -1 entries, so an unsupported letter degrades to a
// partial shape rather than misdrawing. Check the map above before moving a
// word to a different slot.
const uint8_t GL_C = 0x39, GL_E = 0x79, GL_F = 0x71, GL_L = 0x38,
              GL_n = 0x54, GL_o = 0x5C, GL_r = 0x50;

void putGlyph(const int seg[7], uint8_t mask) {
    for (int s = 0; s < 7; s++) if (mask & (1 << s)) setSeg(seg[s]);
}

// Shown while the reset button is held. Everything else goes dark on purpose:
// this is the one moment the display is not a clock, and a half-visible time
// behind the count invites reading the wrong number and wiping the config.
//
// The count is the big hour digit; what releasing now would do is spelled out
// beside and below it, so neither counting flashes nor remembering which
// number means what is required.
void renderButtonHold(int count) {
    clearFrame();
    // The hours can carry two digits (the tens position only ever forms a "1",
    // which is all 10-15 needs), so the count stays visible right up to the
    // abort point rather than sticking at 9.
    if (count >= 10) { setSeg(H1_b); setSeg(H1_c); putDigit(H2seg, count % 10); }
    else if (count >= 1) putDigit(H2seg, count);

    if (count >= BTN_ABORT) {                // "no" -- held too long, nothing will happen
        putGlyph(M1seg, GL_n); putGlyph(M2seg, GL_o);
    } else if (count >= 8) {                 // "Fr" + "CLr" -- factory reset
        putGlyph(M1seg, GL_F); putGlyph(M2seg, GL_r);
        putGlyph(Y2seg, GL_C); putGlyph(Y3seg, GL_L); putGlyph(Y4seg, GL_r);
    } else if (count >= 3) {                 // "rE" + "Con" -- WiFi reset
        putGlyph(M1seg, GL_r); putGlyph(M2seg, GL_E);
        putGlyph(Y2seg, GL_C); putGlyph(Y3seg, GL_o); putGlyph(Y4seg, GL_n);
    }
    shiftFrame();
}

// dowSD: SD3078 day 1=Mon..7=Sun  -> index 0..6
void renderAll(int h12, int m, int dd, int mo, int yr4, int dowSD) {
    clearFrame();
    // time
    if (h12 >= 10) { setSeg(H1_b); setSeg(H1_c); }
    putDigit(H2seg, h12 % 10);
    if (m > 0) {                               // m==0 (on the hour) -> blank both minute digits, not "00"
        if (m / 10 > 0) putDigit(M1seg, m / 10);   // blank tens-of-minutes when 0 (e.g. 5:01, not 5:001-look)
        putDigit(M2seg, m % 10);
    }
    // "no Con" over the date and year while WiFi is down -- deliberately never
    // over the time, which has to stay readable at a glance whatever else is
    // wrong. The RTC keeps perfect time without a network, so this is a notice,
    // not an error: it says why the clock stopped syncing, nothing more.
    if (wifiAlertActive) {
        putGlyph(D1seg, GL_n); putGlyph(D2seg, GL_o);
        putGlyph(Y2seg, GL_C); putGlyph(Y3seg, GL_o); putGlyph(Y4seg, GL_n);
        // Month blanked and the date/month/year label LEDs left off, both so
        // the two words read as one message. The month first sat between them
        // as a hint this was a notice rather than a fault, but "no 7 Con" just
        // interrupts the sentence, and lit labels announce a date and a year
        // that are not being shown.
        if (dowSD >= 1 && dowSD <= 7) { setSeg(DOW[dowSD-1][0]); setSeg(DOW[dowSD-1][1]); }
        if (cfg.logoOn) setSeg(LED_LOGO);
        if (colonOn) setSeg(COLON_OUT);
        shiftFrame();
        return;
    }
    // date (tens blank if 0; dd is never actually 0 on a valid date, kept for defensiveness)
    if (dd > 0) {
        if (dd / 10 > 0) putDigit(D1seg, dd / 10);
        putDigit(D2seg, dd % 10);
    }
    // month (tens "1" only; mo is never actually 0 on a valid date, kept for defensiveness)
    if (mo > 0) {
        if (mo >= 10) { setSeg(O1_b); setSeg(O1_c); }
        putDigit(O2seg, mo % 10);
    }
    // year
    putDigit(Y1seg, (yr4 / 1000) % 10);
    putDigit(Y2seg, (yr4 / 100) % 10);
    putDigit(Y3seg, (yr4 / 10) % 10);
    putDigit(Y4seg, yr4 % 10);
    // day-of-week
    if (dowSD >= 1 && dowSD <= 7) { setSeg(DOW[dowSD-1][0]); setSeg(DOW[dowSD-1][1]); }
    // indicators always on; logo has its own toggle
    setSeg(LED_D); setSeg(LED_M); setSeg(LED_Y);
    if (cfg.logoOn) setSeg(LED_LOGO);
    // colon blink
    if (colonOn) setSeg(COLON_OUT);
    shiftFrame();
}

// ── RTC ──
void rtcEnableWrite() {
    Wire.beginTransmission(SD3078_ADDR); Wire.write(0x10); Wire.write(0x80); Wire.endTransmission(); delay(10);
    Wire.beginTransmission(SD3078_ADDR); Wire.write(0x0F); Wire.write(0x84); Wire.endTransmission(); delay(10);
}
void rtcDisableWrite() {
    Wire.beginTransmission(SD3078_ADDR); Wire.write(0x0F); Wire.write(0x00); Wire.endTransmission(); delay(10);
    Wire.beginTransmission(SD3078_ADDR); Wire.write(0x10); Wire.write(0x00); Wire.endTransmission(); delay(10);
}
// SD3078 datasheet 4.2: hour register bit7 = 12_/24 mode-select (0=12h, 1=24h),
// bit5 = AM/PM *only in 12h mode* (D4:D0 = BCD hour 1-12). Earlier firmware bug:
// PM was OR'd into bit7 (the mode bit) instead of bit5, so the chip's hour mode
// flipped depending on AM/PM at write time -- inconsistent state, likely why
// day-of-week got stuck. Fix: always run 12h mode (bit7 fixed 0), AM/PM correctly
// in bit5, so the RTC hands back h12 directly -- no ESP-side %12 conversion needed.
void rtcSetKnown() {
    rtcEnableWrite();
    Wire.beginTransmission(SD3078_ADDR);
    Wire.write(0x00);
    Wire.write(decToBcd(30)); Wire.write(decToBcd(9)); Wire.write(decToBcd(10) | 0x20); // 10:09:30 PM, 12h mode
    Wire.write(4);            // Thu (datasheet 4.2: reg 03H 00=Sun..06=Sat)
    Wire.write(decToBcd(25)); Wire.write(decToBcd(12)); Wire.write(decToBcd(26));       // 25/12/26
    uint8_t err = Wire.endTransmission();
    rtcDisableWrite();
    Serial.println(err == 0 ? "RTC set OK (Thu 25/12/2026 10:09:30 PM)" : "RTC set FAIL");
}
bool rtcReadAll(int &h12, bool &pm, int &m, int &s, int &dd, int &mo, int &yr, int &dow) {
    Wire.beginTransmission(SD3078_ADDR); Wire.write(0x00);
    if (Wire.endTransmission(false) != 0) return false;
    Wire.requestFrom((uint8_t)SD3078_ADDR, (uint8_t)7);
    if (Wire.available() < 7) return false;
    s = bcdToDec(Wire.read() & 0x7F);
    m = bcdToDec(Wire.read() & 0x7F);
    uint8_t hr = Wire.read();
    h12 = bcdToDec(hr & 0x1F);   // mask off bit7 (mode) + bit5 (AM/PM) -- D4:D0 = BCD hour 1-12
    pm  = (hr & 0x20) != 0;      // bit5 = AM/PM in 12h mode
    dow = Wire.read();
    dd  = bcdToDec(Wire.read());
    mo  = bcdToDec(Wire.read());
    yr  = 2000 + bcdToDec(Wire.read());
    return (h12 >= 1 && h12 <= 12);
}

// write full date/time to RTC, always in 12-hour mode (see note above)
void rtcWriteFull(int sec, int mn, int h24, int wdaySun0, int mday, int mon1, int yr4) {
    bool pm = (h24 >= 12);
    int h12 = h24 % 12; if (h12 == 0) h12 = 12;
    rtcEnableWrite();
    Wire.beginTransmission(SD3078_ADDR);
    Wire.write(0x00);
    Wire.write(decToBcd(sec));
    Wire.write(decToBcd(mn));
    Wire.write(decToBcd(h12) | (pm ? 0x20 : 0));   // bit7=0 (12h mode), bit5=AM/PM (datasheet 4.2)
    Wire.write(wdaySun0);   // datasheet 4.2: reg 03H is 00=Sun..06=Sat, same as struct tm's tm_wday -- no conversion
    Wire.write(decToBcd(mday));
    Wire.write(decToBcd(mon1));
    Wire.write(decToBcd(yr4 % 100));
    uint8_t err = Wire.endTransmission();
    rtcDisableWrite();
    Serial.println(err == 0 ? "RTC write OK" : "RTC write FAIL");   // generic -- rtcWriteFull is shared by NTP sync and the 'u' custom-set command
}

// The setup page, served from the AP. Self-contained (no external anything --
// there is no internet yet). Talks to /scan (GET -> JSON network list) and
// /connect (POST ssid/pass/pin/tz). The browser computes the POSIX timezone
// itself, exactly as the app does, so a fresh clock is correct anywhere on
// first setup with no cloud lookup. Design mirrors the app's dark/cyan theme.
static const char SETUP_PAGE[] PROGMEM = R"PORTAL(<!doctype html><html><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Clockwise - Set up WiFi</title><style>
:root{--bg:#0a0b0f;--sf:#14151d;--sf2:#191b24;--ln:#262835;--ln2:#333648;
--tx:#f3f4fa;--mut:#9a9eb4;--ft:#6d7085;--ac:#22d3ee;--acd:#0891b2;--ai:#04121a;--gd:#34d399}
*{box-sizing:border-box}html,body{margin:0}
body{background:radial-gradient(120% 80% at 50% -10%,#12202b 0,transparent 55%),var(--bg);
color:var(--tx);font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
min-height:100vh;display:flex;justify-content:center;padding:26px 16px 40px;-webkit-font-smoothing:antialiased}
.wrap{width:100%;max-width:412px}
.brand{display:flex;flex-direction:column;align-items:center;text-align:center;gap:13px;margin-bottom:24px}
.em{position:relative;width:72px;height:72px;border-radius:50%;background:radial-gradient(circle,#0e1620,#0a0d13 70%);
border:1px solid var(--ln2);box-shadow:0 14px 40px -12px rgba(34,211,238,.35)}
.em::before{content:"";position:absolute;inset:0;border-radius:50%;
background:conic-gradient(from 0deg,transparent 0,rgba(34,211,238,.55) 60deg,transparent 62deg);
animation:sw 3.4s linear infinite;-webkit-mask:radial-gradient(circle,transparent 30%,#000 31%);
mask:radial-gradient(circle,transparent 30%,#000 31%)}
.em .d{position:absolute;inset:0;margin:auto;width:8px;height:8px;border-radius:50%;
background:var(--ac);box-shadow:0 0 12px 2px rgba(34,211,238,.7)}
@keyframes sw{to{transform:rotate(360deg)}}
@media(prefers-reduced-motion:reduce){.em::before{animation:none}}
h1{font-size:21px;font-weight:600;margin:0}.sub{font-size:13px;color:var(--mut);margin:0;max-width:30ch}
.card{background:linear-gradient(180deg,var(--sf),#0d0f16);border:1px solid var(--ln);border-radius:14px;padding:6px;overflow:hidden}
.ch{display:flex;align-items:center;justify-content:space-between;padding:12px 12px 8px}
.ch .lb{font-size:11px;font-weight:600;letter-spacing:.09em;text-transform:uppercase;color:var(--ft)}
.rs{display:flex;align-items:center;gap:6px;background:none;border:0;color:var(--ac);font:inherit;
font-size:12.5px;font-weight:600;cursor:pointer;padding:4px 6px;border-radius:8px}
.rs svg{width:14px;height:14px}.rs.sp svg{animation:rot .9s linear infinite}
@keyframes rot{to{transform:rotate(360deg)}}
.list{display:flex;flex-direction:column;gap:2px;padding:2px}
.net{display:flex;align-items:center;gap:12px;width:100%;background:none;border:0;border-radius:10px;
padding:13px 12px;color:var(--tx);font:inherit;text-align:left;cursor:pointer}
.net:hover{background:var(--sf2)}
.net[aria-selected=true]{background:rgba(34,211,238,.10);box-shadow:inset 0 0 0 1px rgba(34,211,238,.35)}
.net .nm{flex:1;font-size:15.5px;font-weight:500;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.net .mt{display:flex;align-items:center;gap:9px;color:var(--ft)}
.lk{width:13px;height:13px;opacity:.85}
.bars{display:flex;align-items:flex-end;gap:2px;height:15px}
.bars i{width:3px;border-radius:1px;background:var(--ln2)}
.bars i:nth-child(1){height:5px}.bars i:nth-child(2){height:8px}.bars i:nth-child(3){height:11px}.bars i:nth-child(4){height:15px}
.bars.s1 i:nth-child(-n+1),.bars.s2 i:nth-child(-n+2),.bars.s3 i:nth-child(-n+3),.bars.s4 i:nth-child(-n+4){background:var(--ac)}
.ck{width:18px;height:18px;color:var(--ac);flex:0 0 auto}
.sk{display:flex;align-items:center;gap:12px;padding:13px 12px}
.sk .b{height:13px;border-radius:6px;flex:1;background:linear-gradient(90deg,var(--sf2) 25%,#20222e 37%,var(--sf2) 63%);
background-size:400% 100%;animation:shm 1.3s ease infinite}
@keyframes shm{0%{background-position:100% 0}100%{background-position:-100% 0}}
.pan{max-height:0;opacity:0;overflow:hidden;transition:max-height .32s,opacity .28s}
.pan.op{max-height:360px;opacity:1}
.fld{padding:6px 12px 12px}.fld label{display:block;font-size:12px;color:var(--mut);margin:0 0 7px 2px;font-weight:500}
.ip{position:relative;display:flex;align-items:center}
input{width:100%;background:#101119;color:var(--tx);border:1px solid var(--ln2);border-radius:11px;
padding:13px 44px 13px 13px;font-size:16px;font-family:inherit}
input::placeholder{color:var(--ft)}
input:focus{outline:none;border-color:var(--ac);box-shadow:0 0 0 3px rgba(34,211,238,.14)}
.eye{position:absolute;right:6px;background:none;border:0;color:var(--mut);cursor:pointer;padding:8px;border-radius:8px;display:flex}
.eye svg{width:19px;height:19px}
.pb{border-top:1px solid var(--ln);margin-top:2px;padding-top:4px}
.opt{font-size:11px;font-weight:600;letter-spacing:.05em;text-transform:uppercase;color:var(--ft);
border:1px solid var(--ln2);border-radius:6px;padding:1px 6px;margin-left:6px}
.hint{font-size:12px;color:var(--ft);line-height:1.5;margin:8px 2px 0}
#pf.hide{display:none}
.err{color:#fb7185;font-size:13px;text-align:center;padding:8px 12px 0;display:none}
.go{width:100%;margin-top:16px;border:0;border-radius:13px;cursor:pointer;
background:linear-gradient(180deg,var(--ac),var(--acd));color:var(--ai);font:inherit;font-size:16px;font-weight:700;
padding:15px;display:flex;align-items:center;justify-content:center;gap:9px;box-shadow:0 10px 30px -10px rgba(34,211,238,.6)}
.go:disabled{background:var(--sf2);color:var(--ft);box-shadow:none;cursor:not-allowed}
.go .sp{width:18px;height:18px;border:2.5px solid rgba(4,18,26,.35);border-top-color:var(--ai);border-radius:50%;animation:rot .7s linear infinite}
.ft{text-align:center;color:var(--ft);font-size:12px;margin-top:20px;line-height:1.6}.ft b{color:var(--mut)}
.done{position:fixed;inset:0;background:rgba(8,9,13,.9);display:none;flex-direction:column;
align-items:center;justify-content:center;gap:16px;padding:24px;text-align:center}
.done.show{display:flex}
.rg{width:82px;height:82px;border-radius:50%;border:2px solid rgba(52,211,153,.4);display:flex;
align-items:center;justify-content:center;box-shadow:0 0 40px -6px rgba(52,211,153,.5)}
.rg svg{width:38px;height:38px;color:var(--gd)}.done h2{margin:0;font-size:20px}.done p{margin:0;color:var(--mut);font-size:14px;max-width:28ch}
</style></head><body><div class="wrap">
<div class="brand"><div class="em"><span class="d"></span></div>
<div><h1>Clockwise</h1><p class="sub">Choose your WiFi network to bring the clock online. Everything else is set up in the app.</p></div></div>
<div class="card"><div class="ch"><span class="lb" id="ll">Scanning...</span>
<button class="rs" id="rs" aria-label="Scan again"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 1 1-2.64-6.36"/><path d="M21 3v6h-6"/></svg>Rescan</button></div>
<div class="list" id="ls"></div>
<div class="pan" id="pp"><div class="fld" id="pf"><label id="pl" for="pw">Password</label>
<div class="ip"><input id="pw" type="password" placeholder="Network password" autocomplete="off">
<button class="eye" id="ey" type="button" aria-label="Show password"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7-10-7-10-7Z"/><circle cx="12" cy="12" r="3"/></svg></button></div></div>
<div class="pb"><div class="fld"><label for="pin">App PIN <span class="opt">optional</span></label>
<input id="pin" type="text" inputmode="numeric" placeholder="e.g. 4827" autocomplete="off">
<p class="hint">Set a PIN and the app will need it to connect - this is the only place it can be set. Leave blank on a home network.</p></div></div></div></div>
<p class="err" id="er">Couldn't connect. Check the password and try again.</p>
<button class="go" id="go" disabled><span id="gt">Select a network</span></button>
<p class="ft">Connected to <b>Clockwise-Setup</b><br>Brightness, timezone and the rest live in the app.</p></div>
<div class="done" id="dn"><div class="rg"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg></div>
<h2 id="dh">You're all set</h2><p>The clock is joining your network. It'll show up in the app in a moment.</p><p id="dloc" class="hint"></p></div>
<script>
var ls=d('ls'),ll=d('ll'),pp=d('pp'),pf=d('pf'),pw=d('pw'),pl=d('pl'),pin=d('pin'),go=d('go'),gt=d('gt'),rs=d('rs'),er=d('er'),sel=null;
function d(i){return document.getElementById(i)}
function lk(){return '<svg class="lk" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>'}
function bars(n){return '<span class="bars s'+n+'"><i></i><i></i><i></i><i></i></span>'}
function skel(){ls.innerHTML='';for(var i=0;i<4;i++)ls.insertAdjacentHTML('beforeend','<div class="sk"><span class="bars"><i></i><i></i><i></i><i></i></span><span class="b" style="max-width:'+[70,52,60,44][i]+'%"></span></div>')}
function esc(s){return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}
function scan(){rs.classList.add('sp');ll.textContent='Scanning...';pp.classList.remove('op');go.disabled=true;gt.textContent='Select a network';er.style.display='none';skel();
fetch('/scan').then(function(r){return r.json()}).then(render).catch(function(){ll.textContent='Scan failed - tap rescan'})}
function render(nets){rs.classList.remove('sp');ls.innerHTML='';
if(!nets.length){ll.textContent='No networks found';return}
ll.textContent='Networks nearby';
nets.forEach(function(n){var b=document.createElement('button');b.className='net';b.setAttribute('aria-selected','false');
b.innerHTML='<span class="nm">'+esc(n.s)+'</span><span class="mt">'+(n.l?lk():'')+bars(n.b)+'</span>';
b.onclick=function(){pick(n,b)};ls.appendChild(b)})}
function pick(n,el){sel=n;er.style.display='none';
[].forEach.call(ls.children,function(c){if(c.setAttribute)c.setAttribute('aria-selected','false');var k=c.querySelector('.ck');if(k)k.remove()});
el.setAttribute('aria-selected','true');
el.querySelector('.mt').insertAdjacentHTML('afterbegin','<svg class="ck" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>');
pp.classList.add('op');
if(n.l){pf.classList.remove('hide');pw.value='';pl.textContent='Password for "'+n.s+'"';setTimeout(function(){pw.focus()},260)}
else pf.classList.add('hide');
go.disabled=false;gt.textContent='Connect'}
d('ey').onclick=function(){pw.type=pw.type=='password'?'text':'password'};
rs.onclick=scan;
function tz(){try{function o(x){return -x.getTimezoneOffset()}
function fm(m){var s=m<0?'-':'',a=Math.abs(m),h=a/60|0,n=a%60;return s+h+(n?':'+('0'+n).slice(-2):'')}
function ab(x,m){var p=new Intl.DateTimeFormat('en',{timeZoneName:'short'}).formatToParts(x).find(function(z){return z.type=='timeZoneName'});
var v=p?p.value:'';if(/^[A-Za-z]{3,}$/.test(v))return v;var s=m<0?'-':'+',a=Math.abs(m),h=('0'+(a/60|0)).slice(-2),n=a%60;return '<'+s+h+(n?('0'+n).slice(-2):'')+'>'}
var y=new Date().getFullYear(),ar=[],i;for(i=0;i<12;i++)ar.push(o(new Date(y,i,15,12)));
var st=Math.min.apply(null,ar),ds=Math.max.apply(null,ar),sM=ar.indexOf(st),dM=ar.indexOf(ds);
var base=ab(new Date(y,sM,15,12),st)+fm(-st);if(st==ds)return base;
var a=null,b=null,pv=o(new Date(y,0,1,12));
for(var e=new Date(y,0,2,12);e.getFullYear()==y;e.setDate(e.getDate()+1)){var c=o(e);if(c!=st&&pv==st)a=new Date(e);if(c==st&&pv!=st)b=new Date(e);pv=c}
if(!a||!b)return base;function pd(t){var w=t.getDay(),lz=new Date(t.getFullYear(),t.getMonth()+1,0).getDate(),k=t.getDate()+7>lz?5:((t.getDate()-1)/7|0)+1;return 'M'+(t.getMonth()+1)+'.'+k+'.'+w}
return base+ab(new Date(y,dM,15,12),ds)+fm(-ds)+','+pd(a)+','+pd(b)}catch(e){return ''}}
go.onclick=function(){if(!sel)return;go.disabled=true;er.style.display='none';go.innerHTML='<span class="sp"></span> Connecting...';
var body='ssid='+encodeURIComponent(sel.s)+'&pass='+encodeURIComponent(pw.value)+'&pin='+encodeURIComponent(pin.value)+'&tz='+encodeURIComponent(tz());
fetch('/connect',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:body})
.then(function(r){return r.json()}).then(function(j){
if(j.ok){d('dh').textContent='Connected to '+sel.s;
d('dloc').textContent=j.geo?('Approximate location set ('+(j.city||'nearby')+') -- refine it in the app for accuracy.'):'Location not found automatically -- set it in the app (Settings > Device > Location).';
d('dn').classList.add('show')}
else{er.style.display='block';go.disabled=false;go.innerHTML='<span id="gt">Try again</span>'}})
.catch(function(){er.style.display='block';go.disabled=false;go.innerHTML='<span id="gt">Try again</span>'})};
skel();scan();
</script></body></html>)PORTAL";

// Try saved credentials only -- never opens the portal. Used at boot and by
// ntpSync.
//
// cfg is the source of truth. The no-args WiFi.begin() (which adopts the SDK's
// own stored credentials) fires exactly once, for an install upgraded from the
// WiFiManager build: on success the adopted SSID/pass are copied into cfg and
// wifiMigrated is set, so it never runs again. That is what stops a WiFi reset
// -- which clears cfg but leaves wifiMigrated set -- from silently re-adopting
// the old network instead of opening the portal.
bool wifiTryConnect(uint32_t ms = 15000) {
    if (WiFi.status() == WL_CONNECTED) return true;
    WiFi.mode(WIFI_STA);

    bool adopting = false;
    if (strlen(cfg.wifiSsid) > 0) {
        WiFi.begin(cfg.wifiSsid, cfg.wifiPass);
    } else if (!cfg.wifiMigrated) {
        WiFi.begin();                 // one-time adoption of the old build's creds
        adopting = true;
    } else {
        return false;                 // no creds, migration done -> caller opens portal
    }

    uint32_t start = millis();
    while (millis() - start < ms) {
        if (WiFi.status() == WL_CONNECTED) {
            if (adopting) {           // remember what we just adopted, in cfg
                strlcpy(cfg.wifiSsid, WiFi.SSID().c_str(), sizeof(cfg.wifiSsid));
                strlcpy(cfg.wifiPass, WiFi.psk().c_str(), sizeof(cfg.wifiPass));
                cfg.wifiMigrated = true;
                saveConfig();
                Serial.println("Adopted existing WiFi credentials into config");
            }
            Serial.print("WiFi OK "); Serial.println(WiFi.localIP());
            return true;
        }
        delay(200);
    }
    if (adopting) {                   // adoption failed -- don't retry it next boot
        cfg.wifiMigrated = true;
        saveConfig();
    }
    return false;
}

// Best-effort approximate location, called from /connect right after the ESP
// joins the home network (real internet, setup AP still up for the phone).
// Closes the gap where the WiFi portal only ever set a timezone, never
// coordinates, leaving Sun mode computing sunrise/sunset for the London-area
// placeholder default. City-level accurate at best (IP geolocation, not
// GPS) -- good enough for sun math, not a substitute for the app's real
// GPS/city picker, which is why the app still warns if this doesn't land.
// Plain HTTP on purpose: ip-api.com's free tier needs no key and no TLS,
// which keeps this off BearSSL (meaningful RAM on an ESP8266 already running
// WiFi + a radar UART parser + a web server). Never blocks setup on failure.
bool geolocateByIP(float &lat, float &lon, String &city) {
    WiFiClient client;
    HTTPClient http;
    http.setTimeout(4000);
    if (!http.begin(client, "http://ip-api.com/json/?fields=status,lat,lon,city")) return false;
    int code = http.GET();
    bool ok = false;
    if (code == 200) {
        JsonDocument doc;
        if (!deserializeJson(doc, http.getString()) &&
            strcmp(doc["status"] | "", "success") == 0) {
            lat = doc["lat"] | 0.0f;
            lon = doc["lon"] | 0.0f;
            city = String((const char *)(doc["city"] | ""));
            ok = true;
        }
    }
    http.end();
    return ok;
}

// The custom captive portal. Blocks (like WiFiManager did) until a network is
// joined or the timeout expires -- only on first setup or after a WiFi reset.
// Serves SETUP_PAGE; /scan lists networks; /connect saves creds + PIN + tz and
// tries the join, reporting success so the page can show the right state.
bool runSetupPortal(uint32_t timeoutSec) {
    Serial.println("Opening Clockwise-Setup portal");
    WiFi.mode(WIFI_AP_STA);
    WiFi.softAP("Clockwise-Setup");
    IPAddress apIP = WiFi.softAPIP();
    DNSServer dns;
    dns.start(53, "*", apIP);          // catch-all DNS so any URL pops the portal
    ESP8266WebServer portal(80);
    bool connected = false;

    portal.on("/", [&portal]() { portal.send_P(200, "text/html", SETUP_PAGE); });

    portal.on("/scan", [&portal]() {
        int n = WiFi.scanNetworks();
        String j = "[";
        for (int i = 0; i < n; i++) {
            if (i) j += ",";
            int r = WiFi.RSSI(i);
            int bars = r >= -55 ? 4 : r >= -67 ? 3 : r >= -78 ? 2 : 1;
            String s = WiFi.SSID(i);
            s.replace("\\", "\\\\"); s.replace("\"", "\\\"");
            j += "{\"s\":\"" + s + "\",\"b\":" + bars + ",\"l\":" +
                 (WiFi.encryptionType(i) == ENC_TYPE_NONE ? "0" : "1") + "}";
        }
        j += "]";
        portal.send(200, "application/json", j);
        WiFi.scanDelete();
    });

    portal.on("/connect", HTTP_POST, [&portal, &connected]() {
        String ssid = portal.arg("ssid"), pass = portal.arg("pass");
        String pin = portal.arg("pin"), tz = portal.arg("tz");
        WiFi.begin(ssid.c_str(), pass.c_str());
        uint32_t start = millis();
        bool ok = false;
        while (millis() - start < 12000) {
            if (WiFi.status() == WL_CONNECTED) { ok = true; break; }
            delay(200);
        }
        if (ok) {
            strlcpy(cfg.wifiSsid, ssid.c_str(), sizeof(cfg.wifiSsid));
            strlcpy(cfg.wifiPass, pass.c_str(), sizeof(cfg.wifiPass));
            if (pin.length()) strlcpy(cfg.apiToken, pin.c_str(), sizeof(cfg.apiToken));
            // Only a value that looks like a POSIX rule -- a scripting-off
            // browser posts this empty, and an empty must not wipe a good rule.
            if (tz.length() >= 3) strlcpy(cfg.tzPosix, tz.c_str(), sizeof(cfg.tzPosix));

            // Best-effort approximate location -- see geolocateByIP(). Never
            // blocks setup on failure; the app's location warning banner
            // catches it if this doesn't land.
            float glat, glon; String city;
            bool geoOk = geolocateByIP(glat, glon, city);
            if (geoOk) { cfg.lat = glat; cfg.lon = glon; }

            saveConfig();
            JsonDocument resp;
            resp["ok"] = true;
            resp["geo"] = geoOk;
            if (geoOk) resp["city"] = city;
            String out;
            serializeJson(resp, out);
            portal.send(200, "application/json", out);
            connected = true;
        } else {
            portal.send(200, "application/json", "{\"ok\":false}");
        }
    });

    // Every other path (the phone's captive-portal probe) -> the page.
    portal.onNotFound([&portal, apIP]() {
        portal.sendHeader("Location", "http://" + apIP.toString() + "/", true);
        portal.send(302, "text/plain", "");
    });

    portal.begin();
    uint32_t start = millis();
    while (!connected && (timeoutSec == 0 || millis() - start < timeoutSec * 1000UL)) {
        dns.processNextRequest();
        portal.handleClient();
        yield();
    }
    delay(400);                         // let the final HTTP response flush
    portal.stop();
    dns.stop();
    WiFi.softAPdisconnect(true);
    WiFi.mode(WIFI_STA);
    return connected;
}

// Boot-time connect: saved creds first, the setup portal only if that fails.
bool wifiConnect(uint32_t portalTimeoutSec = 180) {
    if (wifiTryConnect()) return true;
    return runSetupPortal(portalTimeoutSec);
}

void ntpSync() {
    // Never opens the setup portal -- a background 03:00 sync must not hijack
    // the display into AP mode. Just uses whatever connection exists.
    if (!wifiTryConnect(8000)) { Serial.println("NTP: no WiFi, skipped"); logAdd("NTP sync skipped: no WiFi"); return; }
    configTzTime(cfg.tzPosix, "pool.ntp.org", "time.nist.gov");
    Serial.print("NTP: syncing");
    struct tm t;
    for (int i = 0; i < 20; i++) {
        if (getLocalTime(&t, 100) && t.tm_year > 120) {
            char buf[32]; strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S %a", &t);
            Serial.print("\nNTP: "); Serial.println(buf);

            int rh,rm,rs,rdd,rmo,ryr,rdw; bool rpm;
            long driftSec = 999999;   // force a write if RTC read fails or date doesn't match
            if (rtcReadAll(rh,rpm,rm,rs,rdd,rmo,ryr,rdw) &&
                rdd == t.tm_mday && rmo == t.tm_mon + 1 && ryr == t.tm_year + 1900) {
                int rh24 = (rh % 12) + (rpm ? 12 : 0);
                long ntpSec = t.tm_hour * 3600L + t.tm_min * 60 + t.tm_sec;
                long rtcSec = rh24 * 3600L + rm * 60 + rs;
                driftSec = ntpSec - rtcSec;
            }
            const long SYNC_TOLERANCE_SEC = 2;   // RTC crystal drift is tiny -- skip the write if already close enough
            if (labs(driftSec) > SYNC_TOLERANCE_SEC) {
                rtcWriteFull(t.tm_sec, t.tm_min, t.tm_hour, t.tm_wday, t.tm_mday, t.tm_mon + 1, t.tm_year + 1900);
                Serial.printf("NTP: RTC drift %lds, corrected\n", driftSec);
                logAdd("NTP synced, RTC drift " + String(driftSec) + "s, corrected");
            } else {
                Serial.printf("NTP: RTC already accurate (drift %lds), no write\n", driftSec);
                logAdd("NTP synced, RTC already accurate (drift " + String(driftSec) + "s)");
            }
            lastSyncStr = String(buf);
            if (mqtt.connected()) mqtt.publish("clock/lastsync", lastSyncStr.c_str(), true);
            return;
        }
        delay(500); Serial.print(".");
    }
    Serial.println("\nNTP: no time received");
    logAdd("NTP sync failed: no time received");
}

// ── shared config-apply (used by both MQTT clock/config and the local API) ──
void applyConfigJson(const JsonDocument &doc) {
    // Logs which settings changed, not their values (mqttPass/wifiPass are in
    // here too, and even the non-secret fields aren't worth spelling out --
    // this is "what happened", the settings screens already show "what it's
    // set to now"). MQTT's own config-apply path (mqttCallback) shares this
    // function, so this covers changes from HA too, not just the app.
    if (doc.size() > 0) {
        String keys;
        for (JsonPairConst kv : doc.as<JsonObjectConst>()) {
            if (keys.length()) keys += ", ";
            keys += kv.key().c_str();
        }
        logAdd("Config changed: " + keys);
    }
    if (doc["full"].is<int>())       cfg.fullPct     = doc["full"];
    if (doc["dim"].is<int>())        cfg.dimPct      = doc["dim"];
    if (doc["night"].is<int>())      cfg.nightPct    = doc["night"];
    if (doc["fade"].is<int>())       cfg.fadeMs      = doc["fade"];
    if (doc["nightStart"].is<int>()) cfg.nightStart  = doc["nightStart"];
    if (doc["nightEnd"].is<int>())   cfg.nightEnd    = doc["nightEnd"];
    if (doc["sched"].is<bool>())     cfg.schedEnabled = doc["sched"];
    if (doc["autoSync"].is<bool>())  cfg.autoSync     = doc["autoSync"];
    // Changing tz mid-flight leaves the RTC holding a time written under the
    // old rule, so force a fresh NTP write under the new one.
    bool tzChanged = doc["tz"].is<const char*>() &&
                     strcmp(cfg.tzPosix, doc["tz"].as<const char*>()) != 0;
    if (doc["tz"].is<const char*>()) strlcpy(cfg.tzPosix, doc["tz"], sizeof(cfg.tzPosix));
    bool logoChanged = doc["logo"].is<bool>() && cfg.logoOn != doc["logo"].as<bool>();
    if (doc["logo"].is<bool>())      cfg.logoOn       = doc["logo"];
    if (doc["transition"].is<int>()) cfg.transitionMin = constrain((int)doc["transition"], 0, 240);
    // 0 is a valid value here (CIE curve), so it can't share the 100-300 clamp.
    if (doc["gamma"].is<int>()) {
        const int g = doc["gamma"];
        cfg.gammaX100 = (g == 0) ? 0 : constrain(g, 100, 300);
        lastDutyWritten = -1;   // force a re-write: same percent, different duty
    }
    if (doc["dutyFloor"].is<int>()) {
        cfg.dutyFloor = constrain((int)doc["dutyFloor"], 1, 50);
        lastDutyWritten = -1;
    }
    if (doc["mode"].is<int>())  cfg.mode = constrain((int)doc["mode"], 0, 2);
    if (doc["lat"].is<float>()) cfg.lat  = constrain((float)doc["lat"], -90.0f, 90.0f);
    if (doc["lon"].is<float>()) cfg.lon  = constrain((float)doc["lon"], -180.0f, 180.0f);
    // sunLow (legacy, one value) sets both ends; sunDawn/sunDusk override it,
    // so a payload carrying all three still lands on the caller's intent.
    if (doc["sunLow"].is<float>()) {
        const float v = constrain((float)doc["sunLow"], -18.0f, 10.0f);
        cfg.sunDawnDeg = cfg.sunDuskDeg = v;
    }
    // Positive is allowed and useful: it makes the clock wait until the sun is
    // properly up before brightening, rather than starting at first light.
    if (doc["sunDawn"].is<float>()) cfg.sunDawnDeg = constrain((float)doc["sunDawn"], -24.0f, 20.0f);
    if (doc["sunDusk"].is<float>()) cfg.sunDuskDeg = constrain((float)doc["sunDusk"], -24.0f, 20.0f);
    if (doc["sunHigh"].is<float>()) cfg.sunHighDeg = constrain((float)doc["sunHigh"], 2.0f, 70.0f);
    if (doc["sunFull"].is<int>())   cfg.sunFullPct  = constrain((int)doc["sunFull"],  0, 100);
    if (doc["sunNight"].is<int>())  cfg.sunNightPct = constrain((int)doc["sunNight"], 0, 100);
    if (doc["manual"].is<int>()) {
        cfg.manualPct = constrain((int)doc["manual"], 0, 100);
        // Manual mode has no scheduler tick to pick this up, so apply it now.
        if (cfg.mode == MODE_MANUAL) setBrightness(cfg.manualPct);
    }
    // Legacy MQTT/HA clients still send the old boolean instead of `mode`. Only
    // honor it if this payload didn't ALSO set `mode` directly -- otherwise
    // {"mode":2,"sched":false} (sun mode, with sched left at its old value)
    // would silently override mode back to manual right after setting it.
    if (doc["sched"].is<bool>() && !doc["mode"].is<int>()) {
        cfg.mode = doc["sched"] ? MODE_SCHEDULE : MODE_MANUAL;
    }
    cfg.schedEnabled = (cfg.mode != MODE_MANUAL);
    if (doc["oeFreq"].is<int>()) {
        cfg.oeFreq = constrain((int)doc["oeFreq"], 100, 40000);
        analogWriteFreq(cfg.oeFreq);
    }
    // Remember the old broker settings so a change forces a fresh login. Without
    // this, editing the username/password just updates cfg while the existing,
    // already-authenticated session stays up -- so a wrong password appears to
    // "still connect" until the link happens to drop.
    char oldHost[sizeof(cfg.mqttHost)]; strlcpy(oldHost, cfg.mqttHost, sizeof(oldHost));
    char oldUser[sizeof(cfg.mqttUser)]; strlcpy(oldUser, cfg.mqttUser, sizeof(oldUser));
    char oldPass[sizeof(cfg.mqttPass)]; strlcpy(oldPass, cfg.mqttPass, sizeof(oldPass));
    int  oldPort = cfg.mqttPort;
    if (doc["mqttHost"].is<const char*>()) strlcpy(cfg.mqttHost, doc["mqttHost"], sizeof(cfg.mqttHost));
    if (doc["mqttPort"].is<int>())         cfg.mqttPort = doc["mqttPort"];
    if (doc["mqttUser"].is<const char*>()) strlcpy(cfg.mqttUser, doc["mqttUser"], sizeof(cfg.mqttUser));
    if (doc["mqttPass"].is<const char*>()) strlcpy(cfg.mqttPass, doc["mqttPass"], sizeof(cfg.mqttPass));
    if (strcmp(oldHost, cfg.mqttHost) || oldPort != cfg.mqttPort ||
        strcmp(oldUser, cfg.mqttUser) || strcmp(oldPass, cfg.mqttPass)) {
        mqtt.setServer(cfg.mqttHost, cfg.mqttPort);
        mqtt.disconnect();          // drop the old session; mqttReconnect() re-logs-in with the new details (within ~5s)
    }
    if (doc["wifiAlertOn"].is<int>())  cfg.wifiAlertOnS  = constrain((int)doc["wifiAlertOn"],  0, 300);
    if (doc["wifiAlertOff"].is<int>()) cfg.wifiAlertOffS = constrain((int)doc["wifiAlertOff"], 0, 300);
    if (doc["presenceDim"].is<bool>())     cfg.presenceDimEnabled = doc["presenceDim"];
    if (doc["presenceAway"].is<int>())     cfg.presenceAwayPct    = constrain((int)doc["presenceAway"], 0, 100);
    if (doc["presenceTimeout"].is<int>())  cfg.presenceTimeoutMin = constrain((int)doc["presenceTimeout"], 1, 240);
    if (doc["serialDebug"].is<bool>()) {
        cfg.serialDebug = doc["serialDebug"];
        // Leaving debug mode: drop any manual-display state a console session
        // (or stray bytes) may have left set, so the clock face redraws itself
        // on the next tick instead of needing a physical reset to recover.
        if (!cfg.serialDebug) manualMode = false;
    }
    // Re-arm the schedule's anchor to "today" whenever it's (re)enabled or its
    // timing changes -- without this, turning the toggle on with the stale/0
    // anchor already past the interval would fire an immediate restart the
    // very next minute matching the hour, instead of properly waiting out the
    // interval from when the user actually turned it on.
    bool autoRebootWasOff = !cfg.autoRebootEnabled;
    bool autoRebootRearm = false;
    if (doc["autoReboot"].is<bool>()) {
        cfg.autoRebootEnabled = doc["autoReboot"];
        if (cfg.autoRebootEnabled && autoRebootWasOff) autoRebootRearm = true;
    }
    if (doc["autoRebootDays"].is<int>()) {
        cfg.autoRebootIntervalDays = (uint8_t)constrain((int)doc["autoRebootDays"], 1, 365);
        autoRebootRearm = true;
    }
    if (doc["autoRebootHour"].is<int>()) {
        cfg.autoRebootHour = (uint8_t)constrain((int)doc["autoRebootHour"], 0, 23);
        autoRebootRearm = true;
    }
    if (autoRebootRearm) {
        int h, m, s, dd, mo, yr, dw; bool pm;
        if (rtcReadAll(h, pm, m, s, dd, mo, yr, dw)) {
            cfg.autoRebootAnchorDay = daysFromCivil(yr, mo, dd);
        }
    }
    saveConfig();
    if (tzChanged && WiFi.status() == WL_CONNECTED) ntpSync();

    // With the scheduler on, let it decide from the current hour rather than
    // snapping to the daytime level -- otherwise saving config at night would
    // blind you until the next tick.
    previewHoldUntil = 0;   // settings saved -- the schedule is authoritative again
    int h,m,s,dd,mo,yr,dw; bool pm;
    bool rtcOk = rtcReadAll(h,pm,m,s,dd,mo,yr,dw);
    if (cfg.mode != MODE_MANUAL && rtcOk) {
        updateSchedule((h % 12) + (pm ? 12 : 0), m, yr, mo, dd, true);   // fade -- smooth transition when switching modes
    } else {
        // Fade here too, for the same smooth transition switching *into*
        // Manual mode. Harmless when this runs after a normal slider
        // drag-release: brightness already tracks the finger via the live
        // endpoint, so the fade's start and end duty are equal and nothing
        // visibly changes.
        beginFade(cfg.manualPct);
    }

    // The logo is drawn as part of the frame, so unlike brightness (which is
    // just PWM duty) it only changes on a redraw. Redraw now instead of making
    // the user wait up to a second for the next tick.
    if (logoChanged && rtcOk && !manualMode) {
        renderAll(h, m, dd, mo, yr, (dw == 0) ? 7 : dw);
    }
}

// ── mDNS — lets the app find this clock on the LAN without MQTT ──
void startMDNS() {
    mdnsHost = "clockwise-" + String(ESP.getChipId(), HEX);
    if (MDNS.begin(mdnsHost)) {
        MDNS.addService("http", "tcp", 80);
        MDNS.addServiceTxt("http", "tcp", "name", cfg.deviceName);
        MDNS.addServiceTxt("http", "tcp", "fw", FW_VERSION);
        Serial.printf("mDNS: %s.local\n", mdnsHost.c_str());
    } else {
        Serial.println("mDNS start failed");
    }
}

// ── local HTTP/JSON API — app talks to this directly over LAN, MQTT not required ──
bool apiAuthOK() {
    if (strlen(cfg.apiToken) == 0) return true;   // no PIN set yet -- open until user sets one
    return httpServer.header("X-Auth-Token") == cfg.apiToken;
}
void apiUnauthorized() { httpServer.send(401, "application/json", "{\"error\":\"unauthorized\"}"); }

void apiInfo() {
    JsonDocument doc;
    doc["name"]         = cfg.deviceName;
    doc["fw"]           = FW_VERSION;
    doc["ip"]           = WiFi.localIP().toString();
    doc["chipId"]       = String(ESP.getChipId(), HEX);
    doc["authRequired"] = strlen(cfg.apiToken) > 0;
    // Why the ESP last rebooted -- e.g. "Software Watchdog", "Exception",
    // "Hardware Watchdog", "Power on". Diagnostic for the freeze-then-recover
    // pattern seen at high brightness: this is read once at boot (below) and
    // reported every time /api/info is called, so whatever it was survives
    // long enough to actually check after the fact.
    doc["lastResetReason"] = ESP.getResetReason();
    // Static device-health facts -- don't change while running, so they live
    // in /api/info (fetched occasionally) rather than /api/state (polled
    // every 4s).
    doc["cpuFreqMHz"]      = ESP.getCpuFreqMHz();
    doc["sketchSize"]      = ESP.getSketchSize();
    doc["freeSketchSpace"] = ESP.getFreeSketchSpace();
    doc["flashChipSize"]   = ESP.getFlashChipRealSize();
    String out; serializeJson(doc, out);
    httpServer.send(200, "application/json", out);
}

void apiState() {
    if (!apiAuthOK()) return apiUnauthorized();
    JsonDocument doc;
    // The clock's own time, straight off the RTC -- the app shows this rather
    // than the phone's clock, so a drifted/unsynced clock is actually visible.
    int h12, m, s, dd, mo, yr, dow; bool pm;
    if (rtcReadAll(h12, pm, m, s, dd, mo, yr, dow)) {
        int h24 = (h12 % 12) + (pm ? 12 : 0);
        char t[16]; snprintf(t, sizeof(t), "%02d:%02d:%02d", h24, m, s);
        char d[16]; snprintf(d, sizeof(d), "%04d-%02d-%02d", yr, mo, dd);
        doc["time"]  = t;
        doc["date"]  = d;
        doc["dow"]   = dow & 0x07;   // 0=Sun..6=Sat, as written (datasheet 4.2)
        doc["rtcOk"] = true;
        // Sun position, so the app can show what sun mode is reacting to
        // rather than the user having to take it on faith.
        doc["sunElev"] = solarElevation(yr, mo, dd, h24, m);
        doc["sunPct"]  = sunPct(yr, mo, dd, h24, m);
    } else {
        doc["rtcOk"] = false;
    }
    doc["brightness"]    = brightness;
    doc["presence"]      = presenceDetected;
    doc["sensorConnected"] = radar.connected();
    doc["sensorMoving"]    = radar.isMoving();
    doc["sensorDistCm"]    = radar.distanceCm();
    doc["presenceDimActive"] = presenceDimActive;
    doc["lastSync"]      = lastSyncStr;
    doc["rssi"]          = WiFi.RSSI();
    doc["uptime"]        = millis() / 60000;
    doc["mqttConnected"] = mqtt.connected();
    // So the app can show a persistent "manual mode active" warning -- entered
    // via a debug command, it has no auto-timeout, so this is the only way the
    // app would otherwise know the display has stopped showing the real time.
    doc["manualMode"] = manualMode;
    // Rough device-health readout, closest ESP8266 equivalent to a PC's
    // resource meters -- there's no real task scheduler here to measure a
    // "CPU load %" against, so free heap / fragmentation (the thing that
    // actually causes long-uptime crashes) and the loop rate (drops if
    // something's blocking) stand in for it.
    doc["freeHeap"]     = ESP.getFreeHeap();
    doc["heapFragPct"]  = ESP.getHeapFragmentation();
    doc["loopHz"]        = lastLoopHz;
    // Today's UTC offset for cfg.tzPosix, DST already resolved. Reported so the
    // app can judge drift without keeping its own copy of the zone name -- a
    // fresh install, or a second phone, would otherwise have to compare against
    // ITS own timezone and call a correct clock wrong.
    doc["tzOff"]         = currentTzOffsetHours();
    String out; serializeJson(doc, out);
    httpServer.send(200, "application/json", out);
}

void apiConfigGet() {
    if (!apiAuthOK()) return apiUnauthorized();
    JsonDocument doc;
    doc["name"]       = cfg.deviceName;
    doc["mqttHost"]   = cfg.mqttHost;
    doc["mqttPort"]   = cfg.mqttPort;
    doc["mqttUser"]   = cfg.mqttUser;
    doc["full"]       = cfg.fullPct;
    doc["dim"]        = cfg.dimPct;
    doc["night"]      = cfg.nightPct;
    doc["nightStart"] = cfg.nightStart;
    doc["nightEnd"]   = cfg.nightEnd;
    doc["fade"]       = cfg.fadeMs;
    doc["sched"]      = cfg.schedEnabled;
    doc["autoSync"]   = cfg.autoSync;
    doc["oeFreq"]     = cfg.oeFreq;
    doc["logo"]       = cfg.logoOn;
    doc["transition"] = cfg.transitionMin;
    doc["gamma"]      = cfg.gammaX100;
    doc["dutyFloor"]  = cfg.dutyFloor;
    doc["mode"]       = cfg.mode;
    doc["lat"]        = cfg.lat;
    doc["lon"]        = cfg.lon;
    doc["sunDawn"]    = cfg.sunDawnDeg;
    doc["sunDusk"]    = cfg.sunDuskDeg;
    doc["sunLow"]     = cfg.sunDuskDeg;   // legacy alias, kept so old clients keep working
    doc["sunHigh"]    = cfg.sunHighDeg;
    doc["sunFull"]    = cfg.sunFullPct;
    doc["sunNight"]   = cfg.sunNightPct;
    doc["manual"]     = cfg.manualPct;
    doc["tz"]         = cfg.tzPosix;
    doc["wifiAlertOn"]  = cfg.wifiAlertOnS;
    doc["wifiAlertOff"] = cfg.wifiAlertOffS;
    doc["presenceDim"]     = cfg.presenceDimEnabled;
    doc["presenceAway"]    = cfg.presenceAwayPct;
    doc["presenceTimeout"] = cfg.presenceTimeoutMin;
    doc["serialDebug"]     = cfg.serialDebug;
    doc["autoReboot"]      = cfg.autoRebootEnabled;
    doc["autoRebootDays"]  = cfg.autoRebootIntervalDays;
    doc["autoRebootHour"]  = cfg.autoRebootHour;
    String out; serializeJson(doc, out);
    httpServer.send(200, "application/json", out);
}

void apiConfigPost() {
    if (!apiAuthOK()) return apiUnauthorized();
    JsonDocument doc;
    if (deserializeJson(doc, httpServer.arg("plain"))) { httpServer.send(400, "application/json", "{\"error\":\"bad json\"}"); return; }
    applyConfigJson(doc);
    httpServer.send(200, "application/json", "{\"ok\":true}");
}

void apiNamePost() {
    if (!apiAuthOK()) return apiUnauthorized();
    JsonDocument doc;
    if (deserializeJson(doc, httpServer.arg("plain")) || !doc["name"].is<const char*>()) {
        httpServer.send(400, "application/json", "{\"error\":\"bad json\"}"); return;
    }
    strlcpy(cfg.deviceName, doc["name"], sizeof(cfg.deviceName));
    saveConfig();
    MDNS.addServiceTxt("http", "tcp", "name", cfg.deviceName);
    httpServer.send(200, "application/json", "{\"ok\":true}");
}

// Live brightness while the user drags the app's slider.
//
// Deliberately does NOT save to flash and does NOT fade: dragging fires many
// times a second, and /api/config would mean a LittleFS write per update --
// slow enough to make the slider lag, and needless wear on the flash. The app
// sends the final value to /api/config once on release to persist it.
void apiBrightnessPost() {
    if (!apiAuthOK()) return apiUnauthorized();
    JsonDocument doc;
    if (deserializeJson(doc, httpServer.arg("plain")) || !doc["v"].is<int>()) {
        httpServer.send(400, "application/json", "{\"error\":\"bad json\"}"); return;
    }
    cancelFade();   // cancel any scheduler fade -- the user is in charge now
    previewHoldUntil = millis() + PREVIEW_HOLD_MS;
    setBrightness(doc["v"]);
    httpServer.send(200, "application/json", "{\"ok\":true}");
}

void apiCmdPost() {
    if (!apiAuthOK()) return apiUnauthorized();
    JsonDocument doc;
    if (deserializeJson(doc, httpServer.arg("plain"))) { httpServer.send(400, "application/json", "{\"error\":\"bad json\"}"); return; }
    String c = doc["cmd"] | "";
    if (c == "reboot") { httpServer.send(200, "application/json", "{\"ok\":true}"); delay(200); ESP.restart(); return; }
    if (c == "sync") ntpSync();
    httpServer.send(200, "application/json", "{\"ok\":true}");
}

// ── radar API -- live data is free (cached fields, no serial round-trip);
// config/calibration calls are blocking (they talk to the sensor over UART
// and wait for its ACK) and are meant for a settings screen, not polling. ──
void apiSensorGet() {
    if (!apiAuthOK()) return apiUnauthorized();
    JsonDocument doc;
    doc["connected"]   = radar.connected();
    doc["presence"]    = radar.presence();
    doc["moving"]      = radar.isMoving();
    doc["still"]       = radar.isStill();
    doc["distanceCm"]  = radar.distanceCm();
    doc["engineering"] = radar.haveEnergyGates();
    // Diagnostics: is the module transmitting at all, regardless of parsing?
    doc["bytesReceived"]  = radar.bytesReceived();
    doc["msSinceLastByte"] = radar.lastByteMs() == 0 ? -1
                              : (long)(millis() - radar.lastByteMs());
    if (radar.haveEnergyGates()) {
        JsonArray me = doc["motionEnergyDb"].to<JsonArray>();
        JsonArray xe = doc["microEnergyDb"].to<JsonArray>();
        for (uint8_t i = 0; i < 16; i++) {
            me.add(radar.motionEnergyDb(i));
            xe.add(radar.microEnergyDb(i));
        }
    }
    String out; serializeJson(doc, out);
    httpServer.send(200, "application/json", out);
}

// Reads the sensor's own settings (they live on ITS flash, not cfg). Kept
// deliberately LIGHT: only a handful of round-trips, NOT the 32 per-gate
// thresholds. Reading all 34 params meant ~34 blocking serial exchanges while
// the single-threaded web server was frozen -- long enough to trip the app's
// timeout (the 503 the user saw) and, worse, to fight the live engineering
// stream. The per-gate thresholds are rarely needed and can be a separate
// on-demand call later; the common settings screen just needs these few.
//
// enableConfig pauses the sensor's stream. Whatever happens, endConfig() runs
// before returning (it retries internally) so the sensor is never left stuck
// in config mode -- that stranding is exactly what silenced it before.
void apiSensorConfigGet() {
    if (!apiAuthOK()) return apiUnauthorized();
    // Permissive, deliberately: enableConfig's ACK is hard to catch amid the
    // dense engineering stream, so it often returns false EVEN THOUGH the
    // sensor did enter config mode (proven by the mode switch working when its
    // commands are sent unconditionally). So we don't gate on its return --
    // we enter best-effort, then just try the reads. Each read has its own
    // ACK check; if we're genuinely not in config mode they simply fail and
    // that field is omitted. endConfig always runs to resume streaming. This
    // mirrors how the working ESPHome component treats these responses.
    radar.enableConfig(2500);
    JsonDocument doc;
    String fw;
    bool any = false;
    if (radar.readFirmwareVersion(fw))              { doc["firmware"] = fw; any = true; }
    float maxDist;
    if (radar.readMaxDistanceMeters(maxDist))       { doc["maxDistanceM"] = maxDist; any = true; }
    uint16_t delaySec;
    if (radar.readDisappearDelaySec(delaySec))      { doc["disappearDelaySec"] = delaySec; any = true; }
    uint8_t interference;
    if (radar.readPowerInterference(interference))  { doc["powerInterference"] = interference; any = true; }
    doc["engineering"] = cfg.sensorEngineering;
    radar.endConfig(300);   // always resume streaming
    if (!any) {   // nothing read back -> the sensor really isn't answering
        httpServer.send(504, "application/json", "{\"error\":\"sensor not responding\"}");
        return;
    }
    String out; serializeJson(doc, out);
    httpServer.send(200, "application/json", out);
}

// The 16 per-gate motion + 16 micro-motion thresholds, on demand. Separate
// from the light config read because it's 32 serial round-trips -- fine for a
// deliberate "load advanced tuning" tap, too heavy to fold into the settings
// screen opening. Same permissive enter/always-exit pattern.
void apiSensorThresholdsGet() {
    if (!apiAuthOK()) return apiUnauthorized();
    radar.enableConfig(2500);
    JsonDocument doc;
    JsonArray mt = doc["motionThresholdDb"].to<JsonArray>();
    JsonArray xt = doc["microThresholdDb"].to<JsonArray>();
    bool any = false;
    for (uint8_t i = 0; i < 16; i++) {
        float v;
        if (radar.readMotionThresholdDb(i, v)) { mt.add(v); any = true; } else mt.add(nullptr);
        if (radar.readMicroThresholdDb(i, v))  { xt.add(v); any = true; } else xt.add(nullptr);
    }
    radar.endConfig(300);
    if (!any) { httpServer.send(504, "application/json", "{\"error\":\"sensor not responding\"}"); return; }
    String out; serializeJson(doc, out);
    httpServer.send(200, "application/json", out);
}

// Applies whichever fields are present; only touches the ESP's own flash
// (cfg.json) if "engineering" is included and actually changes -- everything
// else (thresholds, max distance, delay) lives on the sensor's own flash and
// isn't written there unless "save":true is also sent.
void apiSensorConfigPost() {
    if (!apiAuthOK()) return apiUnauthorized();
    JsonDocument doc;
    if (deserializeJson(doc, httpServer.arg("plain"))) { httpServer.send(400, "application/json", "{\"error\":\"bad json\"}"); return; }

    if (doc["engineering"].is<bool>()) {
        bool eng = doc["engineering"];
        if (eng != cfg.sensorEngineering) { cfg.sensorEngineering = eng; saveConfig(); }
    }

    // Permissive like the config read: enter best-effort, write, always exit.
    radar.enableConfig(2500);
    if (doc["engineering"].is<bool>())        radar.setOutputMode(cfg.sensorEngineering);
    if (doc["maxDistanceM"].is<float>())      radar.setMaxDistanceMeters(doc["maxDistanceM"]);
    if (doc["disappearDelaySec"].is<int>())   radar.setDisappearDelaySec(doc["disappearDelaySec"]);
    if (doc["motionThresholdDb"].is<JsonArray>()) {
        JsonArray a = doc["motionThresholdDb"];
        uint8_t i = 0;
        for (JsonVariant v : a) { if (i >= 16) break; radar.setMotionThresholdDb(i++, v.as<float>()); }
    }
    if (doc["microThresholdDb"].is<JsonArray>()) {
        JsonArray a = doc["microThresholdDb"];
        uint8_t i = 0;
        for (JsonVariant v : a) { if (i >= 16) break; radar.setMicroThresholdDb(i++, v.as<float>()); }
    }
    bool saved = true;
    if (doc["save"] | false) saved = radar.saveParameters();
    radar.endConfig();
    String out = String("{\"ok\":true,\"saved\":") + (saved ? "true" : "false") + "}";
    httpServer.send(200, "application/json", out);
}

// Single-gate threshold write, for the app's per-gate tuning screen. Kept
// separate from apiSensorConfigPost's array form -- that one writes gates
// positionally from index 0, so sending a short array to change just one
// gate would silently zero out every gate before it. This takes an explicit
// gate index instead, so touching gate 9 can never accidentally clobber
// gates 0-8.
// Oldest-first array of recent event strings -- see logAdd().
void apiLogGet() {
    if (!apiAuthOK()) return apiUnauthorized();
    JsonDocument doc;
    JsonArray a = doc["log"].to<JsonArray>();
    int start = (logCount < LOG_CAP) ? 0 : logHead;
    for (int i = 0; i < logCount; i++) a.add(logBuf[(start + i) % LOG_CAP]);
    String out; serializeJson(doc, out);
    httpServer.send(200, "application/json", out);
}

void apiSensorGatePost() {
    if (!apiAuthOK()) return apiUnauthorized();
    JsonDocument doc;
    if (deserializeJson(doc, httpServer.arg("plain")) || !doc["gate"].is<int>()) {
        httpServer.send(400, "application/json", "{\"error\":\"bad json\"}"); return;
    }
    int gate = doc["gate"];
    if (gate < 0 || gate > 15) {
        httpServer.send(400, "application/json", "{\"error\":\"gate must be 0-15\"}"); return;
    }
    radar.enableConfig(2500);
    bool ok = true;
    if (doc["motionThresholdDb"].is<float>())
        ok &= radar.setMotionThresholdDb((uint8_t)gate, doc["motionThresholdDb"]);
    if (doc["microThresholdDb"].is<float>())
        ok &= radar.setMicroThresholdDb((uint8_t)gate, doc["microThresholdDb"]);
    bool saved = true;
    if (doc["save"] | false) saved = radar.saveParameters();
    radar.endConfig();
    String out = String("{\"ok\":") + (ok ? "true" : "false") +
                 ",\"saved\":" + (saved ? "true" : "false") + "}";
    httpServer.send(200, "application/json", out);
}

// Blocking for the whole calibration run (the sensor must stay in config mode
// throughout, or it stops) -- capped at 120s. A deliberate one-off setup
// action, same tradeoff as OTA already blocking the clock.
//
// Raised from the original 20s (then 60s): the reference example this library
// ships polls calibrationProgress() with NO time cap at all (just until 100%
// or a real comms failure), because how long the sensor's own calibration
// takes isn't something the host can predict -- it depends on the room. Both
// 20s and 60s cut off runs that were still legitimately progressing (seen
// stuck at 14%, then 75%, with no communication errors at all -- the
// consecutive-miss counter below already independently guards against a truly
// dead link, so this outer cap only needs to be a generous backstop against
// an endless run, not a tight budget).
void apiSensorCalibratePost() {
    if (!apiAuthOK()) return apiUnauthorized();
    JsonDocument doc;
    deserializeJson(doc, httpServer.arg("plain"));   // optional body, ok if empty/absent
    uint8_t trig  = doc["trigger"] | 3;
    uint8_t hold  = doc["hold"]    | 3;
    uint8_t micro = doc["micro"]   | 3;

    // Permissive: enter config + start best-effort, then let the progress
    // polling be the real signal. If calibration never actually started,
    // calibrationProgress() fails immediately and we report not-ok.
    //
    // A single missed poll must NOT abort an otherwise-healthy run: the sensor
    // keeps calibrating on its own regardless of whether the ESP heard the
    // last status reply, so one dropped/garbled byte on a routine 500ms poll
    // used to throw away real progress (e.g. stopping at "14%" when the
    // sensor was still calibrating fine) instead of just retrying. Only give
    // up early if several polls in a row fail -- that's a genuinely dead link,
    // not a transient miss.
    logAdd("Calibration started (trigger=" + String(trig) + " hold=" + String(hold) + " micro=" + String(micro) + ")");
    radar.enableConfig(2500);
    radar.startCalibration(trig, hold, micro);
    uint8_t percent = 0;
    bool gotProgress = false;
    uint8_t consecutiveMisses = 0;
    unsigned long start = millis();
    while (millis() - start < 120000) {
        if (radar.calibrationProgress(percent)) {
            gotProgress = true;
            consecutiveMisses = 0;
            if (percent >= 100) break;
        } else if (++consecutiveMisses >= 4) {
            break;   // ~2s of consecutive silence -- treat as genuinely gone
        }
        delay(500);
    }
    // Only meaningful once calibration actually finished -- ask while still in
    // config mode, before endConfig() resumes the data stream.
    bool interference = false;
    uint16_t interferenceGates = 0;
    bool gotInterference = false;
    if (percent >= 100) {
        gotInterference = radar.readCalibrationInterference(interference, interferenceGates);
    }
    radar.endConfig();
    if (!gotProgress) {
        logAdd("Calibration failed: sensor not responding");
        httpServer.send(504, "application/json", "{\"error\":\"sensor not responding\"}");
        return;
    }
    logAdd("Calibration " + String(percent >= 100 ? "complete" : "stopped") + " at " + String(percent) + "%" +
           (gotInterference && interference ? " (interference detected)" : ""));
    JsonDocument resp;
    resp["ok"] = percent >= 100;
    resp["percent"] = percent;
    if (gotInterference) {
        resp["interference"] = interference;
        if (interference) resp["interferenceGates"] = interferenceGates;
    }
    String out;
    serializeJson(resp, out);
    httpServer.send(200, "application/json", out);
}

void apiSensorAutoGainPost() {
    if (!apiAuthOK()) return apiUnauthorized();
    radar.enableConfig(2500);
    radar.startAutoGain();
    bool done = radar.autoGainDone(5000);
    radar.endConfig();
    String out = String("{\"ok\":") + (done ? "true" : "false") + "}";
    httpServer.send(200, "application/json", out);
}

// ── MQTT (optional overlay -- app/local API work without it) ──
void mqttPublishState();   // fwd decl -- callback re-publishes after a change

const char *modeName(int m) {
    return m == MODE_SUN ? "sun" : m == MODE_SCHEDULE ? "schedule" : "manual";
}

void mqttCallback(char *topic, byte *payload, unsigned int len) {
    String msg; msg.reserve(len);
    for (unsigned int i = 0; i < len; i++) msg += (char)payload[i];
    String t(topic);

    if (t == "clock/cmd") {
        if (msg == "sync")          ntpSync();
        else if (msg == "reboot")   { mqtt.publish("clock/status", "offline", true); delay(200); ESP.restart(); }
    } else if (t == "clock/config") {
        JsonDocument doc;
        if (!deserializeJson(doc, msg)) applyConfigJson(doc);
    }
    // Per-entity command topics for Home Assistant's number/select/switch
    // entities -- each carries a bare value, wrapped into a config-apply here so
    // HA needs no JSON templates. Echo state back so HA reflects the change.
    else if (t == "clock/set/brightness") {
        JsonDocument d; d["mode"] = MODE_MANUAL; d["manual"] = msg.toInt();
        applyConfigJson(d); mqttPublishState();
    } else if (t == "clock/set/mode") {
        int m = msg == "sun" ? MODE_SUN : msg == "schedule" ? MODE_SCHEDULE : MODE_MANUAL;
        JsonDocument d; d["mode"] = m; applyConfigJson(d); mqttPublishState();
    } else if (t == "clock/set/logo") {
        JsonDocument d; d["logo"] = (msg == "ON"); applyConfigJson(d); mqttPublishState();
    } else if (t == "clock/set/dim") {
        JsonDocument d; d["presenceDim"] = (msg == "ON"); applyConfigJson(d); mqttPublishState();
    }
}

void mqttPublishState() {
    mqtt.publish("clock/status",     "online", true);
    mqtt.publish("clock/brightness", String(brightness).c_str());
    mqtt.publish("clock/mode",       modeName(cfg.mode), true);
    mqtt.publish("clock/logo",       cfg.logoOn ? "ON" : "OFF", true);
    mqtt.publish("clock/dim",        cfg.presenceDimEnabled ? "ON" : "OFF", true);
    // Radar signals -- the useful ones for automations (the raw energy gates
    // stay in the app; see the plan). distance is metres, blanked when clear.
    mqtt.publish("clock/presence",   presenceDetected ? "ON" : "OFF");
    mqtt.publish("clock/moving",     radar.isMoving() ? "ON" : "OFF");
    mqtt.publish("clock/still",      radar.isStill() ? "ON" : "OFF");
    mqtt.publish("clock/distance",   presenceDetected ? String(radar.distanceCm() / 100.0, 2).c_str() : "0");
    mqtt.publish("clock/lastsync",   lastSyncStr.c_str(), true);
    mqtt.publish("clock/rssi",       String(WiFi.RSSI()).c_str());
    mqtt.publish("clock/uptime",     String(millis() / 60000).c_str());
    mqtt.publish("clock/freeheap",   String(ESP.getFreeHeap()).c_str());
    // The live time/date/day the physical display is showing -- what the HA
    // clock-face card renders so it stays in sync with the real clock. Time is
    // 12-hour (no leading zero on the hour) to match the display; date is
    // YYYY-MM-DD; dow is 1=Mon..7=Sun. Read straight off the RTC.
    {
        int h,m,s,dd,mo,yr,dw; bool pm;
        if (rtcReadAll(h,pm,m,s,dd,mo,yr,dw)) {
            char tb[8];  snprintf(tb, sizeof(tb), "%d:%02d", h, m);          // h is already 12h (1-12)
            char db[12]; snprintf(db, sizeof(db), "%04d-%02d-%02d", yr, mo, dd);
            mqtt.publish("clock/time", tb, true);
            mqtt.publish("clock/date", db, true);
            mqtt.publish("clock/dow",  String((dw == 0) ? 7 : dw).c_str(), true);   // 1=Mon..7=Sun
            mqtt.publish("clock/ampm", pm ? "PM" : "AM", true);
        }
    }
    mqtt.publish("clock/ip",         WiFi.localIP().toString().c_str(), true);
    mqtt.publish("clock/fw",         FW_VERSION, true);
}

// ── Home Assistant MQTT auto-discovery ──
// One retained config message per entity, under homeassistant/.../config, so
// HA builds the whole "Clockwise" device by itself -- no manual YAML. Sent on
// every (re)connect; retained so HA still gets them if it connects later.
// Abbreviated keys (stat_t, cmd_t, dev_cla, ...) keep each message small.
void publishDisc(const char *comp, const char *obj, const String &body) {
    String chip = String(ESP.getChipId(), HEX);
    String base = "clockwise_" + chip;
    String topic = "homeassistant/" + String(comp) + "/" + base + "/" + obj + "/config";
    String dev = "\"dev\":{\"ids\":[\"" + base + "\"],\"name\":\"" + String(cfg.deviceName) +
                 "\",\"mdl\":\"Clockwise\",\"mf\":\"gourav\",\"sw\":\"" + FW_VERSION + "\"}";
    String payload = "{" + body +
                     ",\"uniq_id\":\"" + base + "_" + obj + "\"" +
                     ",\"obj_id\":\"clockwise_" + String(obj) + "\"" +   // deterministic entity_id: <domain>.clockwise_<obj>, so the card can find it
                     ",\"avty_t\":\"clock/status\",\"pl_avail\":\"online\",\"pl_not_avail\":\"offline\"," +
                     dev + "}";
    mqtt.publish(topic.c_str(), payload.c_str(), true);
}

void publishDiscovery() {
    // radar
    publishDisc("binary_sensor", "presence", "\"name\":\"Presence\",\"stat_t\":\"clock/presence\",\"dev_cla\":\"occupancy\",\"pl_on\":\"ON\",\"pl_off\":\"OFF\"");
    publishDisc("binary_sensor", "moving",   "\"name\":\"Moving\",\"stat_t\":\"clock/moving\",\"dev_cla\":\"motion\",\"pl_on\":\"ON\",\"pl_off\":\"OFF\"");
    publishDisc("binary_sensor", "still",    "\"name\":\"Still present\",\"stat_t\":\"clock/still\",\"pl_on\":\"ON\",\"pl_off\":\"OFF\"");
    publishDisc("sensor",        "distance", "\"name\":\"Distance\",\"stat_t\":\"clock/distance\",\"unit_of_meas\":\"m\",\"dev_cla\":\"distance\"");
    // clock controls
    publishDisc("number", "brightness", "\"name\":\"Brightness\",\"stat_t\":\"clock/brightness\",\"cmd_t\":\"clock/set/brightness\",\"min\":0,\"max\":100,\"unit_of_meas\":\"%\",\"ic\":\"mdi:brightness-6\"");
    publishDisc("select", "mode",       "\"name\":\"Mode\",\"stat_t\":\"clock/mode\",\"cmd_t\":\"clock/set/mode\",\"options\":[\"manual\",\"schedule\",\"sun\"]");
    publishDisc("switch", "logo",       "\"name\":\"Logo LED\",\"stat_t\":\"clock/logo\",\"cmd_t\":\"clock/set/logo\",\"pl_on\":\"ON\",\"pl_off\":\"OFF\",\"ic\":\"mdi:led-on\"");
    publishDisc("switch", "dim",        "\"name\":\"Dim when empty\",\"stat_t\":\"clock/dim\",\"cmd_t\":\"clock/set/dim\",\"pl_on\":\"ON\",\"pl_off\":\"OFF\"");
    // buttons
    publishDisc("button", "sync",   "\"name\":\"Sync time\",\"cmd_t\":\"clock/cmd\",\"pl_prs\":\"sync\",\"ic\":\"mdi:clock-check\"");
    publishDisc("button", "reboot", "\"name\":\"Reboot\",\"cmd_t\":\"clock/cmd\",\"pl_prs\":\"reboot\",\"dev_cla\":\"restart\"");
    // diagnostics
    publishDisc("binary_sensor", "online",  "\"name\":\"Online\",\"stat_t\":\"clock/status\",\"dev_cla\":\"connectivity\",\"pl_on\":\"online\",\"pl_off\":\"offline\",\"ent_cat\":\"diagnostic\"");
    publishDisc("sensor", "rssi",     "\"name\":\"WiFi signal\",\"stat_t\":\"clock/rssi\",\"unit_of_meas\":\"dBm\",\"dev_cla\":\"signal_strength\",\"ent_cat\":\"diagnostic\"");
    publishDisc("sensor", "uptime",   "\"name\":\"Uptime\",\"stat_t\":\"clock/uptime\",\"unit_of_meas\":\"min\",\"ent_cat\":\"diagnostic\"");
    publishDisc("sensor", "freeheap", "\"name\":\"Free memory\",\"stat_t\":\"clock/freeheap\",\"unit_of_meas\":\"B\",\"ent_cat\":\"diagnostic\"");
    publishDisc("sensor", "resetreason", "\"name\":\"Last restart reason\",\"stat_t\":\"clock/resetreason\",\"ent_cat\":\"diagnostic\"");
    // The clock's own displayed time/date/day -- read by the custom clock-face
    // card. Diagnostic category so they don't clutter the main device view.
    publishDisc("sensor", "time", "\"name\":\"Displayed time\",\"stat_t\":\"clock/time\",\"ent_cat\":\"diagnostic\"");
    publishDisc("sensor", "date", "\"name\":\"Displayed date\",\"stat_t\":\"clock/date\",\"ent_cat\":\"diagnostic\"");
    publishDisc("sensor", "dow",  "\"name\":\"Day of week\",\"stat_t\":\"clock/dow\",\"ent_cat\":\"diagnostic\"");
}

unsigned long lastMqttAttempt = 0;

void mqttReconnect() {
    if (strlen(cfg.mqttHost) == 0) return;         // no broker configured yet
    if (WiFi.status() != WL_CONNECTED) return;
    if (millis() - lastMqttAttempt < 5000) return;
    lastMqttAttempt = millis();

    mqtt.setServer(cfg.mqttHost, cfg.mqttPort);
    Serial.printf("MQTT: connecting to %s:%d...\n", cfg.mqttHost, cfg.mqttPort);
    bool ok = strlen(cfg.mqttUser) > 0
        ? mqtt.connect("clockwise", cfg.mqttUser, cfg.mqttPass, "clock/status", 0, true, "offline")
        : mqtt.connect("clockwise", "clock/status", 0, true, "offline");
    if (ok) {
        mqtt.subscribe("clock/cmd");
        mqtt.subscribe("clock/config");
        mqtt.subscribe("clock/set/brightness");
        mqtt.subscribe("clock/set/mode");
        mqtt.subscribe("clock/set/logo");
        mqtt.subscribe("clock/set/dim");
        mqtt.publish("clock/resetreason", ESP.getResetReason().c_str(), true);
        publishDiscovery();   // announce all entities to Home Assistant (retained)
        mqttPublishState();
    }
}

unsigned long lastTick = 0;
unsigned long lastMqttPublish = 0;

bool btnPressed  = false;
unsigned long btnPressStart = 0;
// Whole seconds the button has been held, capped at BTN_ABORT. Drives both
// what the display shows and which tier fires on release.
int  btnHeldSecs = 0;

void apiDebugCmdPost();   // defined below setup(), which registers it as a route

// Event callbacks, not polling -- these fire on the actual connect/drop
// rather than needing a periodic WiFi.status() check added somewhere. Purely
// additive: ESP8266's own auto-reconnect already handles the reconnect
// itself, this only logs it.
WiFiEventHandler wifiGotIpHandler, wifiDisconnectedHandler;

void setup() {
    Serial.begin(115200); delay(300);
    radar.begin(Serial);
    pinMode(PIN_SDI, OUTPUT); pinMode(PIN_CLK, OUTPUT);
    pinMode(PIN_LE, OUTPUT);  pinMode(PIN_OE, OUTPUT);
    pinMode(PIN_BUTTON, INPUT_PULLUP);   // idle HIGH, pressed pulls it to GND
    analogWriteRange(1023); analogWriteFreq(cfg.oeFreq); setBrightness(brightness);
    Wire.begin(PIN_SDA, PIN_SCL); Wire.setClock(100000); delay(100);

    loadConfig();
    wifiGotIpHandler = WiFi.onStationModeGotIP([](const WiFiEventStationModeGotIP &e) {
        logAdd("WiFi connected, IP " + e.ip.toString());
    });
    wifiDisconnectedHandler = WiFi.onStationModeDisconnected([](const WiFiEventStationModeDisconnected &e) {
        logAdd("WiFi disconnected (reason " + String((int)e.reason) + ")");
    });
    lastPresenceMs = millis();   // grace period -- don't dim before the radar's had a chance to see anyone
    brightness = cfg.manualPct;
    setBrightness(brightness);
    mqtt.setCallback(mqttCallback);
    mqtt.setBufferSize(768);   // HA discovery configs (with the device block) are bigger than the 256-byte default

    // Push the desired report mode to the radar right away, for the common
    // case where it's already up. If it isn't (the module can take longer to
    // boot than the clock does, or hasn't been plugged in yet at this exact
    // moment), loop() keeps retrying periodically -- see the radar mode-sync
    // check below, which also re-applies this after the sensor reconnects
    // from a reset later, not just once at startup.
    // Sensor mode isn't set here: the module usually isn't finished booting
    // when the clock reaches this point, so a switch now would just fail. The
    // periodic check in loop() applies it once the sensor is actually up and
    // streaming -- and does it in a way that can't leave the sensor stranded.

    if (wifiConnect()) {
        // Untried candidate for ISSUES.md #1 (intermittent multi-minute
        // unreachability, device otherwise alive): ESP8266 modem sleep is on by
        // default and periodically suspends the radio to save power, which is a
        // known cause of exactly this "server goes quiet, comes back on its
        // own" symptom on a device that's also acting as an HTTP/mDNS server.
        WiFi.setSleepMode(WIFI_NONE_SLEEP);
        startMDNS();
    }
    ntpSync();

    httpServer.collectHeaders("X-Auth-Token");
    httpServer.on("/api/info", HTTP_GET, apiInfo);
    httpServer.on("/api/state", HTTP_GET, apiState);
    httpServer.on("/api/config", HTTP_GET, apiConfigGet);
    httpServer.on("/api/config", HTTP_POST, apiConfigPost);
    httpServer.on("/api/name", HTTP_POST, apiNamePost);
    httpServer.on("/api/brightness", HTTP_POST, apiBrightnessPost);
    httpServer.on("/api/cmd", HTTP_POST, apiCmdPost);
    httpServer.on("/api/sensor", HTTP_GET, apiSensorGet);
    httpServer.on("/api/sensor/config", HTTP_GET, apiSensorConfigGet);
    httpServer.on("/api/sensor/config", HTTP_POST, apiSensorConfigPost);
    httpServer.on("/api/sensor/thresholds", HTTP_GET, apiSensorThresholdsGet);
    httpServer.on("/api/sensor/gate", HTTP_POST, apiSensorGatePost);
    httpServer.on("/api/log", HTTP_GET, apiLogGet);
    httpServer.on("/api/debugcmd", HTTP_POST, apiDebugCmdPost);
    httpServer.on("/api/sensor/calibrate", HTTP_POST, apiSensorCalibratePost);
    httpServer.on("/api/sensor/autogain", HTTP_POST, apiSensorAutoGainPost);
    // No browser upload form. Registered before httpUpdater so this GET handler
    // wins (the server takes the first match), leaving only the POST the app
    // uses. The stock form is a second, unstyled way in that nobody wants and
    // nobody tests; the app does this properly, with progress. The only web UI
    // this device should serve is the first-time WiFi setup portal.
    httpServer.on("/update", HTTP_GET, []() {
        httpServer.send(404, "text/plain", "");   // blank -- no browser upload form
    });
    if (strlen(cfg.apiToken) > 0) httpUpdater.setup(&httpServer, "/update", "admin", cfg.apiToken);
    else httpUpdater.setup(&httpServer, "/update");
    // Any unknown path: a bare 404, no body. Nothing to see -- the app uses the
    // /api/* endpoints, and this device serves no browsable pages once online.
    httpServer.onNotFound([]() { httpServer.send(404, "text/plain", ""); });
    // Deliberately NOT keepAlive(true): measured on the real clock, connection
    // reuse made no difference (63.0ms vs 63.6ms median), and holding a
    // connection open risks starving other clients on a server that handles
    // one at a time.
    httpServer.begin();

    // Disable Nagle. Measured: ping to this device is ~2ms but an HTTP request
    // took ~63ms, and the time was being spent inside the ESP, not on the
    // network. That gap is the classic Nagle/delayed-ACK stall -- the response
    // body sits waiting for an ACK of the headers. Without this the brightness
    // slider can never update faster than ~16 times a second.
    httpServer.getServer().setNoDelay(true);

    // Boot banner only in debug mode (cfg.serialDebug) -- otherwise this TX
    // goes into the sensor's RX. In sensor mode the UART stays quiet.
    if (cfg.serialDebug) {
        Serial.println("\n=== Clockwise (SERIAL DEBUG MODE -- sensor paused) ===");
        Serial.println("s=NTP sync  w=set known  u=set custom yyyy mo dd h24 mn ss  t=read  +/-=bright(1% steps)");
        Serial.println("number=light one output  n/p=step  r=resume clock");
        Serial.println("fNNN=set OE PWM freq (Hz)  cN=add chip N  x=clear manual");
        Serial.println("g=toggle logo LED  l=toggle tick log  v=view raw RTC registers  a=WiFi-down notice timing");
        if (mdnsHost.length()) Serial.printf("Local API: http://%s.local/api/info\n", mdnsHost.c_str());
    }
    logAdd("Booted, reason: " + ESP.getResetReason());
}

// Mimics Stream::parseInt() but reads from a String instead of Serial: skips
// to the next digit (or '-'), then consumes the number. Used by runDebugCmd
// so it can reuse the exact same command syntax as the physical console
// without needing a real Stream.
long dbgParseInt(const String &s, int &idx) {
    int n = s.length();
    while (idx < n && s[idx] != '-' && !isDigit(s[idx])) idx++;
    bool neg = false;
    if (idx < n && s[idx] == '-') { neg = true; idx++; }
    long val = 0;
    while (idx < n && isDigit(s[idx])) { val = val * 10 + (s[idx] - '0'); idx++; }
    return neg ? -val : val;
}

// Runs one debug-console command from a string sent over HTTP, for the app's
// "device log" screen -- same command set and syntax as handleSerialDebug()
// below, but deliberately a SEPARATE implementation (not shared code) so that
// adding this HTTP path can never change how the physical USB console
// behaves. Returns human-readable result text instead of printing to Serial.
// Commands that put the display into manual/test mode ('c', 'x', a bare
// number) or write the RTC ('u') have no server-side confirmation gate --
// the app is expected to warn before sending those, same as it would for any
// other action that changes what the physical clock is doing.
String runDebugCmd(const String &lineIn) {
    String line = lineIn; line.trim();
    if (line.length() == 0) return "(empty command)";
    int idx = 0;
    char c0 = line[0];
    if (isDigit(c0) || c0 == '-') {
        int j = (int)dbgParseInt(line, idx);
        if (j >= 0 && j < NUM_OUTPUTS) {
            manualMode = true; manualPos = j; showOne(j);
            return "MANUAL out " + String(j) + " (chip " + String(j / 16) + ", o " + String(j % 16) + ")";
        }
        return "out of range (0-" + String(NUM_OUTPUTS - 1) + ")";
    }
    idx = 1;   // skip the command letter
    switch (c0) {
        case 'c': {
            int chip = (int)dbgParseInt(line, idx);
            if (chip < 0 || chip >= 7) return "chip must be 0-6";
            manualMode = true;
            for (int o = 0; o < 16; o += 2) setSeg(chip * 16 + o);
            shiftFrame();
            return "MANUAL chip " + String(chip) + " ADDED (even outs ON, " +
                   String(chip * 16) + "-" + String(chip * 16 + 15) + ")";
        }
        case 'f': {
            int hz = (int)dbgParseInt(line, idx);
            if (hz < 100 || hz > 40000) return "freq must be 100-40000";
            cfg.oeFreq = hz; analogWriteFreq(cfg.oeFreq); setBrightness(brightness); saveConfig();
            return "OE freq -> " + String(cfg.oeFreq) + " Hz (saved)";
        }
        case 'x': manualMode = true; clearFrame(); shiftFrame(); return "MANUAL cleared";
        case 'g': cfg.logoOn = !cfg.logoOn; saveConfig();
                  return String("logo LED -> ") + (cfg.logoOn ? "ON" : "OFF");
        case 'a': {
            int on = (int)dbgParseInt(line, idx);
            int off = (int)dbgParseInt(line, idx);
            if (on < 0 || on > 300 || off < 0 || off > 300) return "usage: a <on 0-300> <off 0-300>";
            cfg.wifiAlertOnS = on; cfg.wifiAlertOffS = off; saveConfig();
            return "no Con notice -> " + String(on) + "s/" + String(off) + "s (saved)";
        }
        case 'l': tickLogEnabled = !tickLogEnabled;
                  return String("tick log -> ") + (tickLogEnabled ? "ON" : "OFF");
        case 'w': rtcSetKnown(); return "RTC set to known value";
        case 'u': {
            int yr = (int)dbgParseInt(line, idx), mo = (int)dbgParseInt(line, idx), dd = (int)dbgParseInt(line, idx);
            int h24 = (int)dbgParseInt(line, idx), mn = (int)dbgParseInt(line, idx), se = (int)dbgParseInt(line, idx);
            if (yr >= 2000 && yr <= 2099 && mo >= 1 && mo <= 12 && dd >= 1 && dd <= 31 &&
                h24 >= 0 && h24 <= 23 && mn >= 0 && mn <= 59 && se >= 0 && se <= 59) {
                rtcWriteFull(se, mn, h24, dowSun0FromDate(yr, mo, dd), dd, mo, yr);
                char b[48]; snprintf(b, sizeof(b), "RTC set to %04d-%02d-%02d %02d:%02d:%02d", yr, mo, dd, h24, mn, se);
                return String(b);
            }
            return "usage: u <year> <month> <day> <hour24> <min> <sec>";
        }
        case 's': ntpSync(); return "NTP sync requested (see log for result)";
        case 'r': manualMode = false; return "resumed clock display";
        case 'n': manualMode = true; manualPos = (manualPos + 1) % NUM_OUTPUTS; showOne(manualPos);
                  return "MANUAL out " + String(manualPos);
        case 'p': manualMode = true; manualPos = (manualPos + NUM_OUTPUTS - 1) % NUM_OUTPUTS; showOne(manualPos);
                  return "MANUAL out " + String(manualPos);
        case '+': setBrightness(brightness + (brightness < 10 ? 1 : 5)); return "bright " + String(brightness) + "%";
        case '-': setBrightness(brightness - (brightness <= 10 ? 1 : 5)); return "bright " + String(brightness) + "%";
        case 't': {
            int h, m, s, dd, mo, yr, dw; bool pm;
            if (rtcReadAll(h, pm, m, s, dd, mo, yr, dw)) {
                char b[48]; snprintf(b, sizeof(b), "%02d:%02d:%02d %s  %02d/%02d/%d", h, m, s, pm ? "PM" : "AM", dd, mo, yr);
                return String(b);
            }
            return "RTC read fail";
        }
        case 'v': {
            Wire.beginTransmission(SD3078_ADDR); Wire.write(0x00);
            if (Wire.endTransmission(false) == 0 && Wire.requestFrom((uint8_t)SD3078_ADDR, (uint8_t)7) == 7) {
                const char *names[7] = {"sec", "min", "hour", "dow", "date", "mon", "yr"};
                String out = "RTC raw 00H-06H:";
                for (int i = 0; i < 7; i++) { char b[16]; snprintf(b, sizeof(b), " %s=%02Xh", names[i], Wire.read()); out += b; }
                return out;
            }
            return "RTC raw read fail";
        }
        default: return "unknown command '" + String(c0) + "'";
    }
}

void apiDebugCmdPost() {
    if (!apiAuthOK()) return apiUnauthorized();
    JsonDocument doc;
    if (deserializeJson(doc, httpServer.arg("plain")) || !doc["cmd"].is<const char*>()) {
        httpServer.send(400, "application/json", "{\"error\":\"bad json\"}"); return;
    }
    String result = runDebugCmd(String((const char *)doc["cmd"]));
    logAdd("cmd '" + String((const char *)doc["cmd"]) + "': " + result);
    JsonDocument resp;
    resp["output"] = result;
    String out; serializeJson(resp, out);
    httpServer.send(200, "application/json", out);
}

// The USB serial debug console -- only runs when cfg.serialDebug is true (the
// app toggle), and only then is anything read from or printed to Serial. In
// the default sensor mode this is never called and the UART is the radar's
// alone. Use this with the sensor physically unplugged (USB shares its pins).
// This is the same command set the clock had before the sensor took the UART.
void handleSerialDebug() {
    // Safety guard: if the sensor is still plugged in and streaming, its binary
    // bytes are NOT console input -- executing them lit random segments
    // (flicker), could set the RTC or write flash, and the un-capped drain
    // starved the clock until it hung. So while the radar is still connected we
    // just feed its bytes to the (harmless) parser and refuse to run commands.
    // The console only goes live once the sensor's stream has actually stopped
    // (radar.connected() false, ~2s after it's unplugged). Both loops are
    // budget-capped so a flood can never monopolise the loop.
    if (radar.connected()) {
        int drain = 128;
        while (Serial.available() && drain-- > 0) radar.feedByte((uint8_t)Serial.read());
        return;
    }
    int budget = 64;
    while (Serial.available() && budget-- > 0) {
        if (isDigit(Serial.peek())) {                       // number -> manual: light one output
            int j = Serial.parseInt();
            if (j >= 0 && j < NUM_OUTPUTS) { manualMode = true; manualPos = j; showOne(j); Serial.printf("MANUAL out %d (chip %d, o %d)\n", j, j/16, j%16); }
            continue;
        }
        char c = Serial.read();
        if (c == '\n' || c == '\r') continue;
        if (c == 'c') {
            int chip = Serial.parseInt();
            if (chip >= 0 && chip < 7) {
                manualMode = true;
                for (int o = 0; o < 16; o += 2) setSeg(chip * 16 + o);
                shiftFrame();
                Serial.printf("MANUAL chip %d ADDED (even outs ON, %d-%d)\n", chip, chip*16, chip*16+15);
            }
        }
        else if (c == 'f') {
            int hz = Serial.parseInt();
            if (hz >= 100 && hz <= 40000) {
                cfg.oeFreq = hz; analogWriteFreq(cfg.oeFreq); setBrightness(brightness); saveConfig();
                Serial.printf("OE freq -> %d Hz (saved)\n", cfg.oeFreq);
            }
        }
        else if (c == 'x') { manualMode = true; clearFrame(); shiftFrame(); Serial.println("MANUAL cleared"); }
        else if (c == 'g') { cfg.logoOn = !cfg.logoOn; saveConfig(); Serial.printf("logo LED -> %s\n", cfg.logoOn ? "ON" : "OFF"); }
        else if (c == 'a') {
            int on = Serial.parseInt(), off = Serial.parseInt();
            if (on < 0 || on > 300 || off < 0 || off > 300) Serial.println("a: usage 'a <on 0-300> <off 0-300>'");
            else if (on == cfg.wifiAlertOnS && off == cfg.wifiAlertOffS) Serial.printf("no Con notice unchanged (%ds/%ds)\n", on, off);
            else { cfg.wifiAlertOnS = on; cfg.wifiAlertOffS = off; saveConfig(); Serial.printf("no Con notice -> %ds/%ds (saved)\n", on, off); }
        }
        else if (c == 'l') { tickLogEnabled = !tickLogEnabled; Serial.printf("tick log -> %s\n", tickLogEnabled ? "ON" : "OFF"); }
        else if (c == 'w') rtcSetKnown();
        else if (c == 'u') {
            int yr = Serial.parseInt(), mo = Serial.parseInt(), dd = Serial.parseInt();
            int h24 = Serial.parseInt(), mn = Serial.parseInt(), se = Serial.parseInt();
            if (yr>=2000 && yr<=2099 && mo>=1 && mo<=12 && dd>=1 && dd<=31 && h24>=0 && h24<=23 && mn>=0 && mn<=59 && se>=0 && se<=59) {
                rtcWriteFull(se, mn, h24, dowSun0FromDate(yr, mo, dd), dd, mo, yr);
                Serial.printf("RTC set to %04d-%02d-%02d %02d:%02d:%02d\n", yr, mo, dd, h24, mn, se);
            } else Serial.println("Usage: u <year> <month> <day> <hour24> <min> <sec>");
        }
        else if (c == 's') ntpSync();
        else if (c == 'r') { manualMode = false; Serial.println("resume clock display"); }
        else if (c == 'n') { manualMode = true; manualPos = (manualPos+1)%NUM_OUTPUTS; showOne(manualPos); Serial.printf("MANUAL out %d\n", manualPos); }
        else if (c == 'p') { manualMode = true; manualPos = (manualPos+NUM_OUTPUTS-1)%NUM_OUTPUTS; showOne(manualPos); Serial.printf("MANUAL out %d\n", manualPos); }
        else if (c == '+') { setBrightness(brightness + (brightness < 10 ? 1 : 5)); Serial.printf("bright %d%%\n", brightness); }
        else if (c == '-') { setBrightness(brightness - (brightness <= 10 ? 1 : 5)); Serial.printf("bright %d%%\n", brightness); }
        else if (c == 't') {
            int h,m,s,dd,mo,yr,dw; bool pm;
            if (rtcReadAll(h,pm,m,s,dd,mo,yr,dw)) Serial.printf("%02d:%02d:%02d %s  %02d/%02d/%d\n", h,m,s,pm?"PM":"AM",dd,mo,yr);
            else Serial.println("RTC read fail");
        }
        else if (c == 'v') {
            Wire.beginTransmission(SD3078_ADDR); Wire.write(0x00);
            if (Wire.endTransmission(false) == 0 && Wire.requestFrom((uint8_t)SD3078_ADDR, (uint8_t)7) == 7) {
                const char *names[7] = {"sec","min","hour","dow","date","mon","yr"};
                Serial.print("RTC raw 00H-06H:");
                for (int i = 0; i < 7; i++) Serial.printf(" %s=%02Xh", names[i], Wire.read());
                Serial.println();
            } else Serial.println("RTC raw read fail");
        }
    }
}

void loop() {
    loopCounter++;
    static unsigned long lastLoopHzSample = 0;
    if (millis() - lastLoopHzSample >= 1000) {
        lastLoopHzSample = millis();
        lastLoopHz = loopCounter;
        loopCounter = 0;
    }

    // The UART is either the radar's or the debug console's -- cfg.serialDebug
    // (the app toggle) picks which, and they are mutually exclusive because
    // they share the one wire. Default (false): every incoming byte goes to the
    // radar's parser and nothing is printed, so sensor data can never reach a
    // command parser (that hijack blanked the display). True: the console runs
    // and the radar is left idle -- use it with the sensor unplugged.
    if (cfg.serialDebug) {
        handleSerialDebug();
    } else {
        // Budget-capped so a noisy/floating RX can't monopolise the loop and
        // starve the display; leftover bytes are picked up next pass.
        int serialBudget = 128;
        while (Serial.available() && serialBudget-- > 0) {
            radar.feedByte((uint8_t)Serial.read());
        }
        presenceDetected = radar.presence();
    }

    // Keeps the radar's actual report mode in sync with what's wanted --
    // self-healing, not just a one-shot at boot. Covers the sensor booting
    // slower than the clock, being plugged in after the clock's already up,
    // or reconnecting after its own power blip. haveEnergyGates() reflects
    // whichever mode its last real frame actually came in as, so this only
    // does anything when they disagree -- harmless to check often.
    // Radar keep-alive / recovery. Two conditions trigger a re-apply of the
    // desired report mode:
    //   1. Streaming, but in the wrong mode -> switch it.
    //   2. Was streaming and has now gone SILENT (e.g. a settings read left it
    //      stuck in config mode, or it reset) -> un-stick it. This case is the
    //      important one: the old check only ran while connected(), so once the
    //      sensor went quiet nothing ever recovered it and it stayed dead until
    //      a reboot.
    // The three commands run UNCONDITIONALLY (not gated on enableConfig
    // succeeding): entering config mode pauses the stream, so if that command's
    // ACK is lost in the data we must still send the exit, or the sensor is
    // left muted. On a streaming sensor a stray setOutputMode/endConfig is just
    // ignored; on a genuinely absent sensor all three are no-ops.
    static unsigned long lastRadarMaint = 0;
    if (!cfg.serialDebug && millis() - lastRadarMaint > 8000) {   // radar paused in debug mode
        lastRadarMaint = millis();
        const bool wrongMode = radar.connected() &&
                               radar.haveEnergyGates() != cfg.sensorEngineering;
        // "was alive, now silent for >6s" -- lastByteMs()!=0 rules out a sensor
        // that was simply never connected, so we don't hammer commands at an
        // empty UART forever.
        const bool wentSilent = !radar.connected() && radar.lastByteMs() != 0 &&
                                (millis() - radar.lastByteMs() > 6000);
        if (wrongMode || wentSilent) {
            logAdd(String("Radar recovery: ") + (wentSilent ? "went silent" : "wrong output mode"));
            radar.enableConfig(300);
            radar.setOutputMode(cfg.sensorEngineering);
            radar.endConfig(300);
        }
    }

    // Blanks just the colon LED 800ms into each second, without waiting for
    // the once-a-second full redraw below -- a cheap direct frame edit (no
    // RTC read, no digit recompute), so the flash timing doesn't depend on
    // the 1Hz tick.
    static bool colonBlankedThisSec = false;
    if (!manualMode && !btnPressed && colonOn &&
        millis() - lastTick >= 800 && !colonBlankedThisSec) {
        colonBlankedThisSec = true;
        colonOn = false;
        frame[COLON_OUT] = false;
        shiftFrame();
    }

    // btnPressed suppresses the tick's redraw: it would otherwise paint the
    // time back over the button screen within a second of it appearing.
    if (!manualMode && !btnPressed && millis() - lastTick >= 1000) {
        lastTick = millis();
        colonOn = true;                  // on again for the new second
        colonBlankedThisSec = false;
        // Alternates between the notice and the real date/year. Both halves
        // are configurable ('a' over serial); onS = 0 disables it outright.
        // An offS of 0 with a non-zero onS leaves it permanently on, which is
        // a legitimate choice, so it is not clamped away.
        const unsigned long onMs  = (unsigned long)cfg.wifiAlertOnS * 1000UL;
        const unsigned long offMs = (unsigned long)cfg.wifiAlertOffS * 1000UL;
        wifiAlertActive = (WiFi.status() != WL_CONNECTED) && onMs > 0 &&
                          (offMs == 0 || (millis() % (onMs + offMs)) < onMs);
        int h,m,s,dd,mo,yr,dw; bool pm;
        if (rtcReadAll(h,pm,m,s,dd,mo,yr,dw)) {   // h is already h12 (1-12) -- RTC does the 12h conversion
            int h24 = (h % 12) + (pm ? 12 : 0);
            updateSchedule(h24, m, yr, mo, dd, true);   // fade -- automatic background schedule tick
            applyPresenceOverlay(h24, m, yr, mo, dd);   // may override the above -- see its own comment

            // Once-a-day NTP check at 03:00. ntpSync() already skips the RTC
            // write unless drift exceeds its 2s tolerance, so this is cheap
            // and won't chew through write cycles.
            if (cfg.autoSync && h24 == 3 && m == 0 && dd != lastAutoSyncDay
                && WiFi.status() == WL_CONNECTED) {
                lastAutoSyncDay = dd;
                Serial.println("Auto NTP sync (daily)");
                ntpSync();
            }
            // Optional scheduled restart, off by default -- see cfg.autoRebootEnabled.
            // Checked once/minute like the NTP sync above; the anchor day is
            // what actually prevents re-firing every minute through the
            // trigger hour (it's advanced the instant this fires, and
            // persisted so a reboot mid-check can't forget and loop).
            if (cfg.autoRebootEnabled && h24 == cfg.autoRebootHour && m == 0) {
                long today = daysFromCivil(yr, mo, dd);
                if (today - cfg.autoRebootAnchorDay >= (long)cfg.autoRebootIntervalDays) {
                    cfg.autoRebootAnchorDay = today;
                    saveConfig();
                    logAdd("Scheduled restart (every " + String(cfg.autoRebootIntervalDays) + "d)");
                    delay(200);
                    ESP.restart();
                }
            }
            int dowRtc  = (dw == 0) ? 7 : dw;     // testing the actual fix: display uses the RTC's own register now
            int dowCalc = dowFromDate(yr, mo, dd); // still logged for comparison, not displayed
            renderAll(h,m,dd,mo,yr,dowRtc);
            if (cfg.serialDebug && tickLogEnabled) Serial.printf("%02d:%02d:%02d %02d/%02d/%d dow(rtc)=%d dow(calc)=%d\n", h,m,s,dd,mo,yr,dowRtc,dowCalc);
        }
    }
    if (WiFi.status() == WL_CONNECTED) {
        if (!mqtt.connected()) mqttReconnect();
        else {
            mqtt.loop();
            if (millis() - lastMqttPublish >= 5000) {
                lastMqttPublish = millis();
                mqttPublishState();
            }
        }
    }
    // Physical button: plain reboot is the D1 Mini's own RST button (extended
    // out of the case separately), so this one only does the two resets. The
    // display counts the seconds and names what releasing now would do -- see
    // renderButtonHold(). 3 = WiFi reset, 8 = factory, 15 = cancelled.
    bool btnNow = digitalRead(PIN_BUTTON) == LOW;   // pull-up: LOW means pressed
    if (btnNow && !btnPressed) {
        btnPressed = true;
        btnPressStart = millis();
        btnHeldSecs = 0;
        renderButtonHold(0);             // blank the clock the instant it is pressed
    } else if (btnNow && btnPressed) {
        unsigned long held = millis() - btnPressStart;
        int dueSeconds = held / 1000;
        if (dueSeconds > btnHeldSecs && btnHeldSecs < BTN_ABORT) {
            btnHeldSecs++;
            renderButtonHold(btnHeldSecs);
        }
    } else if (!btnNow && btnPressed) {
        btnPressed = false;
        // Past BTN_ABORT nothing fires. Two reasons: a button jammed by the
        // case or a mounting screw would otherwise sail through 8 seconds and
        // factory-reset the clock unprompted, and once past 3 seconds there
        // was no way to change your mind -- releasing always did something.
        // Keeping hold is the intuitive way to back out.
        if (btnHeldSecs >= BTN_ABORT)  { /* cancelled */ }
        else if (btnHeldSecs >= 8)     doFactoryReset();   // clears WiFi + all settings
        else if (btnHeldSecs >= 3)     doWifiReset();      // clears WiFi only
        // Released below either tier: nothing happens, and the next tick
        // (within a second) redraws the time over the blank screen.
    }

    stepFade();
    httpServer.handleClient();
    MDNS.update();
}
