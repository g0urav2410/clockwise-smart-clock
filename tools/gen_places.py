"""Regenerates app/assets/world_places.txt and app/lib/services/countries.dart.

The picker lists cities *and* states. States alone failed the obvious test --
nobody thinks "I live in England", they think "I live in London" -- and cities
alone leave a villager stuck with nothing to pick. Together, either search
works, and the file is small enough that offering both costs nothing.

Cities carry their own coordinates and are exact. A state carries a
population-weighted centre, so it lands where people actually live rather than
in an empty corner; that can be ~100km out, worth about four minutes of
sunrise, which is invisible in a half-hour brightness ramp. GPS remains the
exact option for anyone who wants it.

A state takes the timezone most of its population uses. 54 of ~2,700 span two
zones (US Indiana, Kentucky, ...); the minority side there needs GPS.

Source data:

    curl -sLO https://download.geonames.org/export/dump/cities15000.zip
    unzip cities15000.zip
    curl -sLO https://download.geonames.org/export/dump/admin1CodesASCII.txt
    curl -sLO https://raw.githubusercontent.com/eggert/tz/main/iso3166.tab
    curl -sLO https://raw.githubusercontent.com/eggert/tz/main/backward

GeoNames is CC BY 4.0 -- the app must credit it.

known_zones.txt is the zones the bundled `timezone` Dart package has data
for; it lags the tz database, and a region in a zone it doesn't know can't be
converted to a POSIX rule. Dump it with a throwaway test:

    tz.timeZoneDatabase.locations.keys   (after initializeTimeZones())

Then run this with all five files alongside it.
"""
import io
import os
import zipfile
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(HERE, '..', 'app')
OUT_ASSET = os.path.join(APP, 'assets', 'world_places.txt')

# Below this the list balloons without adding places anyone searches for.
# 50k keeps district towns (Kathua is 60k) while halving the file.
MIN_CITY_POP = 50000
OUT_DART = os.path.join(APP, 'lib', 'services', 'countries.dart')

def load_links(path):
    """tz's `backward` file: alias -> canonical, e.g. Europe/Oslo ->
    Europe/Berlin.

    timezone 0.11 ships canonical zones only, so GeoNames names like
    Europe/Oslo or Asia/Kuala_Lumpur aren't in it and whole countries would
    drop out. The alias and its target are the same zone by definition, so
    following the link is exact, not an approximation. (0.10 included the
    aliases but lacked recent splits like Asia/Barnaul -- hence 0.11 plus
    this map, which covers both.)
    """
    links = {}
    for raw in open(path, encoding='utf-8'):
        parts = raw.split('#')[0].split()
        if len(parts) >= 3 and parts[0] == 'Link':
            links[parts[2]] = parts[1]
    return links


def canonical(name, links, known, seen=None):
    """Follow the alias chain until we reach a zone the package has."""
    seen = seen or set()
    while name not in known and name in links and name not in seen:
        seen.add(name)
        name = links[name]
    return name


def cities():
    txt = os.path.join(HERE, 'cities15000.txt')
    if os.path.exists(txt):
        return open(txt, encoding='utf-8')
    zf = zipfile.ZipFile(os.path.join(HERE, 'cities15000.zip'))
    return io.TextIOWrapper(zf.open('cities15000.txt'), encoding='utf-8')


countries = {}
for line in open(os.path.join(HERE, 'iso3166.tab'), encoding='utf-8'):
    if line.startswith('#') or not line.strip():
        continue
    code, name = line.rstrip('\n').split('\t')[:2]
    countries[code] = name

admin1 = {}
for line in open(os.path.join(HERE, 'admin1.txt'), encoding='utf-8'):
    f = line.rstrip('\n').split('\t')
    if len(f) >= 2:
        admin1[f[0]] = f[1]

known = set(open(os.path.join(HERE, 'known_zones.txt'), encoding='utf-8').read().split())
links = load_links(os.path.join(HERE, 'backward'))

