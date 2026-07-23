import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:geolocator/geolocator.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// One-tap setup: read the phone's coordinates and timezone, and turn the
/// latter into the POSIX TZ rule the firmware wants.
///
/// Both halves are set once and then owned by the clock -- it applies the DST
/// rule itself on every NTP resync, so nothing here needs to run again.
class PhoneLocation {
  final double lat, lon;
  final String tzPosix;
  final String tzName;

  const PhoneLocation({
    required this.lat,
    required this.lon,
    required this.tzPosix,
    required this.tzName,
  });
}

class PhoneLocationException implements Exception {
  final String message;
  PhoneLocationException(this.message);
  @override
  String toString() => message;
}

/// Thrown separately from a plain refusal so the caller can offer to open
/// settings -- a permanently denied permission can't be re-prompted in-app.
class LocationPermanentlyDeniedException extends PhoneLocationException {
  LocationPermanentlyDeniedException()
      : super('Location permission is off for this app. '
            'Turn it on in Settings to use this.');
}

class PhoneLocationService {
  static bool _tzReady = false;

  static Future<PhoneLocation> read() async {
    final tzName = await FlutterTimezone.getLocalTimezone();
    final pos = await _position();
    return PhoneLocation(
      lat: pos.latitude,
      lon: pos.longitude,
      tzPosix:
          posixFor(tzName, fallbackOffset: DateTime.now().timeZoneOffset),
      tzName: tzName,
    );
  }

