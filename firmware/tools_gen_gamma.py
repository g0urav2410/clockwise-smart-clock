GAMMA = 1.8

# 0% is genuinely off. Every other step must light the display -- gamma 2.2
# mapped 1-3% to duty 0, so the bottom of the slider did nothing.
vals = [0] + [max(1, round((p / 100.0) ** GAMMA * 1023)) for p in range(1, 101)]

assert vals[0] == 0
assert all(v >= 1 for v in vals[1:]), "dead zone above 0%"
assert vals[100] == 1023
assert all(b >= a for a, b in zip(vals, vals[1:])), "not monotonic"
dupes = sum(1 for a, b in zip(vals[1:], vals[2:]) if a == b)
print(f"// gamma {GAMMA}, {dupes} repeated steps at the low end")
for i in range(0, 101, 10):
    print("    " + ", ".join("%4d" % v for v in vals[i:i + 10]) + ",")
