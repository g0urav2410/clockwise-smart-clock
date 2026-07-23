# Serial commands

> **⚠️ Off by default (2026-07-22), behind a toggle.** The hardware UART is
> normally the HLK-LD2402 radar's; the sensor's binary data would be misread as
> these commands (it blanked the display). Everything here is now done through
> the app / `/api/*` and OTA instead. To use this console, enable
> **Settings → Presence sensor → USB serial debug** (`serialDebug`) and unplug
> the sensor — the console wakes ~2 s after its stream stops. With the sensor
> plugged in the console stays asleep and these commands never fire. USB
> *flashing* is unaffected either way. See MANUAL.md for the toggle's behaviour.

Connect at 115200 baud. The full list also prints once at boot.

## Debug / testing tools

Kept for future hardware debugging (a repair, a rebuild, a new fault) — not
just leftovers from initial bring-up.

| Command | Purpose |
|---|---|
| `number` (e.g. `42`) | Light exactly one of the 112 raw LED outputs, all others dark. Verify a single segment/wire is soldered and mapped correctly. |
| `n` / `p` | Step the "one output" selection forward/backward. Walk the whole chain without retyping numbers. |
| `cN` (N = 0–6) | Light chip N's even-numbered outputs, **adding** to whatever's already lit. Combine chips (`x`, then `c2`, `c3`, `c6`, ...) to check for cross-chip interaction issues — this is how the [ghosting bug](../firmware/GHOSTING_TEST_GUIDE.pdf) was isolated to chips 2/3/6. |
| `x` | Clear the manual test frame (all outputs dark). |
| `r` | Leave manual test mode, resume the live clock display. |
| `fNNN` | Set the OE PWM (brightness) frequency live, 100–40000 Hz. For retesting brightness/flicker behavior if the hardware changes. |
| `w` | Force a hardcoded known date/time onto the RTC, no WiFi needed. Quick display sanity check independent of NTP. |
| `u <yr> <mo> <dd> <h24> <mn> <ss>` | Set any custom date/time, e.g. `u 2026 7 18 23 59 55` to jump 5 seconds from midnight and watch the date/day-of-week rollover happen live instead of waiting for a real one. |
| `v` | Print the RTC's raw register bytes in hex. Cross-check against the [SD3078 datasheet](#) directly when something looks wrong — this is how the [day-of-week bug](#day-of-week-bug-2026-07-18) below was diagnosed. |

## Operational commands

Everyday controls, not just for testing.

| Command | Purpose |
|---|---|
| `s` | Manual NTP sync (also runs automatically on boot). |
| `t` | Print the RTC's decoded date/time (human-readable), plus both the RTC's own and the calculated day-of-week for comparison. |
| `+` / `-` | Brightness up/down (1% steps below 10%, 5% steps above). |
| `g` | Toggle the logo LED independently of the date/month/year indicators. |
| `m` | Toggle the mmWave presence feature on/off. |
| `l` | Toggle the once-a-second clock tick log on/off (it's on by default and floods the monitor otherwise). |
| `a <on> <off>` | Timing of the `no Con` WiFi-down notice, in seconds — e.g. `a 5 5` alternates 5s of the notice with 5s of the real date/year. Saved to flash. `a 0 0` turns the notice off entirely; an `off` of 0 leaves it up continuously while WiFi is down. Both accept 0–300. Re-entering the current values skips the write. |

mmWave sensor text prints automatically as `[MM] ...` whenever the sensor
sends data — no command needed.

## Day-of-week bug (2026-07-18)

Day-of-week (Mon–Sun) would occasionally get stuck instead of advancing at
midnight. Root cause, found via the SD3078's actual datasheet: the RTC's hour
register has a bit that selects 12-hour vs 24-hour mode, and firmware was
accidentally writing the PM flag into that same bit — every PM time-write
silently flipped the chip's hour mode, leaving it in an inconsistent state.

Fixed by keeping the RTC in 12-hour mode consistently (AM/PM in the correct
bit) and by writing the day-of-week register in the RTC's actual format
(`00=Sunday..06=Saturday`, not the `1=Monday..7=Sunday` the original firmware
assumed). The display also now cross-checks the RTC's own day-of-week
register against a value calculated from the date, logged via `t` and the
per-second tick log, as a way to verify the fix on real hardware.
