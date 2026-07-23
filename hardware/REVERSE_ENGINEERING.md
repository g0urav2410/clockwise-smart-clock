# Ajanta Clock — Full Display Takeover (Option A)

> **This is the raw investigation log from reverse-engineering the display**,
> kept as-is because it's the most honest record of how the pinout, MOSFET
> roles, and chain wiring were actually figured out — including drafts and dead
> ends. **It predates the final firmware and its pin numbers are superseded.**
> For the real, shipped pinout, see the [main README](../README.md#hardware).
> Everything in the "[Current status](#current-status)" section at the end is
> done and shipped — see [`firmware/`](../firmware/) for the finished
> implementation.

Goal: ESP8266 becomes the sole brain. Drives the 7-chip TC5020EJ LED-driver
chain directly, plus section MOSFETs, plus brightness (OE PWM), plus mmWave
presence. Original clock MCU is disconnected from the display lines (can stay
physically on the board, just cut from data/clock/latch).

No more I2C two-master collision because the original MCU no longer owns anything.

---

## Hardware chain

7 × TC5020EJ (SSOP-24), 16 outputs each = **112 total outputs**.
Daisy-chained shift registers:

```
ESP SDI → [chip1 SDI  SDO] → [chip2 SDI  SDO] → ... → [chip7 SDI  SDO](unused)
ESP CLK → common to all 7 chips
ESP LE  → common to all 7 chips
ESP OE  → common to all 7 chips (already wired to D5, PWM brightness)
```

To show a frame: shift out 112 bits (chip7 data first ... chip1 data last,
because chip1 is closest to SDI and data ripples through), then pulse LE.

**Bit order to confirm during mapping** — we discover it empirically with the
walking-bit test, so don't assume MSB/LSB or chip order yet.

---

## TC5020EJ pinout (SSOP-24) — CONFIRMED from real datasheet (FM, v1.0 2021)

| Pin | Signal        | Pin | Signal |
|-----|---------------|-----|--------|
| 1   | GND           | 13  | OUT8   |
| 2   | **SDI** in    | 14  | OUT9   |
| 3   | **CLK** (rising edge) | 15  | OUT10  |
| 4   | **LE** latch  | 16  | OUT11  |
| 5   | OUT0          | 17  | OUT12  |
| 6   | OUT1          | 18  | OUT13  |
| 7   | OUT2          | 19  | OUT14  |
| 8   | OUT3          | 20  | OUT15  |
| 9   | OUT4          | 21  | **OE** active-LOW |
| 10  | OUT5          | 22  | **SDO** out |
| 11  | OUT6          | 23  | REXT   |
| 12  | OUT7          | 24  | VDD    |

Chain: chipN SDO(22) → chipN+1 SDI(2). CLK(3), LE(4), OE(21) all common.
First chip = the one whose SDI(2) comes from the original MCU, not from
another chip's SDO(22).

LE behaviour (from truth table): LE HIGH = shift register transparent to
outputs; LE LOW = latched/held. So: shift 112 bits with LE low, pulse LE
high then low to latch. (tc_chain_test.ino already does this.)
CLK: data shifts on RISING edge.

## Pins (ESP8266 NodeMCU) — DRAFT, confirm pin budget

| Signal      | NodeMCU | GPIO | Notes                          |
|-------------|---------|------|--------------------------------|
| OE (bright) | D5      | 14   | already wired, PWM active-LOW  |
| SDI (data)  | D7      | 13   | to first chip SDI              |
| CLK (clock) | D6      | 12   | common clock                   |
| LE (latch)  | D8      | 15   | common latch (has pulldown, ok)|
| Sensor RX   | D2      | 4    | mmWave TX → here (RTC freed it)|
| Sensor TX   | D1      | 5    | mmWave RX ← here               |
| MOSFET(s)   | D3/D4/? | 0/2  | section power — count TBD      |

⚠ Pin budget is tight on ESP8266. Need exact MOSFET count before finalizing.
If too many MOSFETs, options: drive them via spare TC5020EJ outputs, or move to
a chip with more GPIO.

---

## Step-by-step plan

1. **Identify the 3 control lines into the chain**
   - On TC5020EJ: find SDI (serial data in), SDO (serial data out), CLK, LE, OE.
   - OE confirmed = pin 21 (active LOW).
   - Find chip #1 = the one whose SDI trace goes back to the original MCU
     (not to another chip's SDO).
   - Confirm CLK and LE are common across all 7 chips (probe continuity).

2. **Cut the original MCU from SDI, CLK, LE.** Leave MCU powered/alive; just
   sever its control of the chain. Wire those 3 chip lines to ESP D7/D6/D8.

3. **Walking-bit mapping** (tc_chain_test.ino):
   - Shift a single `1` through positions 0..111, one at a time, ~1s each.
   - You watch the clock face and tell me which segment lit for each position.
   - We build a position → (digit, segment) table.

4. **Build the font map** — from the segment table, define which output bits
   form each digit 0-9 in each display position.

5. **Render firmware** — ESP keeps NTP time, renders HH:MM (+date, day, colon),
   applies brightness via OE PWM, dims/wakes from mmWave presence.

6. **Section MOSFETs** — map which MOSFET powers which display block, drive
   from ESP.

---

## FOUND — control lines traced to original MCU

Chip #1 = the chip whose SDI (pin 2) goes to the original MCU. CONFIRMED.

| Chip #1 pin | Signal      | → Original MCU pin | Action        |
|-------------|-------------|--------------------|---------------|
| Pin 2       | SDI (data)  | MCU pin 8          | CUT, wire ESP D7 |
| Pin 3       | CLK (clock) | MCU pin 17         | CUT, wire ESP D6 |
| Pin 4       | LE (latch)  | MCU pin 3          | CUT, wire ESP D8 |

CLK (pin 3) and LE (pin 4) confirmed SHARED across all 7 chips.

Cut these 3 traces between the MCU and the chain, then wire ESP in their place.
Original MCU stays powered, just severed from the display.

## PRE-DESOLDER CHECKLIST — capture while MCU is ALIVE

Once the MCU is desoldered we lose: live signals, original display behaviour,
and the "which MCU pin does what" reference. Capture all of this FIRST.

### P1 — only knowable with MCU running
- [x] Static vs multiplexed? → **STATIC, CONFIRMED**
      Proof: OE PWM gave smooth uniform brightness across the WHOLE display.
      Multiplexed would fight the scan (flicker/uneven). Clean global dimming
      = every segment driven continuously = static direct drive.
      → Section MOSFETs are brightness/blanking gates, NOT scan rows.
      → Display content: day-of-week, time, date, month, year.
- [ ] Logic-analyzer capture of SDI + CLK + LE + OE (one full refresh) — gives
      bit order, refresh rate, frame size
- [ ] Watch each section MOSFET gate: does it switch fast (mux row) or stay
      on/PWM (brightness/blank)?
- [ ] Photograph the clock showing a KNOWN time (e.g. 12:34) — reference for
      decoding which segments = which digit later

### P1b — LOGIC LEVEL CHECK → DONE, no shifter needed
TC5020EJ VDD measured 3.3V (full bright) up to ~4V (dim). Never 5V.
The swing is just the shared rail sagging under LED load (PWM brightness).
Input-high threshold ~0.7*VDD = 2.3V..2.8V. ESP outputs 3.3V, safely above
in all cases → ESP drives SDI/CLK/LE directly. NO level shifter required.

### POWER TREE — map all rails before adding ESP as a load

Both 5V and 3.3V rails sag under load, so know the whole tree first.
Measure each rail at TWO states: display DIM (light load) and FULL bright (heavy).

| Rail            | Source          | V (dim) | V (full) | Powers                        |
|-----------------|-----------------|---------|----------|-------------------------------|
| Input jack (5V) | adapter         | ___     | ___      | LM1117 in, divider LEDs, ?    |
| LM1117 out(3.3) | LM1117 tab      | ___     | ___      | MCU, RTC, TC5020EJ VDD?, ?    |
| Chain VDD       | FET B rail      | ~4V     | ~3.3V    | TC5020EJ pin24 + LED anodes   |
| Divider LEDs    | 5V via FET A    | ___     | ___      | dividing line LEDs            |

To fill in:
- [ ] Jack + to GND: V at dim vs full bright
- [ ] LM1117 TAB (output) to GND: V  (small side pins mislead — use the tab)
- [ ] Continuity: LM1117 tab -> which chips? (MCU VDD, RTC pin3, TC5020 pin24)
- [ ] Is chain VDD (FET B) fed from LM1117 3.3V or from 5V? (trace FET B source)

### ESP POWER — do NOT hang on the sagging 3.3V logic rail
ESP8266 pulls ~300mA spikes on WiFi TX -> would brown out a soft rail.
Plan: tap raw input jack -> NodeMCU **Vin** (its own onboard reg makes clean
3.3V, isolated). Shared GND mandatory. During dev, just use USB.

### POWER TREE — RESOLVED
Key data: at low brightness, RTC and driver ICs read the SAME ~3.97V -> same rail.
That shared rail = LM1117 output.
  5V input (sags to 4V) -> LM1117 -> LOGIC RAIL 3.3-4V -> RTC + 7 drivers + MCU
  5V input -> directly -> divider LEDs + LED anodes (current-hungry stuff)
Rail moves 3.97V(dim)->3.3V(bright) because input sags under LED load and the
regulator output follows it. Not broken — just a soft input.

I2C level fix: RTC sits on ~4V rail -> its pull-ups would put 4V on the bus
(>ESP 3.6V max). FIX: source the two I2C pull-ups from the ESP's own 3.3V pin.
I2C is open-drain (RTC only pulls LOW), so pull-up voltage sets the high level
= 3.3V, ESP-safe. RTC still reads 3.3V fine (its VIH ~2.8V). No need to move
RTC VDD.

### POWER INVESTIGATION — CLOSED (enough known)
- Onboard LM1117 (adj, feedback R = 100R + 330R). Exact rail topology not
  fully resolved from in-circuit readings — and doesn't need to be.
- What matters & is confirmed: input ~5V (sags to 4V under load), common GND,
  chain runs 3.3-4V, ESP 3.3V logic is valid, ESP powers from Vin.
- ⚠ Input already sags 1V under clock's own load. Check adapter A rating before
  hanging ESP on it. Safest: separate USB or a beefier adapter.
- STOP in-circuit resistance probing — parallel paths give false values.
  Use VOLTAGE comparisons if more mapping ever needed.

### P2 — MCU pinout reference (lost after desolder)
- [ ] Map EVERY MCU pin -> what it connects to. Confirmed so far:
        MCU pin 3  -> chip#1 LE  (pin 4)
        MCU pin 8  -> chip#1 SDI (pin 2)
        MCU pin 17 -> chip#1 CLK (pin 3)
- [ ] MCU pins -> section MOSFET gates (which pin drives which MOSFET)

### MOSFET map (4 total)
| FET | Controls                                    | Powers IC VDD? | ESP action        |
|-----|---------------------------------------------|----------------|-------------------|
| A   | dividing line (separate 5V, not on chain)   | no             | PWM from ESP      |
| B   | time + seconds + logo + **TC5020EJ VDD(24)**| **YES**        | HARDWIRE ON, never PWM |
| C   | date + days section                         | ? (check)      | TBD               |
| D   | CR (colon / blink)                          | ? (check)      | ESP drive (blink) |

Rule: FETs that feed the chain / IC VDD = hardwire ON, brightness via OE.
Only separately-powered stuff (divider, colon, seconds) gets its own ESP drive.

Day-of-week: each day word = 2 LEDs, one on TIME rail (FET B), one on DATE
rail (FET C). Both FETs ON = days work. No special handling.
CR (FET D): toggling showed nothing notable. Colon is actually powered by the
TIME rail (FET B), not CR. CR function still unknown — revisit later.
COLON: anode on FET B rail (always powered), but CATHODE switched directly by
an MCU GPIO (ground-side blink control) — NOT on the chain. ESP must drive the
colon cathode after MCU removal (pull LOW = lit, release = off). Needs 1 pin.
  - MCU pin driving colon cathode = **MCU pin 4, ACTIVE LOW** (LOW=colon on)
  - Sink current low enough for direct ESP GPIO, or need transistor? -> TBD

### CONSOLIDATED DRIVE PLAN (post-desolder, static display)

Hardwire ON (no ESP pin):
  - FET B (time + seconds anode + logo + TC5020EJ VDD)
  - FET C (date + month + year + day-LED #2)

ESP drives:
  | Signal        | NodeMCU | GPIO | Notes                              |
  |---------------|---------|------|------------------------------------|
  | OE brightness | D5      | 14   | PWM, global chain brightness       |
  | CLK           | D6      | 12   | chain clock                        |
  | SDI           | D7      | 13   | chain data (chip#1 pin2)           |
  | LE            | D8      | 15   | chain latch                        |
  | Divider PWM   | D3      | 0    | separate 5V, PWM to match brightness |
  | Seconds blink | D4      | 2    | via S9015, toggle 1Hz              |
  | Sensor RX     | D1      | 5    | mmWave TX -> here (SoftwareSerial) |
  | Sensor TX     | D2      | 4    | mmWave RX <- here                  |
  | (spare)       | D0      | 16   | colon/CR on-off if needed          |

### RTC — KEPT as battery-backed fallback

Once MCU is desoldered, ESP is the ONLY I2C master → NO collision, ever.
The entire "write FAILED" saga was the original MCU fighting us. Gone now.
  - Network up  -> ESP syncs SD3078 from NTP
  - Power/net down -> ESP reads time from SD3078 on boot, display correct instantly
  - RTC keeps time on its VBAT battery through outages

### PIN BUDGET (with RTC back in) — TIGHT, needs 2 freed

Everything wanted: chain(4) + divider PWM(1) + colon(1) + seconds(1) +
sensor RX/TX(2) + RTC SDA/SCL(2) = 11. ESP8266 has only 9 usable. Over by 2.

FREE 2 PINS — two easy wins:
  1. Reroute COLON + SECONDS cathodes to SPARE TC5020EJ chain outputs.
     112 outputs exist; display likely uses fewer -> spares probably available.
     Confirm during walking-bit map. If spares exist, colon+seconds become
     data bits (no ESP pin) -> frees 2 pins. THIS IS THE CLEAN FIX.
  2. (fallback) Sensor RX-only: we just read presence frames, never send config
     at runtime -> 1 pin instead of 2. Frees 1.

Target pin map IF colon+seconds move to chain:
  | Signal        | NodeMCU | GPIO | PWM? |
  |---------------|---------|------|------|
  | OE brightness | D5      | 14   | yes  |
  | CLK           | D6      | 12   |      |
  | SDI           | D7      | 13   |      |
  | LE            | D8      | 15   |      |
  | Divider PWM   | D3      | 0    | yes  |
  | RTC SDA       | D2      | 4    |      |
  | RTC SCL       | D1      | 5    |      |
  | Sensor RX     | D4      | 2    |      | (SoftwareSerial, RX only)
  | (spare)       | D0      | 16   |      |
  → 8 pins, one spare. Comfortable. Colon+seconds = chain outputs.
- [ ] MCU pins -> RTC SDA/SCL (the I2C pair)
- [ ] MCU VDD & GND pins
- [ ] MCU pins -> seconds LED / colon drive
- [ ] MCU pins -> any buttons / set switches

### P3 — can also do AFTER desolder (ESP drives chain)
- [ ] Chain order of all 7 chips (SDO pin22 -> next SDI pin2)
- [ ] Walking-bit segment map (tc_chain_test.ino), positions 0..111
- [ ] REXT resistor value on each chip (sets LED current)

## DESOLDER + REWIRE — step by step

### Before desoldering (capture, MCU still alive)
- [ ] Photo of display at a KNOWN time/date (reference for segment decoding)
- [ ] Trace + note MCU pin -> colon cathode
- [ ] Confirm: is seconds also GPIO-cathode (like colon) or on the chain?
- [ ] Note MCU VDD & GND pins (leave those rails/pads intact)

### Desolder
- [ ] Hot-air the original MCU off. Leave every other component in place.
- [ ] Clean the pads. MCU is fully out of the circuit now.

### Rewire ESP -> chain (chip #1)
- [ ] ESP D7 (GPIO13) -> chip#1 pin 2  (SDI)
- [ ] ESP D6 (GPIO12) -> chip#1 pin 3  (CLK)
- [ ] ESP D8 (GPIO15) -> chip#1 pin 4  (LE)
- [ ] ESP D5 (GPIO14) -> OE line        (already wired)
- [ ] ESP GND         -> board GND       (common)

### Hardwire section power ON
- [ ] FET B gate -> tie to permanent-ON level (P-ch: gate to GND via pulldown,
      or however it switches on). Powers TC5020EJ VDD + time/logo/colon/seconds.
- [ ] FET C gate -> tie permanent-ON. Powers date/month/year + day-LED#2.

### Separate-drive parts
- [ ] Divider line FET gate -> ESP D3 (GPIO0)   [PWM, separate 5V]
- [ ] Colon cathode   -> spare TC5020EJ output (reroute) OR ESP pin if no spare
- [ ] Seconds cathode -> spare TC5020EJ output (reroute) OR ESP pin if no spare

### RTC (ESP is now sole I2C master)
- [ ] ESP D2 (GPIO4) -> RTC SDA (pin 8)
- [ ] ESP D1 (GPIO5) -> RTC SCL (pin 1)
- [ ] Remove the old 100ohm series resistors if they hinder (no MCU to isolate now)

### BEST RTC WIRING — power RTC from D1 Mini 3V3 (cleanest)
Board = Wemos D1 Mini (low-dropout reg ME6211/RT9013, works from ~3.6V in).
Power the RTC entirely from the D1 Mini 3V3 pin -> whole I2C bus is 3.3V by
nature, perfect match, no level tricks, no 4V near the ESP.
  - RTC VDD (pin3) -> D1 Mini 3V3   (CUT from old 4V rail first!)
  - RTC SDA (pin8) -> D1 Mini D2 + 4.7k pull-up to 3V3
  - RTC SCL (pin1) -> D1 Mini D1 + 4.7k pull-up to 3V3
  - RTC GND -> common GND
  - VBAT coin cell -> leave as-is (keeps time through outages)
  ⚠ Old on-board pull-ups: if they reference the 4V rail, MOVE them to 3V3 or
    remove and use fresh 4.7k to 3V3. No 4V may touch the bus.
  RTC draws only microamps -> D1 Mini 3V3 supplies it easily.

### ESP POWER (D1 Mini) — single cord
D1 Mini reg is LOW dropout (~0.3V), makes 3.3V from as low as ~3.6V input.
Raw clock input (5V, sags to 4V) stays >3.6V -> feed it to D1 Mini "5V" pin.
  - Raw input jack -> D1 Mini 5V pin (NOT the internal 4V rail, that sags to 3.3)
  - Shared GND
  One wall adapter powers everything. Beefier adapter optional (stiffer rail).

### mmWave sensor
- [ ] Sensor TX -> ESP D4 (GPIO2)  [RX only, SoftwareSerial]
- [ ] Sensor GND -> common GND

### Bring-up sequence
- [ ] Flash tc_chain_test.ino -> walk outputs 0..111, record segment map
- [ ] Map the USED outputs first: time digits, date, month, year, day words
- [ ] Whatever outputs are left = spares. THEN decide colon/seconds:
        spare outputs available -> reroute colon+seconds to chain (0 pins)
        no spares               -> keep colon+seconds on ESP GPIO pins
- [ ] Build font map from segment table
- [ ] Flash final render firmware (NTP + RTC + brightness + presence)

Note: reshifting the full 112-bit frame to blink the colon is HARMLESS —
outputs hold on the latch while shifting, only LE pulse updates them, so no
flicker. Frame shift is <1ms. Colon-on-chain is fine if pins are tight.

## DISPLAY LED COUNT (from physical inspection)
| Section                         | LED points |
|---------------------------------|------------|
| Time (HH:MM, colon separate)    | 23 (2+7+7+7, tens-hr shows only "1") |
| Days (day-of-week)              | 7          |
| Date (incl. 3 D/M/Y indicators) | 50         |
| TOTAL used                      | 80         |
Chain has 112 outputs -> ~32 SPARE outputs available.
Spares can host colon/seconds later (no extra ESP pin needed).
Still must walk outputs 0..111 to map each position -> physical LED.

## Current status

Everything below is done and shipped — this log is kept as the record of how
each step was figured out. See [`firmware/src/main.cpp`](../firmware/src/main.cpp)
and [`SEGMENT_MAP.md`](SEGMENT_MAP.md) for the final results, and the
[main README](../README.md) for the current pinout.

- [x] Control lines identified (SDI=MCU8 / CLK=MCU17 / LE=MCU3)
- [x] Display type: STATIC (confirmed via OE PWM behaviour)
- [x] MOSFET roles mapped (B=time+ICs, C=date+days, A=divider, D=CR unknown)
- [x] Colon = FET B anode + MCU-GPIO cathode (not on chain)
- [x] RTC kept as battery backup (ESP sole master after MCU removed)
- [x] Pin budget solved (colon+seconds -> spare chain outputs)
- [x] MCU cut from chain, ESP wired in
- [x] Walking-bit map complete (0..111)
- [x] Font map built
- [x] Time rendering works
- [x] MOSFET sections mapped
- [x] mmWave presence integrated
- [x] Brightness (OE PWM) integrated
