"""Reference solar-elevation calc, to check the firmware's version against."""
import math, datetime

def elevation(lat, lon, tz_hours, dt):
    N = dt.timetuple().tm_yday
    hour = dt.hour + dt.minute / 60 + dt.second / 3600
    g = 2 * math.pi / 365 * (N - 1 + (hour - 12) / 24)
    eqtime = 229.18 * (0.000075 + 0.001868 * math.cos(g) - 0.032077 * math.sin(g)
                       - 0.014615 * math.cos(2 * g) - 0.040849 * math.sin(2 * g))
    decl = (0.006918 - 0.399912 * math.cos(g) + 0.070257 * math.sin(g)
            - 0.006758 * math.cos(2 * g) + 0.000907 * math.sin(2 * g)
            - 0.002697 * math.cos(3 * g) + 0.00148 * math.sin(3 * g))
    time_offset = eqtime + 4 * lon - 60 * tz_hours
    tst = hour * 60 + time_offset
    ha = math.radians(tst / 4 - 180)
    la = math.radians(lat)
    cosz = math.sin(la) * math.sin(decl) + math.cos(la) * math.cos(decl) * math.cos(ha)
    return math.degrees(math.asin(max(-1, min(1, cosz))))

if __name__ == "__main__":
    LAT, LON, TZ = 20.59, 78.96, 5.5
    day = datetime.date(2026, 7, 18)
    print(f"lat {LAT} lon {LON} tz +{TZ}  on {day}")
    for h in range(0, 24, 2):
        dt = datetime.datetime.combine(day, datetime.time(h, 0))
        print(f"  {h:02d}:00  elevation {elevation(LAT, LON, TZ, dt):7.2f} deg")
    # crossing points
    prev = None
    for m in range(0, 1440):
        dt = datetime.datetime.combine(day, datetime.time(m // 60, m % 60))
        e = elevation(LAT, LON, TZ, dt)
        if prev is not None and prev < 0 <= e:
            print(f"  sunrise ~ {m//60:02d}:{m%60:02d}")
        if prev is not None and prev >= 0 > e:
            print(f"  sunset  ~ {m//60:02d}:{m%60:02d}")
        prev = e
