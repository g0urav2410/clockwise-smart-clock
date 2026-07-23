import 'package:flutter/material.dart';

class AppTheme {
  static const Color _purple     = Color(0xFF7C4DFF);
  static const Color _blue       = Color(0xFF448AFF);
  static const Color _cyan       = Color(0xFF00E5FF);
  static const Color _green      = Color(0xFF00FF88);
  static const Color _amber      = Color(0xFFF59E0B);

  // ── Light (glassmorphism tones) ───────────────────────────────
  static ThemeData light() => ThemeData(
    brightness: Brightness.light,
    useMaterial3: true,
    colorScheme: ColorScheme.light(
      primary:   _purple,
      secondary: _blue,
      surface:   const Color(0xFFE8EAF6),
      onSurface: const Color(0xFF1A237E),
    ),
    scaffoldBackgroundColor: const Color(0xFFE8EAF6),
    extensions: [
      ClockColors(
        card:         Colors.white.withValues(alpha: 0.55),
        cardBorder:   Colors.white.withValues(alpha: 0.80),
        card2:        Colors.white.withValues(alpha: 0.40),
        card2Border:  Colors.white.withValues(alpha: 0.60),
        navBg:        Colors.white.withValues(alpha: 0.50),
        navBorder:    Colors.white.withValues(alpha: 0.70),
        title:        const Color(0xFF1A237E),
        subtitle:     const Color(0xFF5C6BC0),
        muted:        const Color(0xFF9FA8DA),
        accent:       _purple,
        accentAlt:    _blue,
        presence:     const Color(0xFF2E7D32),
        presenceBg:   const Color(0x1A4CAF50),
        presenceBdr:  const Color(0x4C4CAF50),
        pillBg:       const Color(0x1A4CAF50),
        pillText:     const Color(0xFF2E7D32),
        pillBdr:      const Color(0x4C4CAF50),
        barBg:        const Color(0x265C6BC0),
        stepBg:       const Color(0x1A5C6BC0),
        stepBdr:      const Color(0x335C6BC0),
        divider:      const Color(0x1A5C6BC0),
        online:       _green,
        amber:        _amber,
        cyan:         _cyan,
        gradientStart: _purple,
        gradientEnd:   _blue,
      ),
    ],
  );

  // ── Dark (AMOLED neon) ────────────────────────────────────────
  static ThemeData dark() => ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorScheme: ColorScheme.dark(
      primary:   _cyan,
      secondary: _purple,
      surface:   Colors.black,
      onSurface: Colors.white,
    ),
    scaffoldBackgroundColor: Colors.black,
    extensions: [
      ClockColors(
        card:        const Color(0xFF0A0A0A),
        cardBorder:  const Color(0xFF1C1C1C),
        card2:       const Color(0xFF050505),
        card2Border: const Color(0xFF141414),
        navBg:       Colors.black,
        navBorder:   const Color(0xFF111111),
        title:       Colors.white,
        subtitle:    _cyan,
        muted:       const Color(0xFF333333),
        accent:      _cyan,
        accentAlt:   _purple,
        presence:    _green,
        presenceBg:  const Color(0x0F00FF88),
        presenceBdr: const Color(0x4000FF88),
        pillBg:      const Color(0x0F00FF88),
        pillText:    _green,
        pillBdr:     const Color(0x4000FF88),
        barBg:       const Color(0xFF111111),
        stepBg:      const Color(0xFF111111),
        stepBdr:     const Color(0xFF1C1C1C),
        divider:     const Color(0xFF111111),
        online:      _green,
        amber:       _amber,
        cyan:        _cyan,
        gradientStart: _purple,
        gradientEnd:   _cyan,
      ),
    ],
  );
}

class ClockColors extends ThemeExtension<ClockColors> {
  final Color card, cardBorder, card2, card2Border;
  final Color navBg, navBorder;
  final Color title, subtitle, muted;
  final Color accent, accentAlt;
  final Color presence, presenceBg, presenceBdr;
  final Color pillBg, pillText, pillBdr;
  final Color barBg, stepBg, stepBdr, divider;
  final Color online, amber, cyan;
  final Color gradientStart, gradientEnd;

