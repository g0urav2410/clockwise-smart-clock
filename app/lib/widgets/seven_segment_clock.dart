import 'package:flutter/material.dart';

/// Renders the clock's real 7-segment digit face, matching the shapes drawn
/// by the HA Lovelace card (`clockwise-card.js`, `SEGP`/`SEG` constants) so
/// the app's Home screen shows literally the same clock face as HA does.
/// Segment polygon points are copied 1:1 from the card's SVG (viewBox 0 0 46 84).
const Map<String, List<Offset>> _segPoints = {
  'a': [Offset(11, 3), Offset(35, 3), Offset(38.5, 6.5), Offset(35, 10), Offset(11, 10), Offset(7.5, 6.5)],
  'b': [Offset(37, 13), Offset(40.5, 9.5), Offset(44, 13), Offset(44, 35), Offset(40.5, 38.5), Offset(37, 35)],
  'c': [Offset(37, 49), Offset(40.5, 45.5), Offset(44, 49), Offset(44, 71), Offset(40.5, 74.5), Offset(37, 71)],
  'd': [Offset(11, 74), Offset(35, 74), Offset(38.5, 77.5), Offset(35, 81), Offset(11, 81), Offset(7.5, 77.5)],
  'e': [Offset(2, 49), Offset(5.5, 45.5), Offset(9, 49), Offset(9, 71), Offset(5.5, 74.5), Offset(2, 71)],
  'f': [Offset(2, 13), Offset(5.5, 9.5), Offset(9, 13), Offset(9, 35), Offset(5.5, 38.5), Offset(2, 35)],
  'g': [Offset(11, 38.5), Offset(35, 38.5), Offset(38.5, 42), Offset(35, 45.5), Offset(11, 45.5), Offset(7.5, 42)],
};

/// Which segments are lit for each digit — same table as the card's `SEG`.
const Map<String, String> _segForDigit = {
  '0': 'abcdef', '1': 'bc', '2': 'abged', '3': 'abgcd', '4': 'fgbc',
  '5': 'afgcd', '6': 'afgedc', '7': 'abc', '8': 'abcdefg', '9': 'abcfgd',
};

const _onColor = Color(0xFFF4F6FF);
const _offColor = Color(0xFF2C3038);
const double _designW = 46, _designH = 84;

class SevenSegDigit extends StatelessWidget {
  final String char; // '0'-'9' or ' ' for blank spacer
  final double height;
  const SevenSegDigit(this.char, {super.key, this.height = 84});

  @override
  Widget build(BuildContext context) {
    final w = height * _designW / _designH;
    if (char == ' ') return SizedBox(width: w, height: height);
    return SizedBox(
      width: w,
      height: height,
      child: CustomPaint(
        painter: _DigitPainter(_segForDigit[char] ?? ''),
      ),
    );
  }
}

class _DigitPainter extends CustomPainter {
  final String lit;
  _DigitPainter(this.lit);

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / _designW, sy = size.height / _designH;
    for (final entry in _segPoints.entries) {
      final on = lit.contains(entry.key);
      final path = Path()
        ..addPolygon(
          entry.value.map((p) => Offset(p.dx * sx, p.dy * sy)).toList(),
          true,
        );
      if (on) {
        canvas.drawPath(
          path,
          Paint()
            ..color = _onColor.withValues(alpha: 0.45)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
        );
      }
      canvas.drawPath(path, Paint()..color = on ? _onColor : _offColor);
    }
  }

  @override
  bool shouldRepaint(covariant _DigitPainter old) => old.lit != lit;
}

/// A row of digits for a number/string, spaces become blank spacers —
/// mirrors the card's `digitsHTML`.
class SevenSegRow extends StatelessWidget {
  final String text;
  final double height;
  final double gap;
  const SevenSegRow(this.text, {super.key, this.height = 84, this.gap = 2});