  static Future<Position> _position() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw PhoneLocationException(
          'Location is turned off on this phone. Turn it on and try again.');
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever) {
      throw LocationPermanentlyDeniedException();
    }
    if (perm == LocationPermission.denied) {
      throw PhoneLocationException('Location permission was declined.');
    }
    // A cached fix is fine: the clock only needs to know roughly where it is,
    // and waiting on a fresh GPS lock indoors can take a long while.
    final last = await Geolocator.getLastKnownPosition();
    if (last != null) return last;
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.low,
        timeLimit: Duration(seconds: 15),
      ),
    );
  }

  /// Builds a POSIX TZ string (what newlib on the ESP8266 parses) from an IANA
  /// zone name like "Asia/Kolkata".
  ///
  /// The tz package exposes transitions as instants rather than as the
  /// recurring month/week/day rule POSIX wants, so the DST window is found by
  /// walking the year and then written back as `Mmonth.week.weekday`.
  ///
  /// [fallbackOffset] covers a zone the bundled tz data doesn't have — a
  /// handful were split off after it was published, and the phone can well be
  /// sitting in one. A fixed-offset rule is then the honest answer: correct
  /// now, and correct forever for the zones in question, which don't observe
  /// DST. Without it, `getLocation` throws and setup fails outright.
  static String posixFor(String ianaName, {Duration? fallbackOffset}) {
    if (!_tzReady) {
      tzdata.initializeTimeZones();
      _tzReady = true;
    }

    final tz.Location loc;
    try {
      loc = tz.getLocation(ianaName);
    } on tz.LocationNotFoundException {
      if (fallbackOffset == null) rethrow;
      return _fixedRule(fallbackOffset);
    }
    final now = tz.TZDateTime.now(loc);
    final stdOffset = _standardOffset(loc, now);
    final stdAbbr = _abbrAt(loc, _standardMoment(loc, now));
    final base = '$stdAbbr${_posixOffset(stdOffset)}';

    final dst = _dstWindow(loc, now);
    if (dst == null) return base;

    final dstAbbr = _abbrAt(loc, dst.$1);
    final dstOffset = loc.timeZone(dst.$1.millisecondsSinceEpoch).offset;
    return '$base$dstAbbr${_posixOffset(dstOffset)}'
        ',${_posixDate(dst.$1)},${_posixDate(dst.$2)}';
  }

  static Duration _standardOffset(tz.Location loc, tz.TZDateTime at) {
    // Sample the year: the smallest offset any moment uses is standard time.
    var smallest = loc.timeZone(at.millisecondsSinceEpoch).offset;
    for (var m = 1; m <= 12; m++) {
      final probe = tz.TZDateTime(loc, at.year, m, 15);
      final off = loc.timeZone(probe.millisecondsSinceEpoch).offset;
      if (off < smallest) smallest = off;
    }
    return smallest;
  }

  /// Abbreviation for a moment known to be in the wanted half of the year.
  /// Can't assume January is standard time -- in the southern hemisphere it's
  /// the middle of DST.
  static String _abbrAt(tz.Location loc, tz.TZDateTime at) {
    final abbr = loc.timeZone(at.millisecondsSinceEpoch).abbreviation;
    // Numeric abbreviations ("+0530") aren't valid bare in a POSIX string --
    // they have to be bracketed, and plain letters are what most zones give.
    return RegExp(r'^[A-Za-z]{3,}$').hasMatch(abbr) ? abbr : '<$abbr>';
  }

  /// A moment this year that is definitely standard time, for reading the
  /// standard abbreviation. Falls back to now for zones with no DST.
  static tz.TZDateTime _standardMoment(tz.Location loc, tz.TZDateTime now) {
    final std = _standardOffset(loc, now);
    for (var m = 1; m <= 12; m++) {
      final probe = tz.TZDateTime(loc, now.year, m, 15, 12);
      if (loc.timeZone(probe.millisecondsSinceEpoch).offset == std) {
        return probe;
      }
    }
    return now;
  }

  /// Finds this year's DST window as (start, end), or null if the zone has
  /// no daylight saving.
  static (tz.TZDateTime, tz.TZDateTime)? _dstWindow(
      tz.Location loc, tz.TZDateTime now) {
    final std = _standardOffset(loc, now);

    // Probe at midday, not midnight: transitions happen around 02:00-03:00
    // local, so a midnight probe on the transition day still reads the old
    // offset and reports the change a day late -- which shifts the POSIX
    // weekday from Sunday to Monday.
    bool dstOn(tz.TZDateTime t) =>
        loc.timeZone(t.millisecondsSinceEpoch).offset != std;

    tz.TZDateTime? start, end;
    var probe = tz.TZDateTime(loc, now.year, 1, 1, 12);
    var wasDst = dstOn(probe);
    final yearEnd = tz.TZDateTime(loc, now.year + 1, 1, 1, 12);
    while (probe.isBefore(yearEnd)) {
      final isDst = dstOn(probe);
      if (isDst && !wasDst) start = probe;
      if (!isDst && wasDst) end = probe;
      wasDst = isDst;
      probe = probe.add(const Duration(days: 1));
    }
    if (start == null || end == null) return null;
    return (start, end);
  }

  /// Current UTC offset in hours for a zone, daylight saving included.
  ///
  /// Only the app's own sun-curve preview needs this — the clock works its own
  /// offset out from the POSIX rule. Reading it live rather than storing a
  /// standard offset keeps the preview matching the device in summer.
  static double offsetHoursFor(String ianaName, {double fallback = 5.5}) {
    try {
      if (!_tzReady) {
        tzdata.initializeTimeZones();
        _tzReady = true;
      }
      final loc = tz.getLocation(ianaName);
      return loc.timeZone(DateTime.now().millisecondsSinceEpoch)
              .offset
              .inMinutes /
          60.0;
    } catch (_) {
      return fallback;
    }
  }

  /// A no-DST rule for a bare offset, named the way the tz database names
  /// such zones: "<+0530>-5:30".
  static String _fixedRule(Duration offset) {
    final m = offset.inMinutes;
    final sign = m < 0 ? '-' : '+';
    final a = m.abs();
    final h = (a ~/ 60).toString().padLeft(2, '0');
    final mm = a % 60;
    final abbr = '<$sign$h${mm == 0 ? '' : mm.toString().padLeft(2, '0')}>';
    return '$abbr${_posixOffset(offset)}';
  }

  /// POSIX writes offsets inverted: UTC+5:30 is "-5:30".
  static String _posixOffset(Duration d) {
    final invert = -d.inMinutes;
    final sign = invert < 0 ? '-' : '';
    final abs = invert.abs();
    final h = abs ~/ 60, m = abs % 60;
    return m == 0 ? '$sign$h' : '$sign$h:${m.toString().padLeft(2, '0')}';
  }

  /// The Mm.w.d form: month, week-of-month (5 = last), weekday (0 = Sunday).
  static String _posixDate(tz.TZDateTime t) {
    final weekday = t.weekday % 7; // DateTime: Mon=1..Sun=7 -> POSIX Sun=0
    final week = ((t.day - 1) ~/ 7) + 1;
    final isLast = t.day + 7 > DateTime(t.year, t.month + 1, 0).day;
    return 'M${t.month}.${isLast ? 5 : week}.$weekday';
  }
}
