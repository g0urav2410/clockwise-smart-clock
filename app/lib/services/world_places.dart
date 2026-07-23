import 'package:flutter/services.dart' show rootBundle;
import 'countries.dart';

/// Somewhere the clock can be placed: a city or a state.
///
/// Both, because either alone fails someone. States alone failed the obvious
/// test — nobody thinks "I live in England", they think "I live in London" —
/// and cities alone leave a villager with nothing to pick. A city's
/// coordinates are its own and exact; a state's are its population-weighted
/// centre, which can be ~100km off and moves sunrise about four minutes. That
/// is invisible in a half-hour brightness ramp, and GPS stays the exact
/// option.
class WorldPlace {
  final String name;

  /// ISO country code, e.g. "IN".
  final String countryCode;

  final double lat, lon;

  /// IANA zone, e.g. "Asia/Kolkata". Already resolved to a name the bundled
  /// `timezone` package knows, so it always converts to a POSIX rule.
  final String zone;

  /// A state rather than a city — shown so "Punjab" the state is
  /// distinguishable from a city of the same name.
  final bool isState;

  const WorldPlace(this.name, this.countryCode, this.lat, this.lon, this.zone,
      {required this.isState});

  String get country => kCountryNames[countryCode] ?? countryCode;

  /// "Jammu, India" / "Jammu and Kashmir, India"
  String get label => '$name, $country';

  String get subtitle => isState ? '$country · state' : country;
}

/// Loads the place list from its asset, once.
///
/// An asset rather than generated Dart: 15,000 entries as source would be a
/// slow file to compile, for data that never participates in type checking.
class WorldPlaces {
  static List<WorldPlace>? _cache;

  static Future<List<WorldPlace>> load() async {
    final cached = _cache;
    if (cached != null) return cached;

    final raw = await rootBundle.loadString('assets/world_places.txt');
    final zones = <String>[];
    final out = <WorldPlace>[];
    var inZones = true;

    for (final line in raw.split('\n')) {
      if (line.startsWith('#')) continue;
      if (line.trim().isEmpty) {
        // Blank line separates the zone table from the places.
        inZones = false;
        continue;
      }
      if (inZones) {
        zones.add(line.trim());
        continue;
      }
      final f = line.split('|');
      if (f.length < 6) continue;
      out.add(WorldPlace(
          f[1], f[2], double.parse(f[3]), double.parse(f[4]),
          zones[int.parse(f[5])],
          isState: f[0] == 's'));
    }
    return _cache = out;
  }

  /// Ranked search over place and country name. Lower is better: an exact
  /// name first, then a prefix, then anywhere in it, then country-only
  /// matches — otherwise typing "india" buries the place you wanted under
  /// every other Indian one. Cities outrank states at equal quality, since a
  /// typed name is far more often a city.
  static List<WorldPlace> search(List<WorldPlace> all, String query,
      {int limit = 300}) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      // Nothing typed yet: states only, as a short browsable list. Scrolling
      // 15,000 entries is meaningless.
      return all.where((p) => p.isState).take(limit).toList();
    }

    int rank(WorldPlace p) {
      final n = p.name.toLowerCase();
      final base = n == q
          ? 0
          : n.startsWith(q)
              ? 2
              : n.contains(q)
                  ? 4
                  : 6;
      return base + (p.isState ? 1 : 0);
    }

    final hits = all
        .where((p) =>
            p.name.toLowerCase().contains(q) ||
            p.country.toLowerCase().contains(q))
        .toList();
    hits.sort((a, b) {
      final c = rank(a).compareTo(rank(b));
      return c != 0 ? c : a.label.compareTo(b.label);
    });
    return hits.length > limit ? hits.sublist(0, limit) : hits;
  }

  /// Closest place to a set of coordinates, for labelling a clock set by GPS
  /// or configured elsewhere. Squared degrees rather than a great-circle
  /// distance: close enough to pick the same one, and this runs on rebuilds.
  static WorldPlace? nearest(List<WorldPlace> all, double lat, double lon) {
    WorldPlace? best;
    var bestD = double.infinity;
    for (final p in all) {
      final dy = p.lat - lat, dx = p.lon - lon;
      final d = dy * dy + dx * dx;
      if (d < bestD) {
        bestD = d;
        best = p;
      }
    }
    return best;
  }
}
