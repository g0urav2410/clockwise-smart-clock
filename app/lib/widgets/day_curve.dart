import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// The clock's brightness across the whole day, as a filled curve.
///
/// Replaced a row of shaded blocks. Shading alone could not show the middle
/// hours differing -- the eye can't rank opacity that finely -- so a day that
/// varied smoothly looked flat. Height can be read directly, and the shape of
/// the day becomes obvious.
///
/// Daylight is drawn warm and night cool. That is redundant with the shaded
/// background and with the sunrise/sunset figures beneath, deliberately: two
/// cues make the boundary quicker to find, even though neither adds
/// information the other lacks.
class DayCurve extends StatelessWidget {
  /// Brightness percentage per sample, evenly spaced from midnight. More
  /// samples make a smoother line; 96 (15-minute steps) is plenty.
  final List<int> brightness;

  /// Minutes since midnight.
  final int nowMinute;
  final int? riseMinute, setMinute, peakMinute;

  final double height;

  const DayCurve({
    super.key,
    required this.brightness,
    required this.nowMinute,
    this.riseMinute,
    this.setMinute,
    this.peakMinute,
    this.height = 104,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<ClockColors>()!;
    return SizedBox(
      height: height,
      child: CustomPaint(
        size: Size.infinite,
        painter: _DayCurvePainter(
          brightness: brightness,
          nowMinute: nowMinute,
          riseMinute: riseMinute,
          setMinute: setMinute,
          peakMinute: peakMinute,
          day: c.amber,
          night: c.cyan,
          axis: c.divider,
          label: c.muted,
          marker: c.title,
          pill: c.card,
          pillBorder: c.cardBorder,
        ),
      ),
    );
  }
}

class _DayCurvePainter extends CustomPainter {
  final List<int> brightness;
  final int nowMinute;
  final int? riseMinute, setMinute, peakMinute;
  final Color day, night, axis, label, marker, pill, pillBorder;

  _DayCurvePainter({
    required this.brightness,
    required this.nowMinute,
    required this.riseMinute,
    required this.setMinute,
    required this.peakMinute,
    required this.day,
    required this.night,
    required this.axis,
    required this.label,
    required this.marker,
    required this.pill,
    required this.pillBorder,
  });

  static const _left = 22.0, _right = 20.0, _top = 22.0, _bottom = 16.0;