  @override
  Widget build(BuildContext context) {
    final chars = text.split('');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < chars.length; i++) ...[
          if (i > 0) SizedBox(width: gap),
          SevenSegDigit(chars[i], height: height),
        ],
      ],
    );
  }
}

/// The two blinking colon dots + the small logo dot above them, matching
/// `.cw .colon` in the card.
class SevenSegColon extends StatelessWidget {
  final bool dotsOn;
  final bool logoOn;
  final double height;
  const SevenSegColon({super.key, required this.dotsOn, this.logoOn = false, this.height = 84});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 26,
      height: height,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 9,
            height: 9,
            margin: const EdgeInsets.only(bottom: 10),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: logoOn ? const Color(0xFFFF3B3B) : const Color(0xFF26282E),
              boxShadow: logoOn
                  ? [const BoxShadow(color: Color(0x99FF3B3B), blurRadius: 9, spreadRadius: 2)]
                  : null,
            ),
          ),
          _dot(dotsOn),
          const SizedBox(height: 18),
          _dot(dotsOn),
        ],
      ),
    );
  }

  Widget _dot(bool on) => Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _onColor.withValues(alpha: on ? 1 : 0.12),
          boxShadow: on
              ? const [BoxShadow(color: Color(0x8CE6EEFF), blurRadius: 8, spreadRadius: 0.5)]
              : null,
        ),
      );
}

/// Mon..Sun vertical day list, matching `.cw .dowcol` — the current day glows,
/// the rest sit dim. `monSunIndex` is 0=Mon..6=Sun (convert from the API's
/// 0=Sun..6=Sat `dow` via `(apiDow + 6) % 7`).
class SevenSegDowColumn extends StatelessWidget {
  static const _days = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
  final int monSunIndex;
  final double height;
  const SevenSegDowColumn({super.key, required this.monSunIndex, this.height = 96});

  @override
  Widget build(BuildContext context) {
    // Sized to its own natural content, not forced into `height` — forcing 7
    // lines into a box shorter than they actually need silently overflowed
    // past the bottom of the column and painted over the amber bar below it.
    // The parent Row centers this against the (taller) digits anyway.
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < _days.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1.5),
            child: Text(
              _days[i],
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 10,
                height: 1.0,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.0,
                color: i == monSunIndex ? _onColor : const Color(0xFF31353D),
                shadows: i == monSunIndex
                    ? const [Shadow(color: Color(0xA6E6EEFF), blurRadius: 8)]
                    : null,
              ),
            ),
          ),
      ],
    );
  }
}

/// The amber divider bar between the time face and the D/M/Y row, matching
/// `.cw .amber`.
class SevenSegAmberBar extends StatelessWidget {
  const SevenSegAmberBar({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 4,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(3),
        gradient: const LinearGradient(colors: [Color(0xFFF5A623), Color(0xFFE8890A)]),
        boxShadow: [BoxShadow(color: const Color(0xFFF5A623).withValues(alpha: 0.4), blurRadius: 10)],
      ),
    );
  }
}

/// A small digit group with a "D"/"M"/"Y" label under it, matching `.cw .grp`.
class SevenSegLabeledGroup extends StatelessWidget {
  final String value;
  final String label;
  final double height;
  const SevenSegLabeledGroup({super.key, required this.value, required this.label, this.height = 34});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        SevenSegRow(value, height: height, gap: 1.5),
        const SizedBox(width: 3),
        Padding(
          padding: const EdgeInsets.only(bottom: 3),
          child: Text(
            label,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF525863), letterSpacing: 0.8),
          ),
        ),
      ],
    );
  }
}

/// The dark radial-gradient panel background used behind the digits,
/// matching `.cw .panel` in the card.
class SevenSegPanel extends StatelessWidget {
  final Widget child;
  const SevenSegPanel({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: const RadialGradient(
          center: Alignment(0, -1),
          radius: 1.3,
          colors: [Color(0xFF14161C), Color(0xFF030304)],
          stops: [0.0, 0.78],
        ),
      ),
      child: child,
    );
  }
}
