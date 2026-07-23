"""Check every letter the firmware draws actually fits the digit it is drawn on.

This dial is missing segments on three positions (date tens has no f, year
thousands no c/f, year hundreds no g), and setSeg() silently ignores a -1. So a
letter placed on the wrong digit does not fail to build and does not throw --
it just renders as a wrong shape on the wall, which is only discoverable by
holding the reset button and squinting at it.

Parses main.cpp rather than taking a copy of the segment map, so it cannot
drift out of step with the firmware. Run: python tools/check_glyphs.py
"""
import re
import sys
import pathlib

SRC = pathlib.Path(__file__).resolve().parent.parent / "firmware_pio" / "src" / "main.cpp"
NAMES = "abcdefg"


def seg_arrays(text):
    """Every `const int NAMEseg[7] = {...}` -> {name: [7 output numbers]}."""
    out = {}
    for m in re.finditer(r"const int (\w+)\[7\]\s*=\s*\{([^}]*)\}", text):
        vals = [int(v.strip()) for v in m.group(2).split(",")]
        assert len(vals) == 7, m.group(1)
        out[m.group(1)] = vals
    return out


def glyphs(text):
    """Every `GL_X = 0xNN` -> {'X': mask}."""
    return {m.group(1): int(m.group(2), 16)
            for m in re.finditer(r"GL_(\w+)\s*=\s*(0x[0-9A-Fa-f]+)", text)}


def draw_calls(text):
    """Every putGlyph(SEG, GL_X) actually in the source -> [(seg, letter, line)]."""
    calls = []
    for i, line in enumerate(text.splitlines(), 1):
        for m in re.finditer(r"putGlyph\((\w+),\s*GL_(\w+)\)", line):
            calls.append((m.group(1), m.group(2), i))
    return calls


def main(argv):
    src = pathlib.Path(argv[1]) if len(argv) > 1 else SRC
    text = src.read_text(encoding="utf-8", errors="replace")
    segs, gl, calls = seg_arrays(text), glyphs(text), draw_calls(text)

    if not calls:
        print("no putGlyph calls found -- did the parser break?")
        return 1

    bad = []
    for seg_name, letter, line in calls:
        if seg_name not in segs:
            bad.append(f"{src.name}:{line} unknown segment array {seg_name}")
            continue
        if letter not in gl:
            bad.append(f"{src.name}:{line} unknown glyph GL_{letter}")
            continue
        missing = [NAMES[s] for s in range(7)
                   if (gl[letter] >> s) & 1 and segs[seg_name][s] == -1]
        if missing:
            bad.append(f"{src.name}:{line} '{letter}' on {seg_name} needs "
                       f"segment {','.join(missing)}, which this digit lacks")

    if bad:
        print(f"{len(bad)} problem(s) in {len(calls)} glyph draws:")
        for b in bad:
            print("  " + b)
        return 1
    print(f"all {len(calls)} glyph draws fit their digit")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