  @override
  void paint(Canvas canvas, Size size) {
    final n = brightness.length;
    if (n < 2 || size.width <= _left + _right) return;

    double x(num minute) =>
        _left + (minute / 1440) * (size.width - _left - _right);
    double y(num pct) =>
        size.height - _bottom - (pct / 100) * (size.height - _bottom - _top);

    final plotTop = _top, plotBottom = size.height - _bottom;

    // Night bands, drawn first so everything else sits on top.
    if (riseMinute != null && setMinute != null) {
      final band = Paint()..color = night.withValues(alpha: 0.07);
      canvas.drawRect(
          Rect.fromLTRB(x(0), plotTop, x(riseMinute!), plotBottom), band);
      canvas.drawRect(
          Rect.fromLTRB(x(setMinute!), plotTop, x(1440), plotBottom), band);
    }

    // Gridlines at 0/50/100 with labels.
    for (final v in [0, 50, 100]) {
      canvas.drawLine(
        Offset(x(0), y(v)),
        Offset(size.width - _right, y(v)),
        Paint()
          ..color = axis.withValues(alpha: v == 0 ? 0.9 : 0.45)
          ..strokeWidth = 1,
      );
      _text(canvas, '$v', Offset(_left - 5, y(v)),
          color: label, size: 8.5, alignRight: true);
    }

    // The curve, as a path plus a filled version clipped per day/night section.
    final line = Path();
    final fill = Path()..moveTo(x(0), y(0));
    for (var i = 0; i < n; i++) {
      final m = (i * 1440) / (n - 1);
      final p = Offset(x(m), y(brightness[i]));
      if (i == 0) {
        line.moveTo(p.dx, p.dy);
      } else {
        line.lineTo(p.dx, p.dy);
      }
      fill.lineTo(p.dx, p.dy);
    }
    fill
      ..lineTo(x(1440), y(0))
      ..close();

    void fillBetween(double a, double b, Color colour, double alpha) {
      canvas.save();
      canvas.clipRect(Rect.fromLTRB(a, plotTop, b, plotBottom));
      canvas.drawPath(fill, Paint()..color = colour.withValues(alpha: alpha));
      canvas.restore();
    }

    if (riseMinute != null && setMinute != null) {
      fillBetween(x(0), x(riseMinute!), night, 0.30);
      fillBetween(x(riseMinute!), x(setMinute!), day, 0.22);
      fillBetween(x(setMinute!), x(1440), night, 0.30);
    } else {
      fillBetween(x(0), x(1440), day, 0.22);
    }

    canvas.drawPath(
      line,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..color = day,
    );

    if (peakMinute != null) {
      final i = ((peakMinute! / 1440) * (n - 1)).round().clamp(0, n - 1);
      canvas.drawCircle(
          Offset(x(peakMinute!), y(brightness[i])), 2.4, Paint()..color = day);
    }

    // Hour ticks.
    const ticks = {0: '12a', 360: '6a', 720: '12p', 1080: '6p', 1440: '12a'};
    ticks.forEach((m, t) {
      _text(canvas, t, Offset(x(m), size.height - 10), color: label, size: 8.5);
    });

    // Now: drop line, label pill, then the dot on top.
    final idx = ((nowMinute / 1440) * (n - 1)).round().clamp(0, n - 1);
    final nx = x(nowMinute), ny = y(brightness[idx]);
    canvas.drawLine(
      Offset(nx, ny),
      Offset(nx, plotBottom),
      Paint()
        ..color = marker.withValues(alpha: 0.35)
        ..strokeWidth = 1,
    );

    final txt = '${brightness[idx]}% · ${_clock(nowMinute)}';
    final tp = _painter(txt, marker, 9.5);
    final pw = tp.width + 12, ph = 14.0;
    // Flip to whichever side has room, and never let it ride off the top.
    final flip = nx + pw + 7 > size.width - _right;
    final cx = flip ? nx - pw / 2 - 7 : nx + pw / 2 + 7;
    final cy = (ny - 13).clamp(plotTop - 4, plotBottom);
    final rect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(cx, cy), width: pw, height: ph),
      const Radius.circular(7),
    );
    canvas.drawRRect(rect, Paint()..color = pill);
    canvas.drawRRect(
      rect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..color = pillBorder,
    );
    tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));

    canvas.drawCircle(Offset(nx, ny), 4, Paint()..color = pill);
    canvas.drawCircle(
      Offset(nx, ny),
      4,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..color = marker,
    );
  }

  static String _clock(int m) {
    final h = m ~/ 60;
    return '${(h % 12) == 0 ? 12 : h % 12}:${(m % 60).toString().padLeft(2, '0')}${h < 12 ? 'a' : 'p'}';
  }

  TextPainter _painter(String s, Color colour, double size) => TextPainter(
        text: TextSpan(
            text: s,
            style: TextStyle(
                color: colour,
                fontSize: size,
                fontFeatures: const [FontFeature.tabularFigures()])),
        textDirection: TextDirection.ltr,
      )..layout();

  void _text(Canvas canvas, String s, Offset at,
      {required Color color, required double size, bool alignRight = false}) {
    final tp = _painter(s, color, size);
    tp.paint(
      canvas,
      Offset(alignRight ? at.dx - tp.width : at.dx - tp.width / 2,
          at.dy - tp.height / 2),
    );
  }

  @override
  bool shouldRepaint(_DayCurvePainter old) =>
      old.nowMinute != nowMinute ||
      old.riseMinute != riseMinute ||
      old.setMinute != setMinute ||
      old.day != day ||
      !_same(old.brightness, brightness);

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
