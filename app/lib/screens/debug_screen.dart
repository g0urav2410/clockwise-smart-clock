import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/clock_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/clock_card.dart';
import 'home_screen.dart' show showToast;

/// Hardware tuning, for feeling changes on the real display rather than
/// reasoning about them.
///
/// The two settings here interact, which is why they're on one page: the
/// brightness curve decides how short low-brightness PWM pulses get, and the
/// PWM frequency decides how much room those pulses have. Push both and the
/// display flickers, because WiFi jitters the ESP8266's software PWM by about
/// a microsecond and a short enough pulse can't absorb that.
class DebugScreen extends StatefulWidget {
  const DebugScreen({super.key});
  @override
  State<DebugScreen> createState() => _DebugScreenState();
}

class _DebugScreenState extends State<DebugScreen> {
  bool _running = false;
  int? _liveBrightness;

  // Seeded from the clock on first build, not on every rebuild: polling would
  // otherwise overwrite a half-typed number under the user's fingers.
  final _freqCtl = TextEditingController();
  bool _freqSeeded = false;

  @override
  void dispose() {
    _freqCtl.dispose();
    super.dispose();
  }

  // 0 is the CIE lightness curve, not a gamma exponent. It is the only option
  // that keeps every percent a distinct level at the dim end: Strong (2.2)
  // collapses 1-5% onto duty 1, so those slider positions look smooth only
  // because nothing is actually changing.
  static const _gammas = {
    100: 'Linear',
    180: 'Standard',
    220: 'Strong',
    0: 'Even',
  };

  /// Same maths as the firmware's dutyForPct, so the numbers shown match what
  /// the hardware is actually doing.
  double _pulseMicros(int pct, int gammaX100, int freq) {
    if (pct <= 0) return 0;
    final double lum;
    if (gammaX100 == 0) {
      // CIE 1931 lightness, matching the firmware's gamma==0 branch.
      final L = pct.toDouble();
      lum = L > 8 ? math.pow((L + 16) / 116, 3).toDouble() : L / 903.3;
    } else {
      lum = math.pow(pct / 100.0, gammaX100 / 100.0).toDouble();
    }
    final duty = math.max(1, (lum * 1023).round());
    return duty / 1023 * (1000000 / freq);
  }

  Future<void> _ladder(ClockController ctl) async {
    setState(() => _running = true);
    for (final p in [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]) {
      if (!mounted) return;
      setState(() => _liveBrightness = p);
      ctl.setBrightnessLive(p);
      await Future.delayed(const Duration(milliseconds: 1200));
    }
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final ctl = context.watch<ClockController>();
    final c = Theme.of(context).extension<ClockColors>()!;
    final cfg = ctl.config;

    if (cfg == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Display tuning')),
        body: Center(
            child: Text('Not connected', style: TextStyle(color: c.muted))),
      );
    }

    if (!_freqSeeded) {
      _freqCtl.text = cfg.oeFreq.toString();
      _freqSeeded = true;
    }

    final pulse1 = _pulseMicros(1, cfg.gammaX100, cfg.oeFreq);
    final pulse12 = _pulseMicros(12, cfg.gammaX100, cfg.oeFreq);
    final risky = pulse12 < 3.0;

