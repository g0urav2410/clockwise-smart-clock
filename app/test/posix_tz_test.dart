import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:clock_app/services/phone_location.dart';

/// The POSIX TZ string is what the firmware stores and what newlib parses to
/// apply DST on its own, so getting it wrong means a clock an hour out for
/// half the year. These are the canonical strings for each zone.
void main() {
  test('no DST, half-hour offset', () {
    expect(PhoneLocationService.posixFor('Asia/Kolkata'), 'IST-5:30');
  });

  test('no DST, 45-minute offset', () {
    expect(PhoneLocationService.posixFor('Asia/Kathmandu'), '<+0545>-5:45');
  });

  test('northern hemisphere DST', () {
    expect(PhoneLocationService.posixFor('America/New_York'),
        'EST5EDT4,M3.2.0,M11.1.0');
    expect(PhoneLocationService.posixFor('Europe/Berlin'),
        'CET-1CEST-2,M3.5.0,M10.5.0');
  });

  test('last-Sunday rules use week 5', () {
    expect(PhoneLocationService.posixFor('Europe/London'),
        'GMT0BST-1,M3.5.0,M10.5.0');
  });

  // The one most likely to break: January is DST here, not standard time, so
  // anything that samples January for the standard abbreviation gets it wrong.
  test('southern hemisphere, DST spans the new year', () {
    expect(PhoneLocationService.posixFor('Australia/Sydney'),
        'AEST-10AEDT-11,M10.1.0,M4.1.0');
    expect(PhoneLocationService.posixFor('Pacific/Auckland'),
        'NZST-12NZDT-13,M9.5.0,M4.1.0');
  });

  test('numeric abbreviations get bracketed', () {
    expect(PhoneLocationService.posixFor('Asia/Dubai'), '<+04>-4');
    expect(PhoneLocationService.posixFor('America/Sao_Paulo'), '<-03>3');
  });

  // timezone 0.11 dropped the bare "UTC" name in favour of "Etc/UTC". A phone
  // can still report the old one, which is why read() always passes a
  // fallback offset -- without it this would throw during setup.
  test('UTC', () {
    expect(PhoneLocationService.posixFor('Etc/UTC'), 'UTC0');
    expect(PhoneLocationService.posixFor('UTC', fallbackOffset: Duration.zero),
        '<+00>0');
  });

  // A zone split off after the bundled tz data was published. Someone's phone
  // can be sitting in one, so this must degrade rather than throw.
  test('unknown zone falls back to a fixed-offset rule', () {
    expect(
        PhoneLocationService.posixFor('Asia/Barnaul',
            fallbackOffset: const Duration(hours: 7)),
        '<+07>-7');
    expect(
        PhoneLocationService.posixFor('Nowhere/Fake',
            fallbackOffset: const Duration(hours: -3, minutes: -30)),
        '<-0330>3:30');
    expect(() => PhoneLocationService.posixFor('Nowhere/Fake'), throwsA(anything));
  });
  // Guards the integration between the region list and the tz package: every
  // zone the picker can offer must convert to something newlib will parse, or
  // a user picks a place and the clock silently keeps the old rule. Reads the
  // asset directly -- rootBundle isn't available in a plain unit test.
  test('every zone in the picker converts to a plausible POSIX rule', () {
    final raw = File('assets/world_places.txt').readAsStringSync();
    final zones = <String>[];
    for (final line in raw.split('\n')) {
      if (line.startsWith('#')) continue;
      if (line.trim().isEmpty) break;
      zones.add(line.trim());
    }
    expect(zones.length, greaterThan(200));

    final bad = <String>[];
    for (final name in zones) {
      try {
        final s = PhoneLocationService.posixFor(name);
        // name+offset, optionally a DST half and two Mm.w.d transition rules
        final ok = RegExp(
                r'^(?:[A-Za-z]{3,}|<[+-][0-9]+>)-?\d{1,2}(?::\d{2})?'
                r'(?:(?:[A-Za-z]{3,}|<[+-][0-9]+>)-?\d{1,2}(?::\d{2})?'
                r',M\d{1,2}\.[1-5]\.[0-6],M\d{1,2}\.[1-5]\.[0-6])?$')
            .hasMatch(s);
        if (!ok) bad.add('$name -> $s');
      } catch (e) {
        bad.add('$name threw $e');
      }
    }
    expect(bad, isEmpty, reason: '${bad.length} bad:\n${bad.take(15).join("\n")}');
  });
}