# key -> weighted lat/lon sums, population per timezone
acc = defaultdict(lambda: {'w': 0.0, 'lat': 0.0, 'lon': 0.0, 'tz': defaultdict(int)})

city_rows = []

for line in cities():
    f = line.rstrip('\n').split('\t')
    if len(f) < 18:
        continue
    name, lat, lon, cc, a1, pop, tzname = \
        f[1], f[4], f[5], f[8], f[10], f[14], f[17]
    if not pop.isdigit() or not cc or not a1:
        continue
    p = int(pop)
    if p <= 0:
        continue
    if p >= MIN_CITY_POP:
        city_rows.append(
            (name, cc, float(lat), float(lon), canonical(tzname, links, known)))
    a = acc['%s.%s' % (cc, a1)]
    a['w'] += p
    a['lat'] += float(lat) * p
    a['lon'] += float(lon) * p
    a['tz'][canonical(tzname, links, known)] += p

zones, zone_idx = [], {}
rows, dropped = [], []

for key, a in acc.items():
    cc = key.split('.')[0]
    name = admin1.get(key)
    if not name or a['w'] <= 0:
        continue
    tzname = max(a['tz'].items(), key=lambda kv: kv[1])[0]
    if tzname not in known:
        dropped.append('%s (%s)' % (name, tzname))
        continue
    if tzname not in zone_idx:
        zone_idx[tzname] = len(zones)
        zones.append(tzname)
    # 2dp is ~1.1km -- far finer than a region centre is meaningful to, but it
    # keeps the displayed coordinates from looking oddly rounded.
    rows.append('s|%s|%s|%.2f|%.2f|%d' % (
        name.replace('|', ' '), cc,
        a['lat'] / a['w'], a['lon'] / a['w'], zone_idx[tzname]))

for name, cc, lat, lon, tzname in city_rows:
    if tzname not in known:
        dropped.append('%s (%s)' % (name, tzname))
        continue
    if tzname not in zone_idx:
        zone_idx[tzname] = len(zones)
        zones.append(tzname)
    rows.append('c|%s|%s|%.2f|%.2f|%d'
                % (name.replace('|', ' '), cc, lat, lon, zone_idx[tzname]))

rows.sort(key=lambda r: r.split('|')[1])

os.makedirs(os.path.dirname(OUT_ASSET), exist_ok=True)
with open(OUT_ASSET, 'w', encoding='utf-8', newline='\n') as out:
    out.write('# GENERATED by tools/gen_regions.py -- do not edit.\n')
    out.write('# Place data from GeoNames (https://geonames.org), CC BY 4.0.\n')
    out.write('# Zones, one per line, then a blank line, then regions as\n')
    out.write('# name|countryCode|lat|lon|zoneIndex\n')
    out.write('\n'.join(zones))
    out.write('\n\n')
    out.write('\n'.join(rows))
    out.write('\n')

with open(OUT_DART, 'w', encoding='utf-8', newline='\n') as out:
    out.write('// GENERATED by tools/gen_regions.py -- do not edit.\n')
    out.write('//\n')
    out.write('// ISO 3166 country names, so a region reads as "Punjab, India"\n')
    out.write('// rather than "Punjab, IN".\n\n')
    out.write('const kCountryNames = <String, String>{\n')
    for code in sorted(countries):
        out.write("  '%s': '%s',\n" % (code, countries[code].replace("'", r"\'")))
    out.write('};\n')

print('places: %d (%d cities + %d states)  zones: %d  asset: %.0f KB'
      % (len(rows), len(city_rows), len(rows) - len(city_rows), len(zones),
         os.path.getsize(OUT_ASSET) / 1024))
if dropped:
    # ascii-safe: region names carry accents the Windows console can't encode
    msg = ', '.join(sorted(dropped)).encode('ascii', 'replace').decode()
    print('dropped %d in zones the bundled tz data lacks: %s' % (len(dropped), msg))
