"""Force sun mode to any brightness, for testing, without waiting for the sun.

The clock has no API to set its RTC, so this shifts its *longitude* instead:
sun position is computed from longitude and a fixed timezone, so moving the
clock west makes it believe the sun is elsewhere in the sky. The RTC is never
touched, and the change is a normal config write you can undo.

    py tools_fake_sun.py --host 192.168.0.50 25       aim sun mode at 25%
    py tools_fake_sun.py --host 192.168.0.50 restore  put the real longitude back

Restore uses the longitude saved by the first run of this tool (in
tools_fake_sun_saved.json next to this script), so run it once before you start
faking, and always restore when finished -- otherwise the clock will follow a
sun on the wrong side of the planet.

While faking, the app's day strip will look wrong: it draws from the same fake
longitude, so the "now" marker can sit in a bright part of the strip while the
LEDs are dim. That is the lie showing, not a bug.
"""
import argparse
import datetime
import json
import math
import os
import sys
import urllib.request

SAVED = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                     "tools_fake_sun_saved.json")


def elevation(lat, lon, tz_hours, dt):
    """Same NOAA approximation the firmware's solarElevation() uses."""
    n = dt.timetuple().tm_yday
    hour = dt.hour + dt.minute / 60 + dt.second / 3600
    g = 2 * math.pi / 365 * (n - 1 + (hour - 12) / 24)
    eqtime = 229.18 * (0.000075 + 0.001868 * math.cos(g) - 0.032077 * math.sin(g)
                       - 0.014615 * math.cos(2 * g) - 0.040849 * math.sin(2 * g))
    decl = (0.006918 - 0.399912 * math.cos(g) + 0.070257 * math.sin(g)
            - 0.006758 * math.cos(2 * g) + 0.000907 * math.sin(2 * g)
            - 0.002697 * math.cos(3 * g) + 0.00148 * math.sin(3 * g))
    tst = hour * 60 + eqtime + 4 * lon - 60 * tz_hours
    ha = math.radians(tst / 4 - 180)
    la = math.radians(lat)
    cosz = (math.sin(la) * math.sin(decl)
            + math.cos(la) * math.cos(decl) * math.cos(ha))
    return math.degrees(math.asin(max(-1.0, min(1.0, cosz))))


def get(host, path):
    with urllib.request.urlopen("http://%s%s" % (host, path), timeout=6) as r:
        return json.load(r)


def post(host, path, payload):
    req = urllib.request.Request(
        "http://%s%s" % (host, path),
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=6) as r:
        return r.read().decode()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("target", help="brightness percentage to aim for, or 'restore'")
    ap.add_argument("--host", required=True, help="clock IP or hostname")
    ap.add_argument("--tz", type=float, default=5.5,
                    help="timezone hours; must match the firmware's TZ_OFFSET (default 5.5)")
    args = ap.parse_args()

    cfg = get(args.host, "/api/config")

    if args.target == "restore":
        if not os.path.exists(SAVED):
            sys.exit("No saved longitude. Set it by hand: POST /api/config {\"lon\": <yours>}")
        with open(SAVED) as f:
            real = json.load(f)["lon"]
        post(args.host, "/api/config", {"lon": real})
        print("longitude restored to %.2f" % real)
        return

    if not os.path.exists(SAVED):
        with open(SAVED, "w") as f:
            json.dump({"lon": cfg["lon"]}, f)
        print("saved real longitude %.2f for restore" % cfg["lon"])

    st = get(args.host, "/api/state")
    lat = cfg["lat"]
    low, high = cfg["sunLow"], cfg["sunHigh"]
    night, full = cfg["sunNight"], cfg["sunFull"]
    if full == night:
        sys.exit("sunFull == sunNight, there is no range to aim within")

    target = int(args.target)
    t = max(0.0, min(1.0, (target - night) / float(full - night)))
    want_elev = low + t * (high - low)

    # Use the clock's own clock, not this machine's -- they can differ.
    d = [int(x) for x in st["date"].split("-")]
    hm = [int(x) for x in st["time"].split(":")]
    now = datetime.datetime(d[0], d[1], d[2], hm[0], hm[1])

    # Brute-force search: 1441 cheap evaluations, and it cannot miss the way a
    # closed-form inversion can when the target elevation is unreachable today.
    best, best_err = None, 1e9
    lon = -180.0
    while lon <= 180.0:
        err = abs(elevation(lat, lon, args.tz, now) - want_elev)
        if err < best_err:
            best, best_err = lon, err
        lon += 0.25

    got = elevation(lat, best, args.tz, now)
    got_pct = night + round((full - night) * max(0.0, min(1.0, (got - low) / (high - low))))
    print("clock time  %s %s" % (st["date"], st["time"]))
    print("target      %d%% (needs elevation %.2f deg)" % (target, want_elev))
    print("longitude   %.2f -> elevation %.2f deg -> %d%%" % (best, got, got_pct))
    if abs(got_pct - target) > 1:
        print("note: closest achievable today is %d%%" % got_pct)
    post(args.host, "/api/config", {"lon": best})
    print("applied. restore with:  py tools_fake_sun.py --host %s restore" % args.host)


main()
