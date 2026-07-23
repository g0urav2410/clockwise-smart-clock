# Ajanta Clock — Segment Map (output position → physical LED)

> The mapping below is complete and matches the shipped firmware — see
> "FULL DISPLAY VERIFIED" near the end. Kept in its original working-notes
> form as a reference for anyone mapping a similar display.

Fill this in by walking the mapper (tc_chain_test): for each POS 0..111, note
which LED/segment lights. 80 of 112 are used; the rest are spares.

## Naming convention

**7-segment digit segments** (standard a–g):
```
     aaa
    f   b
    f   b
     ggg
    e   c
    e   c
     ddd
```

**Digit labels:**
- Time:  H1 H2 : M1 M2   (H1 = tens-of-hour, only shows "1")
- Date:  DD (D1 D2)  MM (O1 O2)  YY (Y1 Y2)
- Indicators: iD iM iY (the 3 date/month/year marker LEDs)
- Days:  dMon dTue dWed dThu dFri dSat dSun
- Other: LOGO, COLON, SEC

Example entry:  `POS 5 = M1-a` (top segment of first minute digit)
Spare/nothing:  `POS 5 = (none)`

## CHIP → REGION (done — from 'c' walk)

Assuming firmware CHIP 0 = outputs 0-15 = first chip on SDI (confirm indexing!).

| Chip | Outputs  | Region                                   |
|------|----------|------------------------------------------|
| 1    | 0 - 15   | Year, last 2 digits (YY low)             |
| 2    | 16 - 31  | Year, first 2 digits + Y indicator LED   |
| 3    | 32 - 47  | Date (DD, day-of-month)                  |
| 4    | 48 - 63  | Days (day-of-week Mon..Sun)              |
| 5    | 64 - 79  | Hours (H1 partial + H2)                  |
| 6    | 80 - 95  | Minutes (M1 + M2)                        |
| 7    | 96 - 111 | D indicator, Months (MM), M indicator    |

Next: map segments within each chip. Do Hours (64-79) + Minutes (80-95) first
to get a working clock fastest, then colon, then date/year/days.

## SEGMENTS MAPPED (output number per segment)

HOURS (chip 5, outputs 64-79):
  H1 (tens, shows only "1"):  b=65  c=66
  H2 (units, full digit):     a=77  b=76  c=74  d=73  e=72  f=71  g=75
  LOGO led (red) = 79
  Unmapped in this chip: 64,67,68,69,70,78 (colon? spare? — check later)

MINUTES (chip 6, outputs 80-95):
  M1 (full digit):  a=80  b=86  c=85  d=83  e=82  f=81  g=84
  M2 (full digit):  a=91  b=93  c=94  d=95  e=89  f=90  g=92
  Unmapped in this chip: 87,88 (colon? spare? — check later)

(Remaining segments — colon, date, month, year, day-of-week, and the D/M/Y
indicators — are mapped further down; see "FULL SEGMENT MAP" below.)

>>> HOURS + MINUTES VERIFIED: firmware renders 12:34 from RTC correctly,
    proper 12h format (1-12, no leading zero). Time display WORKS. <<<

## FULL SEGMENT MAP (from mapping session)

seg order a,b,c,d,e,f,g

HOURS (chip4, 64-79):
  H1 (tens "1"): b=65 c=66
  H2:  a=77 b=76 c=74 d=73 e=72 f=71 g=75
LOGO led (red) = 79

MINUTES (chip5, 80-95):
  M1:  a=80 b=86 c=85 d=83 e=82 f=81 g=84
  M2:  a=91 b=93 c=94 d=95 e=89 f=90 g=92

DATE / day-of-month (chip2, 32-47):
  D1 (tens): a=34 b=35 c=36 d=37 f=38 g=47   (e? tens only 0-3, verify)
  D2 (units): a=46 b=45 c=43 d=42 e=41 f=40 g=44

MONTH (chip6, 96-111 low part):
  O1 (tens "1"): b=102 c=101
  O2 (units): a=109 b=108 c=107 d=103 e=104 f=105 g=106
  D-indicator LED = 110    M-indicator LED = 111

DAYS (chip3, 48-63) — each day = 2 LEDs (two outputs):
  Mon=62+48  Tue=61+49  Wed=60+50  Thu=59+51
  Fri=58+52  Sat=57+53  Sun=56+54

YEAR (chip0+chip1, 0-31) — 4 digits, VERIFIED (shows 2026 clean):
  Yd1 (thousands "2"): a=16 b=22 d=19 e=18 g=20   (c,f absent)
  Yd2 (hundreds  "0"): a=29 b=28 c=27 d=23 e=24 f=25   (g absent)
  Yd3 (tens):          a=0  b=5  c=4  d=3  e=2  f=1  g=6
  Yd4 (units):         a=15 b=14 c=9  d=13 e=12 f=11 g=10
  Y-indicator LED = 8

Known shorts fixed during mapping (e.g. output 42 was bridged c+g).

>>> FULL DISPLAY VERIFIED: time + date + month + year + day-of-week all render
    correctly from RTC. Entire display mapped. <<<

COLON: cathode rewired to spare chain output 67 -> blinks via frame bit,
brightness follows OE. WORKS.

>>> CORE CLOCK COMPLETE: full display + RTC + NTP sync + blinking colon,
    all ESP-driven, correct time/date/day. <<<
Remaining = smart features: auto-brightness, mmWave presence, WiFiManager,
MQTT/Home Assistant, OTA, daily auto NTP sync.

## Map

| POS | LED | POS | LED | POS | LED | POS | LED |
|-----|-----|-----|-----|-----|-----|-----|-----|
| 0   |     | 28  |     | 56  |     | 84  |     |
| 1   |     | 29  |     | 57  |     | 85  |     |
| 2   |     | 30  |     | 58  |     | 86  |     |
| 3   |     | 31  |     | 59  |     | 87  |     |
| 4   |     | 32  |     | 60  |     | 88  |     |
| 5   |     | 33  |     | 61  |     | 89  |     |
| 6   |     | 34  |     | 62  |     | 90  |     |
| 7   |     | 35  |     | 63  |     | 91  |     |
| 8   |     | 36  |     | 64  |     | 92  |     |
| 9   |     | 37  |     | 65  |     | 93  |     |
| 10  |     | 38  |     | 66  |     | 94  |     |
| 11  |     | 39  |     | 67  |     | 95  |     |
| 12  |     | 40  |     | 68  |     | 96  |     |
| 13  |     | 41  |     | 69  |     | 97  |     |
| 14  |     | 42  |     | 70  |     | 98  |     |
| 15  |     | 43  |     | 71  |     | 99  |     |
| 16  |     | 44  |     | 72  |     | 100 |     |
| 17  |     | 45  |     | 73  |     | 101 |     |
| 18  |     | 46  |     | 74  |     | 102 |     |
| 19  |     | 47  |     | 75  |     | 103 |     |
| 20  |     | 48  |     | 76  |     | 104 |     |
| 21  |     | 49  |     | 77  |     | 105 |     |
| 22  |     | 50  |     | 78  |     | 106 |     |
| 23  |     | 51  |     | 79  |     | 107 |     |
| 24  |     | 52  |     | 80  |     | 108 |     |
| 25  |     | 53  |     | 81  |     | 109 |     |
| 26  |     | 54  |     | 82  |     | 110 |     |
| 27  |     | 55  |     | 83  |     | 111 |     |