    return Scaffold(
      appBar: AppBar(title: const Text('Display tuning')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Brightness curve',
                    style: TextStyle(fontSize: 14, color: c.title)),
                const SizedBox(height: 4),
                Text(
                  'Linear makes low percentages jump and high ones barely '
                  'change. Stronger curves even the steps out, but push the '
                  'first few percent onto the same duty — smooth because '
                  'nothing changes. Even keeps every percent distinct.',
                  style: TextStyle(fontSize: 11, color: c.muted),
                ),
                const SizedBox(height: 10),
                SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: [
                    for (final e in _gammas.entries)
                      ButtonSegment(
                          value: e.key,
                          label: Text(e.value,
                              style: const TextStyle(fontSize: 12))),
                  ],
                  selected: {
                    _gammas.containsKey(cfg.gammaX100) ? cfg.gammaX100 : 180
                  },
                  onSelectionChanged: (s) =>
                      ctl.patchConfig({'gamma': s.first}),
                ),
              ],
            ),
          ),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('PWM frequency',
                    style: TextStyle(fontSize: 14, color: c.title)),
                const SizedBox(height: 4),
                Text(
                  'Higher is not better here. It shortens every pulse, which '
                  'is what lets WiFi timing jitter show up as flicker. Lower '
                  'lengthens them — below about 200 Hz the flicker becomes '
                  'visible to the eye instead. 100–40000 accepted.',
                  style: TextStyle(fontSize: 11, color: c.muted),
                ),
                const SizedBox(height: 10),
                // Free entry rather than fixed presets, and the only place in
                // the app this can be set. It used to be here as four presets
                // AND as a text field in Settings, which meant a value from
                // either one (or from serial) that wasn't a preset showed up
                // here as "1k" -- the page stated a frequency the clock was
                // not running, and one tap silently overwrote the real value.
                Row(children: [
                  SizedBox(
                    width: 110,
                    child: TextField(
                      controller: _freqCtl,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        isDense: true,
                        suffixText: 'Hz',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      final hz = int.tryParse(_freqCtl.text);
                      if (hz == null || hz < 100 || hz > 40000) {
                        showToast(context, 'Enter 100–40000 Hz');
                        return;
                      }
                      ctl.patchConfig({'oeFreq': hz});
                      showToast(context, 'PWM frequency set to $hz Hz');
                    },
                    child: const Text('Apply'),
                  ),
                ]),
              ],
            ),
          ),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Pulse width at this combination',
                    style: TextStyle(fontSize: 13, color: c.title)),
                const SizedBox(height: 6),
                _row(c, 'at 1% brightness', '${pulse1.toStringAsFixed(2)} µs'),
                _row(c, 'at 12% brightness', '${pulse12.toStringAsFixed(2)} µs'),
                const SizedBox(height: 6),
                Text(
                  risky
                      ? 'Under ~3 µs — WiFi jitter is roughly a microsecond, so '
                          'expect visible flicker at low brightness while the '
                          'app is connected.'
                      : 'Comfortably above WiFi jitter (~1 µs). Should be steady.',
                  style: TextStyle(
                      fontSize: 11, color: risky ? c.amber : c.presence),
                ),
              ],
            ),
          ),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Try it', style: TextStyle(fontSize: 14, color: c.title)),
                const SizedBox(height: 4),
                Text(
                  'Ten equal steps, 10% to 100%. Even-looking steps mean the '
                  'curve suits the display. Nothing here is saved.',
                  style: TextStyle(fontSize: 11, color: c.muted),
                ),
                const SizedBox(height: 10),
                Row(children: [
                  FilledButton.icon(
                    onPressed: _running ? null : () => _ladder(ctl),
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: Text(_running
                        ? 'Running… ${_liveBrightness ?? ''}%'
                        : 'Run step test'),
                  ),
                  const SizedBox(width: 10),
                  TextButton(
                    onPressed: () async {
                      await ctl.refresh();
                      if (context.mounted) showToast(context, 'Restored');
                    },
                    child: const Text('Restore'),
                  ),
                ]),
                const SizedBox(height: 14),
                Text('Live brightness — drag and watch',
                    style: TextStyle(fontSize: 13, color: c.title)),
                Slider(
                  value: (_liveBrightness ?? cfg.full).toDouble().clamp(0, 100),
                  max: 100,
                  onChangeStart: (_) => ctl.beginBrightnessDrag(),
                  onChanged: (v) {
                    setState(() => _liveBrightness = v.round());
                    ctl.setBrightnessLive(v.round());
                  },
                  onChangeEnd: (v) => ctl.endBrightnessDrag(v.round()),
                ),
                Text('${_liveBrightness ?? cfg.full}%',
                    style: TextStyle(fontSize: 12, color: c.accent)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(ClockColors c, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(
              child: Text(k, style: TextStyle(fontSize: 12, color: c.muted))),
          Text(v, style: TextStyle(fontSize: 12, color: c.title)),
        ]),
      );
}