  const ClockColors({
    required this.card, required this.cardBorder,
    required this.card2, required this.card2Border,
    required this.navBg, required this.navBorder,
    required this.title, required this.subtitle, required this.muted,
    required this.accent, required this.accentAlt,
    required this.presence, required this.presenceBg, required this.presenceBdr,
    required this.pillBg, required this.pillText, required this.pillBdr,
    required this.barBg, required this.stepBg, required this.stepBdr, required this.divider,
    required this.online, required this.amber, required this.cyan,
    required this.gradientStart, required this.gradientEnd,
  });

  @override
  ClockColors copyWith({
    Color? card, Color? cardBorder, Color? card2, Color? card2Border,
    Color? navBg, Color? navBorder, Color? title, Color? subtitle, Color? muted,
    Color? accent, Color? accentAlt, Color? presence, Color? presenceBg, Color? presenceBdr,
    Color? pillBg, Color? pillText, Color? pillBdr,
    Color? barBg, Color? stepBg, Color? stepBdr, Color? divider,
    Color? online, Color? amber, Color? cyan, Color? gradientStart, Color? gradientEnd,
  }) => ClockColors(
    card: card ?? this.card, cardBorder: cardBorder ?? this.cardBorder,
    card2: card2 ?? this.card2, card2Border: card2Border ?? this.card2Border,
    navBg: navBg ?? this.navBg, navBorder: navBorder ?? this.navBorder,
    title: title ?? this.title, subtitle: subtitle ?? this.subtitle, muted: muted ?? this.muted,
    accent: accent ?? this.accent, accentAlt: accentAlt ?? this.accentAlt,
    presence: presence ?? this.presence, presenceBg: presenceBg ?? this.presenceBg,
    presenceBdr: presenceBdr ?? this.presenceBdr,
    pillBg: pillBg ?? this.pillBg, pillText: pillText ?? this.pillText, pillBdr: pillBdr ?? this.pillBdr,
    barBg: barBg ?? this.barBg, stepBg: stepBg ?? this.stepBg,
    stepBdr: stepBdr ?? this.stepBdr, divider: divider ?? this.divider,
    online: online ?? this.online, amber: amber ?? this.amber, cyan: cyan ?? this.cyan,
    gradientStart: gradientStart ?? this.gradientStart, gradientEnd: gradientEnd ?? this.gradientEnd,
  );

  @override
  ClockColors lerp(ClockColors? other, double t) {
    if (other == null) return this;
    return ClockColors(
      card: Color.lerp(card, other.card, t)!, cardBorder: Color.lerp(cardBorder, other.cardBorder, t)!,
      card2: Color.lerp(card2, other.card2, t)!, card2Border: Color.lerp(card2Border, other.card2Border, t)!,
      navBg: Color.lerp(navBg, other.navBg, t)!, navBorder: Color.lerp(navBorder, other.navBorder, t)!,
      title: Color.lerp(title, other.title, t)!, subtitle: Color.lerp(subtitle, other.subtitle, t)!,
      muted: Color.lerp(muted, other.muted, t)!, accent: Color.lerp(accent, other.accent, t)!,
      accentAlt: Color.lerp(accentAlt, other.accentAlt, t)!,
      presence: Color.lerp(presence, other.presence, t)!, presenceBg: Color.lerp(presenceBg, other.presenceBg, t)!,
      presenceBdr: Color.lerp(presenceBdr, other.presenceBdr, t)!,
      pillBg: Color.lerp(pillBg, other.pillBg, t)!, pillText: Color.lerp(pillText, other.pillText, t)!,
      pillBdr: Color.lerp(pillBdr, other.pillBdr, t)!,
      barBg: Color.lerp(barBg, other.barBg, t)!, stepBg: Color.lerp(stepBg, other.stepBg, t)!,
      stepBdr: Color.lerp(stepBdr, other.stepBdr, t)!, divider: Color.lerp(divider, other.divider, t)!,
      online: Color.lerp(online, other.online, t)!, amber: Color.lerp(amber, other.amber, t)!,
      cyan: Color.lerp(cyan, other.cyan, t)!, gradientStart: Color.lerp(gradientStart, other.gradientStart, t)!,
      gradientEnd: Color.lerp(gradientEnd, other.gradientEnd, t)!,
    );
  }
}
