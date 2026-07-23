import 'dart:math' as math;

/// Same solar maths the firmware runs, mirrored here so the app can *explain*
/// what sun mode will do — in clock times, which people understand, rather
/// than elevation angles, which they don't.
class SunMath {
  /// Both day-wide calculations walk the whole day, which costs tens of
  /// milliseconds -- and the screen rebuilds them on every poll, about once a
  /// second. The answers only change when the config or the calendar date
  /// changes, so cache on exactly that.
  static final Map<String, List<double>> _shapeCache = {};
  static final Map<String, List<double>> _elevCache = {};

  /// The sun's elevation for every minute of a day, computed once and reused.
  ///
  /// Everything else here is a cheap scan over this: sunrise, sunset, the
  /// brightness shape, and the twilight crossings for any angle. That matters
  /// because the twilight sliders need to answer "what time would this angle
  /// give?" on every frame of a drag, and recomputing 1441 solar positions per
  /// frame would not fit in a frame budget.
  static List<double> dayElevations({
    required double lat,
    required double lon,
    required double tzHours,
    DateTime? date,
  }) {
    final day = date ?? DateTime.now();
    final key = _key(day, [lat, lon, tzHours]);
    final hit = _elevCache[key];
    if (hit != null) return hit;

    final midnight = DateTime(day.year, day.month, day.day);
    final out = List<double>.generate(
        1441,
        (m) => elevation(
            lat: lat,
            lon: lon,
            tzHours: tzHours,
            local: midnight.add(Duration(minutes: m))));

    if (_elevCache.length > 4) _elevCache.clear();
    return _elevCache[key] = out;
  }

  /// When the sun crosses [dawnDeg] going up and [duskDeg] coming down. Pure
  /// scan over [elevs] -- no trigonometry, so it is cheap enough to call while
  /// a slider is moving.
  static (int? start, int? end) crossings(
      List<double> elevs, double dawnDeg, double duskDeg) {
    var peak = 0;
    for (var i = 1; i < elevs.length; i++) {
      if (elevs[i] > elevs[peak]) peak = i;
    }
    int? start, end;
    for (var m = 1; m < elevs.length; m++) {
      final low = m <= peak ? dawnDeg : duskDeg;
      if (elevs[m - 1] <= low && elevs[m] > low) start ??= m;
      if (elevs[m - 1] > low && elevs[m] <= low) end = m;
    }
    return (start, end);
  }

  static String _key(DateTime day, List<Object> parts) =>
      '${day.year}-${day.month}-${day.day}|${parts.join(",")}';

  /// Sun's height above the horizon in degrees, negative when below.
  /// Standard NOAA approximation; matches the firmware's solarElevation().
  static double elevation({
    required double lat,
    required double lon,
    required double tzHours,
    required DateTime local,
  }) {
    final n = DateTime(local.year, local.month, local.day)
            .difference(DateTime(local.year, 1, 1))
            .inDays +
        1;
    final hour = local.hour + local.minute / 60 + local.second / 3600;

    final g = 2 * math.pi / 365 * (n - 1 + (hour - 12) / 24);
    final eqtime = 229.18 *
        (0.000075 +
            0.001868 * math.cos(g) -
            0.032077 * math.sin(g) -
            0.014615 * math.cos(2 * g) -
            0.040849 * math.sin(2 * g));
    final decl = 0.006918 -
        0.399912 * math.cos(g) +
        0.070257 * math.sin(g) -
        0.006758 * math.cos(2 * g) +
        0.000907 * math.sin(2 * g) -
        0.002697 * math.cos(3 * g) +
        0.00148 * math.sin(3 * g);

    final timeOffset = eqtime + 4 * lon - 60 * tzHours;
    final tst = hour * 60 + timeOffset;
    final ha = _rad(tst / 4 - 180);
    final la = _rad(lat);

    var cosz = math.sin(la) * math.sin(decl) +
        math.cos(la) * math.cos(decl) * math.cos(ha);
    cosz = cosz.clamp(-1.0, 1.0);
    return _deg(math.asin(cosz));
  }

  /// Highest the sun gets on a given day, in degrees. Mirrors the firmware's
  /// solarPeakElevation() -- the hour term in elevation() drops out exactly at
  /// solar noon, so this only needs the declination.
  static double peakElevation({required double lat, required int dayOfYear}) {
    final g = 2 * math.pi / 365 * (dayOfYear - 1);
    final decl = 0.006918 -
        0.399912 * math.cos(g) +
        0.070257 * math.sin(g) -
        0.006758 * math.cos(2 * g) +
        0.000907 * math.sin(2 * g) -
        0.002697 * math.cos(3 * g) +
        0.00148 * math.sin(3 * g);
    final la = _rad(lat);
    var cosz = math.sin(la) * math.sin(decl) + math.cos(la) * math.cos(decl);
    cosz = cosz.clamp(-1.0, 1.0);
    return _deg(math.asin(cosz));
  }

  static int _dayOfYear(DateTime day) =>
      DateTime(day.year, day.month, day.day)
          .difference(DateTime(day.year, 1, 1))
          .inDays +
      1;

