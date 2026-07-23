#!/usr/bin/env python3
"""Render the project's Markdown docs into styled static HTML pages for the site.

Run from the repo root:  python docs/build.py
Source of truth stays the .md files; this just produces browsable versions under
docs/ that match the site's look. Re-run after editing any doc.
"""
import os, markdown

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT  = os.path.join(ROOT, "docs")

# (source .md, output .html, nav/card title, one-line description)
PAGES = [
    ("MANUAL.md",                      "manual.html",            "Manual",
     "Set up and use the clock day to day, plus troubleshooting."),
    ("homeassistant/README.md",        "home-assistant.html",    "Home Assistant",
     "Add the clock to Home Assistant and install the clock-face card."),
    ("hardware/REVERSE_ENGINEERING.md","reverse-engineering.html","Reverse engineering",
     "How the original display was decoded and driven."),
    ("hardware/SEGMENT_MAP.md",        "segment-map.html",       "Segment map",
     "The 7-segment wiring / bit map used by the firmware."),
]

NAV = """
<div class="nav"><div class="row">
  <a class="brand" href="index.html"><span class="dot"></span> Clockwise</a>
  <nav>
    <a href="index.html">Home</a>
    <a href="index.html#flash">Flash</a>
    <a href="docs.html">Docs</a>
    <a class="gh" href="https://github.com/g0urav2410/clockwise-smart-clock">GitHub</a>
  </nav>
</div></div>
"""

FOOTER = """
<footer class="site">Open source (GPL v3) · built on the ESP8266 ·
<a href="https://github.com/g0urav2410/clockwise-smart-clock">source on GitHub</a></footer>
"""

PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} — Clockwise</title>
<meta name="description" content="{desc}">
<link rel="stylesheet" href="assets/site.css">
</head>
<body>
{nav}
<article class="doc">
<a class="back" href="docs.html">← All docs</a>
{body}
</article>
{footer}
</body>
</html>
"""

def convert(md_text):
    return markdown.markdown(
        md_text,
        extensions=["extra", "toc", "sane_lists", "admonition"],
        output_format="html5",
    )

def build_page(md_path, out_html, title, desc):
    with open(os.path.join(ROOT, md_path), encoding="utf-8") as f:
        body = convert(f.read())
    html = PAGE.format(title=title, desc=desc, nav=NAV, body=body, footer=FOOTER)
    with open(os.path.join(OUT, out_html), "w", encoding="utf-8") as f:
        f.write(html)
    print("wrote", out_html)

def build_hub():
    cards = "\n".join(
        f'<a href="{out}"><h3>{title}</h3><p>{desc}</p></a>'
        for _, out, title, desc in PAGES
    )
    body = f"""
<h1>Documentation</h1>
<p class="lede" style="margin-bottom:6px">Everything you need to build, flash, use, and extend Clockwise.</p>
<div class="docgrid">{cards}</div>
"""
    html = PAGE.format(title="Docs", desc="Clockwise documentation.",
                       nav=NAV, body=body, footer=FOOTER)
    # the hub has no "All docs" back-link; drop it
    html = html.replace('<a class="back" href="docs.html">← All docs</a>\n', "")
    with open(os.path.join(OUT, "docs.html"), "w", encoding="utf-8") as f:
        f.write(html)
    print("wrote docs.html")

if __name__ == "__main__":
    for p in PAGES:
        build_page(*p)
    build_hub()
    print("done.")
