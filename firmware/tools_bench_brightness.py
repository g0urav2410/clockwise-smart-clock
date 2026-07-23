"""Measure /api/brightness round-trip, with and without connection reuse.

Point it at the real clock:  py bench.py 192.168.0.xx
"""
import http.client, json, sys, time

host = sys.argv[1]
N = 20


def bench(reuse):
    times = []
    conn = http.client.HTTPConnection(host, 80, timeout=5) if reuse else None
    for i in range(N):
        if not reuse:
            conn = http.client.HTTPConnection(host, 80, timeout=5)
        body = json.dumps({"v": 40 + (i % 20)})
        t0 = time.perf_counter()
        conn.request("POST", "/api/brightness", body,
                     {"Content-Type": "application/json"})
        conn.getresponse().read()
        times.append((time.perf_counter() - t0) * 1000)
        if not reuse:
            conn.close()
    if reuse:
        conn.close()
    times.sort()
    return times


for reuse in (False, True):
    t = bench(reuse)
    label = "keep-alive " if reuse else "new conn   "
    print(f"{label} median {t[len(t)//2]:6.1f} ms   min {t[0]:6.1f}   max {t[-1]:6.1f}")