  /// The *shape* of the day: how far along the night-to-midday ramp the sun is
  /// at each of [segments] slices, 0.0 to 1.0. Mirrors the firmware's sunPct(),
  /// scaled against the day's own peak in sine space rather than a fixed degree
  /// ceiling -- see the firmware's comment for why.
  ///
  /// Deliberately separate from the brightness levels. The shape depends only on
  /// where you are and what day it is, so it can be cached and reused while the
  /// brightness sliders move -- which is what lets the strip track a drag
  /// without recomputing 48 solar positions per frame.
  static List<double> dayShape({
    required double lat,
    required double lon,
    required double tzHours,
    required double dawnDeg,
    required double duskDeg,
    int segments = 48,
    DateTime? date,
  }) {
    final day = date ?? DateTime.now();
    final key = _key(day, [lat, lon, tzHours, dawnDeg, duskDeg, segments]);
    final hit = _shapeCache[key];
    if (hit != null) return hit;

    final peak = peakElevation(lat: lat, dayOfYear: _dayOfYear(day));
    final all = dayElevations(lat: lat, lon: lon, tzHours: tzHours, date: day);
    final elev = List<double>.generate(segments,
        (i) => all[((i + 0.5) * 1440 / segments).round().clamp(0, 1440)]);

    // Before the day's highest point is morning, after it is evening. Elevation
    // alone can't tell them apart -- every height happens twice -- and dawn and
    // dusk now have separate floors.
    var peakIdx = 0;
    for (var i = 1; i < segments; i++) {
      if (elev[i] > elev[peakIdx]) peakIdx = i;
    }

    final sPeak = math.sin(_rad(peak));
    final out = List<double>.generate(segments, (i) {
      final e = elev[i];
      final low = i <= peakIdx ? dawnDeg : duskDeg;
      if (e <= low) return 0.0;
      // Ramp from the twilight floor to the peak, matching the firmware. Using
      // sin(e)/sin(peak) alone breaks below the horizon: sin of a negative
      // elevation is negative, so the whole twilight clamped to zero and the
      // dusk setting had no visible effect at all.
      final sLow = math.sin(_rad(low));
      if (sPeak <= sLow + 0.001) return 1.0;
      return ((math.sin(_rad(e)) - sLow) / (sPeak - sLow)).clamp(0.0, 1.0);
    });

    if (_shapeCache.length > 8) _shapeCache.clear();
    return _shapeCache[key] = out;
  }

  static final Map<String, SunFacts> _factsCache = {};

  /// Sunrise, sunset and solar noon for a day, found by walking it at
  /// one-minute steps. Brute force on purpose: it cannot get the edge cases
  /// wrong (polar day, sun never rising) the way a closed-form inversion can.
  static SunFacts dayFacts({
    required double lat,
    required double lon,
    required double tzHours,
    DateTime? date,
  }) {
    final day = date ?? DateTime.now();
    final key = _key(day, [lat, lon, tzHours]);
    final hit = _factsCache[key];
    if (hit != null) return hit;

    final elevs = dayElevations(lat: lat, lon: lon, tzHours: tzHours, date: day);
    int? rise, set;
    var peakMin = 0;
    var peakElev = elevs[0];

    for (var m = 1; m <= 1440; m++) {
      final e = elevs[m];
      if (e > peakElev) {
        peakElev = e;
        peakMin = m;
      }
      if (elevs[m - 1] < 0 && e >= 0) rise ??= m;
      if (elevs[m - 1] >= 0 && e < 0) set = m;
    }

    if (_factsCache.length > 8) _factsCache.clear();
    return _factsCache[key] = SunFacts(
        riseMin: rise, setMin: set, peakMin: peakMin, peakElev: peakElev);
  }

  static final Map<String, (int?, int?)> _twilightCache = {};

  /// The window where the sun is above [lowDeg] -- the hours during which
  /// brightness is above the night level. The twilight setting moves both ends
  /// symmetrically, so both are worth showing: it starts lifting in the morning
  /// exactly as long before sunrise as it keeps light after sunset.
  static (int? start, int? end) twilight({
    required double lat,
    required double lon,
    required double tzHours,
    required double dawnDeg,
    required double duskDeg,
    DateTime? date,
  }) {
    final day = date ?? DateTime.now();
    final key = _key(day, [lat, lon, tzHours, dawnDeg, duskDeg]);
    final hit = _twilightCache[key];
    if (hit != null) return hit;

    final out = crossings(
        dayElevations(lat: lat, lon: lon, tzHours: tzHours, date: day),
        dawnDeg,
        duskDeg);

    if (_twilightCache.length > 8) _twilightCache.clear();
    return _twilightCache[key] = out;
  }

  /// Brightness per segment for a given night/midday pair. Cheap: the expensive
  /// part is [dayShape], which is cached.
  static List<int> brightnessFromShape(
          List<double> shape, int nightPct, int fullPct) =>
      [for (final t in shape) nightPct + ((fullPct - nightPct) * t).round()];

  static double _rad(double d) => d * math.pi / 180;
  static double _deg(double r) => r * 180 / math.pi;

}

/// Sunrise, sunset and solar noon for one day. Minutes since midnight; null
/// when the sun never crosses the horizon at all.
class SunFacts {
  final int? riseMin, setMin;
  final int peakMin;
  final double peakElev;

  const SunFacts({
    required this.riseMin,
    required this.setMin,
    required this.peakMin,
    required this.peakElev,
  });

  /// Length of daylight, or null if the sun never rose or never set.
  Duration? get daylight => (riseMin != null && setMin != null)
      ? Duration(minutes: setMin! - riseMin!)
      : null;

  static String hhmm(int? minute) {
    if (minute == null) return '—';
    final h = minute ~/ 60, m = minute % 60;
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '$h12:${m.toString().padLeft(2, '0')} ${h < 12 ? 'am' : 'pm'}';
  }
}

