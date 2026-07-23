import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets? padding;
  final double radius;

  const GlassCard({super.key, required this.child, this.padding, this.radius = 16});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<ClockColors>()!;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: c.card,
        border: Border.all(color: c.cardBorder, width: 0.5),
        borderRadius: BorderRadius.circular(radius),
      ),
      padding: padding ?? const EdgeInsets.all(14),
      child: child,
    );
  }
}

class StatChip extends StatelessWidget {
  final String value;
  final String label;
  final Color? valueColor;

  const StatChip({super.key, required this.value, required this.label, this.valueColor});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<ClockColors>()!;
    return Container(
      decoration: BoxDecoration(
        color: c.card2,
        border: Border.all(color: c.card2Border, width: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w400, color: valueColor ?? c.title)),
          const SizedBox(height: 2),
          Text(label,
            style: TextStyle(fontSize: 9, color: c.muted, letterSpacing: 0.5,
              fontFeatures: const [FontFeature.enable('smcp')])),
        ],
      ),
    );
  }
}

class Stepper extends StatelessWidget {
  final String label;
  final String sublabel;
  final String display;
  final VoidCallback onDec;
  final VoidCallback onInc;

  const Stepper({
    super.key,
    required this.label,
    required this.sublabel,
    required this.display,
    required this.onDec,
    required this.onInc,
  });

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<ClockColors>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(fontSize: 13, color: c.title)),
              const SizedBox(height: 1),
              Text(sublabel, style: TextStyle(fontSize: 10, color: c.muted)),
            ],
          )),
          Row(children: [
            _StepBtn(icon: Icons.remove, onTap: onDec),
            SizedBox(
              width: 46,
              child: Text(display,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: c.accent)),
            ),
            _StepBtn(icon: Icons.add, onTap: onInc),
          ]),
        ],
      ),
    );
  }
}

class _StepBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _StepBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<ClockColors>()!;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 26, height: 26,
        decoration: BoxDecoration(
          color: c.stepBg,
          border: Border.all(color: c.stepBdr, width: 0.5),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(icon, size: 14, color: c.muted),
      ),
    );
  }
}

class OnlinePill extends StatelessWidget {
  final bool online;
  const OnlinePill({super.key, required this.online});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<ClockColors>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: online ? c.pillBg : Colors.transparent,
        border: Border.all(color: online ? c.pillBdr : c.muted, width: 0.5),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        online ? 'online' : 'offline',
        style: TextStyle(fontSize: 10, color: online ? c.pillText : c.muted),
      ),
    );
  }
}

class GradientBar extends StatelessWidget {
  final double fraction;
  final Color? start;
  final Color? end;

  const GradientBar({super.key, required this.fraction, this.start, this.end});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<ClockColors>()!;
    return Container(
      height: 4,
      decoration: BoxDecoration(color: c.barBg, borderRadius: BorderRadius.circular(2)),
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: fraction.clamp(0.0, 1.0),
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [start ?? c.gradientStart, end ?? c.gradientEnd]),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}
