import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/clock_api.dart';
import '../services/clock_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/clock_card.dart';
import 'home_screen.dart' show showToast;

/// The LD2402 splits range into fixed ~0.7m "gates". Gate 0 is nearest; each
/// higher gate is one slice further out. Used to label everything by real
/// distance instead of a bare gate number.
///
/// 16 gates * 0.7m = 11.2m in theory, but the datasheet caps supported range
/// at 10.0m (matching setMaxDistanceMeters' own 0.7-10.0m clamp in the
/// firmware) -- gate 15 is entirely past that, and gate 14 straddles it. Clip
/// the printed range to the real spec instead of the raw arithmetic, so the
/// UI doesn't claim range the sensor isn't actually rated for.
const double _gateWidthM = 0.7;
const double _sensorMaxRangeM = 10.0;
String _gateRange(int gate) {
  final lo = gate * _gateWidthM;
  if (lo >= _sensorMaxRangeM) return 'beyond ${_sensorMaxRangeM.toStringAsFixed(1)}m range';
  final hi = ((gate + 1) * _gateWidthM).clamp(0, _sensorMaxRangeM);
  return '${lo.toStringAsFixed(1)}–${hi.toStringAsFixed(1)} m';
}

/// HLK-LD2402 presence radar -- live readings, calibration, and thresholds.
/// A separate section rather than folded into Advanced: this talks to a
/// different device on the clock's UART, not the clock's own settings, and
/// the config fetch is slow (~35 small serial round-trips), so it only
/// happens when this page is actually opened.
class SensorScreen extends StatefulWidget {
  const SensorScreen({super.key});
  @override
  State<SensorScreen> createState() => _SensorScreenState();
}

class _SensorScreenState extends State<SensorScreen> {
  Timer? _poll;
  SensorState? _live;
  SensorConfig? _cfg;
  bool _cfgLoading = false;
  String? _cfgError;
  // Paused while calibration/auto-gain is running -- both hold the sensor's
  // UART for many seconds, and the ESP8266 web server only handles one
  // request at a time, so once-a-second polling underneath a 20s+ blocking
  // request just piles up pending connections against a very memory-limited
  // device instead of doing anything useful.
  bool _sensorBusy = false;

  ClockApi? _api(BuildContext context) {
    final ctl = context.read<ClockController>();
    if (!ctl.hasDevice) return null;
    return ClockApi(ctl.current!.host, pin: ctl.current!.pin);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pollLive();
      _loadConfig();
      _poll = Timer.periodic(const Duration(seconds: 1), (_) => _pollLive());
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _pollLive() async {
    if (_sensorBusy) return;
    final api = _api(context);
    if (api == null) return;
    try {
      final s = await api.sensorState();
      if (mounted) setState(() => _live = s);
    } catch (_) {
      // transient -- keep showing the last good reading
    }
  }

  Future<void> _loadConfig() async {
    final api = _api(context);
    if (api == null) return;
    setState(() { _cfgLoading = true; _cfgError = null; });
    try {
      final c = await api.sensorConfig();
      if (mounted) setState(() { _cfg = c; _cfgLoading = false; });
    } catch (e) {
      if (mounted) setState(() { _cfgError = '$e'; _cfgLoading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ctl = context.watch<ClockController>();
    final c = Theme.of(context).extension<ClockColors>()!;

    if (!ctl.hasDevice) {
      return Scaffold(
        appBar: AppBar(title: const Text('Presence sensor')),
        body: Center(child: Text('No clock added', style: TextStyle(color: c.muted))),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Presence sensor')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          _LiveCard(live: _live),
          _DimOverlayCard(dimActive: ctl.state?.presenceDimActive, ctl: ctl),
          if (_cfgLoading)
            const GlassCard(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Center(child: CircularProgressIndicator()),
              ),
            )
          else if (_cfgError != null)
            GlassCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Could not load sensor settings', style: TextStyle(color: c.title)),
                const SizedBox(height: 4),
                Text(_cfgError!, style: TextStyle(fontSize: 11, color: c.muted)),
                const SizedBox(height: 8),
                FilledButton(onPressed: _loadConfig, child: const Text('Retry')),
              ]),
            )
          else if (_cfg != null)
            _ConfigCard(
              cfg: _cfg!,
              onSaved: () async {
                await _loadConfig();
                if (mounted) showToast(context, 'Applied');
              },
              apiOf: () => _api(context),
            ),
          if (_cfg != null)
            _CalibrationCard(
              apiOf: () => _api(context),
              onBusyChanged: (busy) => setState(() => _sensorBusy = busy),
            ),
          if (_cfg != null)
            _GateTuningCard(
              apiOf: () => _api(context),
              liveOf: () => _live,
              engineering: _cfg!.engineering,
              onEngineeringChanged: () => _loadConfig(),
            ),
          _SerialDebugCard(ctl: ctl),
        ],
      ),
    );
  }
}

class _LiveCard extends StatelessWidget {
  final SensorState? live;
  const _LiveCard({required this.live});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<ClockColors>()!;
    final l = live;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text('Live', style: TextStyle(fontSize: 14, color: c.title)),
            const Spacer(),
            Icon(Icons.circle, size: 9,
                color: l?.connected == true ? c.presence : c.muted),
            const SizedBox(width: 5),
            Text(l?.connected == true ? 'Connected' : 'Not detected',
                style: TextStyle(fontSize: 11, color: c.muted)),
          ]),
          const SizedBox(height: 10),
          if (l == null)
            Text('Waiting for a reading…', style: TextStyle(color: c.muted))
          else ...[
            Row(children: [
              _Pill(label: l.presence ? 'Presence' : 'Empty',
                  on: l.presence, c: c),
              const SizedBox(width: 8),
              if (l.presence)
                _Pill(label: l.moving ? 'Moving' : (l.still ? 'Still' : '—'),
                    on: true, c: c),
            ]),
            const SizedBox(height: 10),
            Text('Distance', style: TextStyle(fontSize: 12, color: c.muted)),
            Text(l.presence ? '${(l.distanceCm / 100).toStringAsFixed(2)} m' : '—',
                style: TextStyle(fontSize: 22, color: c.title, fontWeight: FontWeight.w600)),
          ],
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final bool on;
  final ClockColors c;
  const _Pill({required this.label, required this.on, required this.c});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: (on ? c.presence : c.muted).withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: TextStyle(fontSize: 12, color: on ? c.presence : c.muted)),
      );
}

/// Dims the display when the room's been empty a while -- works on top of
/// whichever brightness mode (Manual/Schedule/Sun) is active on the clock,
/// not a separate mode of its own. Off by default.
class _DimOverlayCard extends StatefulWidget {
  final bool? dimActive;
  final ClockController ctl;
  const _DimOverlayCard({required this.dimActive, required this.ctl});
  @override
  State<_DimOverlayCard> createState() => _DimOverlayCardState();
}

class _DimOverlayCardState extends State<_DimOverlayCard> {
  bool _filled = false;
  late bool _enabled;
  late int _away;
  late int _timeout;

  void _fill() {
    final cfg = widget.ctl.config;
    if (_filled || cfg == null) return;
    _filled = true;
    _enabled = cfg.presenceDim;
    _away = cfg.presenceAway;
    _timeout = cfg.presenceTimeout;
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<ClockColors>()!;
    final cfg = widget.ctl.config;
    _fill();
    if (cfg == null) return const SizedBox.shrink();

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Dim when empty', style: TextStyle(fontSize: 14, color: c.title)),
                  const SizedBox(height: 2),
                  Text('Works in Manual, Schedule and Sun mode alike -- '
                      'temporarily overrides whatever brightness the mode '
                      'wants, then hands control back the moment someone '
                      'returns.',
                      style: TextStyle(fontSize: 11, color: c.muted)),
                ],
              ),
            ),
            Switch(
              value: _enabled,
              onChanged: (v) {
                setState(() => _enabled = v);
                widget.ctl.patchConfig({'presenceDim': v});
              },
            ),
          ]),
          if (_enabled) ...[
            const SizedBox(height: 6),
            if (widget.dimActive == true)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('Currently dimmed — room has been empty a while',
                    style: TextStyle(fontSize: 11.5, color: c.accent)),
              ),
            Text('Away brightness: $_away%', style: TextStyle(fontSize: 12, color: c.muted)),
            Slider(
              value: _away.clamp(0, 100).toDouble(),
              min: 0, max: 100, divisions: 100,
              onChanged: (v) => setState(() => _away = v.round()),
              onChangeEnd: (v) => widget.ctl.patchConfig({'presenceAway': v.round()}),
            ),
            Text('After $_timeout min with no one detected',
                style: TextStyle(fontSize: 12, color: c.muted)),
            Slider(
              value: _timeout.clamp(1, 60).toDouble(),
              min: 1, max: 60, divisions: 59,
              onChanged: (v) => setState(() => _timeout = v.round()),
              onChangeEnd: (v) => widget.ctl.patchConfig({'presenceTimeout': v.round()}),
            ),
          ],
        ],
      ),
    );
  }
}

class _ConfigCard extends StatefulWidget {
  final SensorConfig cfg;
  final VoidCallback onSaved;
  final ClockApi? Function() apiOf;
  const _ConfigCard({required this.cfg, required this.onSaved, required this.apiOf});
  @override
  State<_ConfigCard> createState() => _ConfigCardState();
}

class _ConfigCardState extends State<_ConfigCard> {
  late double _maxDist = widget.cfg.maxDistanceM;
  late int _delay = widget.cfg.disappearDelaySec;
  bool _busy = false;
  bool _expanded = false;
  late List<double> _motionTh = List.of(widget.cfg.motionThresholdDb);
  late List<double> _microTh = List.of(widget.cfg.microThresholdDb);

  Future<void> _apply({bool save = false}) async {
    final api = widget.apiOf();
    if (api == null) return;
    setState(() => _busy = true);
    try {
      await api.setSensorConfig({
        'maxDistanceM': _maxDist,
        'disappearDelaySec': _delay,
        if (_motionTh.length == 16) 'motionThresholdDb': _motionTh,
        if (_microTh.length == 16) 'microThresholdDb': _microTh,
      }, save: save);
      widget.onSaved();
    } catch (e) {
      if (mounted) showToast(context, 'Failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<ClockColors>()!;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Range & timing', style: TextStyle(fontSize: 14, color: c.title)),
          if (widget.cfg.firmware != null) ...[
            const SizedBox(height: 2),
            Text('Firmware ${widget.cfg.firmware}${widget.cfg.serial != null ? ' · SN ${widget.cfg.serial}' : ''}',
                style: TextStyle(fontSize: 11, color: c.muted)),
          ],
          const SizedBox(height: 10),
          Text('Max distance: ${_maxDist.toStringAsFixed(1)} m',
              style: TextStyle(fontSize: 12, color: c.muted)),
          Slider(
            value: _maxDist.clamp(0.7, 10.0),
            min: 0.7, max: 10.0, divisions: 93,
            onChanged: (v) => setState(() => _maxDist = v),
          ),
          Text('Disappearance delay: ${_delay}s',
              style: TextStyle(fontSize: 12, color: c.muted)),
          Slider(
            value: _delay.clamp(0, 120).toDouble(),
            min: 0, max: 120, divisions: 120,
            onChanged: (v) => setState(() => _delay = v.round()),
          ),
          if (widget.cfg.powerInterference == 2)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('⚠ Power interference detected on the sensor',
                  style: TextStyle(fontSize: 11, color: Colors.orange.shade400)),
            ),
          if (_motionTh.length == 16 && _microTh.length == 16) ...[
            const SizedBox(height: 4),
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(children: [
                Text('Per-gate thresholds (advanced)',
                    style: TextStyle(fontSize: 12, color: c.accent)),
                Icon(_expanded ? Icons.expand_less : Icons.expand_more, size: 18, color: c.accent),
              ]),
            ),
            if (_expanded)
              for (int i = 0; i < 16; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    SizedBox(width: 18, child: Text('$i', style: TextStyle(fontSize: 10, color: c.muted))),
                    Expanded(
                      child: _thresholdSlider('motion', _motionTh[i], c,
                          (v) => setState(() => _motionTh[i] = v)),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _thresholdSlider('micro', _microTh[i], c,
                          (v) => setState(() => _microTh[i] = v)),
                    ),
                  ]),
                ),
          ],
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : () => _apply(save: false),
                child: const Text('Apply'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                onPressed: _busy ? null : () => _apply(save: true),
                child: Text(_busy ? 'Working…' : 'Save to sensor'),
              ),
            ),
          ]),
          const SizedBox(height: 4),
          Text('Apply tries it now. Save to sensor writes it to the sensor\'s '
              'own flash so it survives a power cycle.',
              style: TextStyle(fontSize: 10.5, color: c.muted)),
        ],
      ),
    );
  }

  Widget _thresholdSlider(String label, double value, ClockColors c, ValueChanged<double> onChanged) {
    return Row(children: [
      SizedBox(width: 38, child: Text(label, style: TextStyle(fontSize: 10, color: c.muted))),
      Expanded(
        child: Slider(
          value: value.clamp(0.0, 60.0),
          min: 0, max: 60,
          onChanged: onChanged,
        ),
      ),
    ]);
  }
}

class _CalibrationCard extends StatefulWidget {
  final ClockApi? Function() apiOf;
  final ValueChanged<bool>? onBusyChanged;
  const _CalibrationCard({required this.apiOf, this.onBusyChanged});
  @override
  State<_CalibrationCard> createState() => _CalibrationCardState();
}

class _CalibrationCardState extends State<_CalibrationCard> {
  bool _calibrating = false;
  bool _gaining = false;
  String? _result;

  Future<void> _calibrate() async {
    final api = widget.apiOf();
    if (api == null) return;
    widget.onBusyChanged?.call(true);
    setState(() { _calibrating = true; _result = 'Calibrating… keep the room clear of movement — this can take up to two minutes.'; });
    try {
      final r = await api.calibrateSensor();
      setState(() {
        if (r['ok'] != true) {
          _result = 'Stopped at ${r['percent']}% — try again, or check the sensor is wired.';
          return;
        }
        if (r['interference'] == true) {
          final mask = (r['interferenceGates'] as int?) ?? 0;
          final gates = [for (var g = 0; g < 16; g++) if ((mask >> g) & 1 == 1) g];
          final where = gates.isEmpty ? '' : ' (near ${gates.map(_gateRange).join(', ')})';
          _result = 'Calibration complete, but detected movement in the room$where — '
              'for best results, redo it with the room clear.';
        } else {
          _result = 'Calibration complete.';
        }
      });
    } catch (e) {
      setState(() => _result = 'Failed: $e');
    } finally {
      widget.onBusyChanged?.call(false);
      if (mounted) setState(() => _calibrating = false);
    }
  }

  Future<void> _autoGain() async {
    final api = widget.apiOf();
    if (api == null) return;
    widget.onBusyChanged?.call(true);
    setState(() { _gaining = true; _result = 'Adjusting gain…'; });
    try {
      final r = await api.autoGainSensor();
      setState(() => _result = (r['ok'] == true) ? 'Auto-gain complete.' : 'Auto-gain did not finish.');
    } catch (e) {
      setState(() => _result = 'Failed: $e');
    } finally {
      widget.onBusyChanged?.call(false);
      if (mounted) setState(() => _gaining = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<ClockColors>()!;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Calibration', style: TextStyle(fontSize: 14, color: c.title)),
          const SizedBox(height: 4),
          Text('Auto-calibrate sets the detection thresholds for this room. '
              'Auto-gain corrects the sensor if it\'s saturated. Both take a few seconds.',
              style: TextStyle(fontSize: 11, color: c.muted)),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: (_calibrating || _gaining) ? null : _calibrate,
                child: Text(_calibrating ? 'Calibrating…' : 'Auto-calibrate'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: (_calibrating || _gaining) ? null : _autoGain,
                child: Text(_gaining ? 'Working…' : 'Auto-gain'),
              ),
            ),
          ]),
          if (_result != null) ...[
            const SizedBox(height: 8),
            Text(_result!, style: TextStyle(fontSize: 12, color: c.accent)),
          ],
        ],
      ),
    );
  }
}

/// The one UART is shared: either the radar has it (sensor works) or the USB
/// serial debug console does. This toggle picks which. Flipping it on pauses
/// the sensor — meant for plugging in USB to debug, with the sensor unplugged.
class _SerialDebugCard extends StatelessWidget {
  final ClockController ctl;
  const _SerialDebugCard({required this.ctl});
  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<ClockColors>()!;
    final cfg = ctl.config;
    if (cfg == null) return const SizedBox.shrink();
    final on = cfg.serialDebug;
    return GlassCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('USB serial debug', style: TextStyle(fontSize: 14, color: c.title)),
              const SizedBox(height: 2),
              Text('The sensor and the USB console share one wire, so only one '
                  'runs at a time. Flip this on, then unplug the sensor — the '
                  'console wakes up for USB debugging. The sensor keeps working '
                  'normally until you unplug it; nothing breaks either way. Turn '
                  'off when done.',
                  style: TextStyle(fontSize: 11, color: c.muted)),
            ]),
          ),
          Switch(
            value: on,
            onChanged: ctl.isConnected
                ? (v) => ctl.patchConfig({'serialDebug': v})
                : null,
          ),
        ]),
        if (on)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('⚠ Debug armed. Unplug the sensor to use the USB console '
                '— it stays asleep while the sensor is plugged in (the sensor '
                'keeps running). Turn this off to return to normal.',
                style: TextStyle(fontSize: 11.5, color: Colors.orange.shade400)),
          ),
      ]),
    );
  }
}

/// Per-gate threshold tuning. For each ~0.7 m distance slice you set the
/// "detect" level for movement and for micro-motion separately, watching the
/// live signal against it. Loaded on demand (32 reads) so it doesn't slow the
/// screen down for people who never touch it.
class _GateTuningCard extends StatefulWidget {
  final ClockApi? Function() apiOf;
  final SensorState? Function() liveOf;
  final bool engineering;
  final VoidCallback onEngineeringChanged;
  const _GateTuningCard({
    required this.apiOf,
    required this.liveOf,
    required this.engineering,
    required this.onEngineeringChanged,
  });
  @override
  State<_GateTuningCard> createState() => _GateTuningCardState();
}

class _GateTuningCardState extends State<_GateTuningCard> {
  bool _loading = false;
  bool _saving = false;
  // Off by default even once loaded/streaming -- so opening this card just
  // shows the live signal, and dragging a threshold (with its save actions)
  // is a deliberate second step, not something that can happen by accident
  // while just looking at the bars.
  bool _editMode = false;
  String? _error;
  List<double> _motion = [];
  List<double> _micro = [];
  // What's actually on the sensor right now (as of the last load/save) --
  // compared against _motion/_micro to know whether there's anything unsaved
  // to send. Saving unchanged values is a pointless flash write.
  List<double> _savedMotion = [];
  List<double> _savedMicro = [];
  static const double _maxDb = 80;

  bool _gateDirty(int i) =>
      i >= _savedMotion.length || i >= _savedMicro.length ||
      _motion[i] != _savedMotion[i] || _micro[i] != _savedMicro[i];
  bool get _anyDirty => List.generate(_motion.length, (i) => i).any(_gateDirty);

  // One button now does both: turns Full data on (if it isn't already -- no
  // point loading thresholds you can't watch live) and loads them. Used to be
  // two separate steps (a toggle elsewhere, then this button); merging them
  // means there's nothing to forget or get confused about the order of.
  Future<void> _loadAndStream() async {
    final api = widget.apiOf();
    if (api == null) return;
    setState(() { _loading = true; _error = null; });
    try {
      if (!widget.engineering) {
        await api.setSensorConfig({'engineering': true});
        widget.onEngineeringChanged();
      }
      final t = await api.sensorThresholds();
      setState(() {
        // null (a gate that didn't read) falls back to a sane mid value so the
        // slider is still usable rather than pinned at 0.
        _motion = t.motion.map((v) => v ?? 35.0).toList();
        _micro = t.micro.map((v) => v ?? 35.0).toList();
        _savedMotion = List.of(_motion);
        _savedMicro = List.of(_micro);
        _loading = false;
      });
    } catch (e) {
      setState(() { _error = '$e'; _loading = false; });
    }
  }

  Future<void> _save() async {
    final api = widget.apiOf();
    if (api == null || _motion.length != 16 || _micro.length != 16) return;
    setState(() => _saving = true);
    try {
      await api.setSensorConfig({
        'motionThresholdDb': _motion,
        'microThresholdDb': _micro,
      }, save: true);
      _savedMotion = List.of(_motion);
      _savedMicro = List.of(_micro);
      if (mounted) showToast(context, 'Saved to sensor');
    } catch (e) {
      if (mounted) showToast(context, 'Failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<ClockColors>()!;
    final loaded = _motion.length == 16 && _micro.length == 16;
    final live = widget.liveOf();

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Per-gate tuning', style: TextStyle(fontSize: 14, color: c.title)),
          const SizedBox(height: 2),
          Text('Live signal for each ~0.7 m distance slice.',
              style: TextStyle(fontSize: 11, color: c.muted)),
          if (!loaded) ...[
            const SizedBox(height: 12),
            if (_error != null) ...[
              Text(_error!, style: TextStyle(fontSize: 11, color: Colors.red)),
              const SizedBox(height: 8),
            ],
            FilledButton.icon(
              onPressed: _loading ? null : _loadAndStream,
              icon: _loading
                  ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sensors, size: 16),
              label: Text(_loading ? 'Loading…' : 'Show live gate signal'),
            ),
          ] else ...[
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: Text(
                  _editMode
                      ? 'Drag a marker to set that gate\'s threshold. Signal past the marker = detected.'
                      : 'Viewing only. Turn on editing to adjust thresholds.',
                  style: TextStyle(fontSize: 11, color: c.muted),
                ),
              ),
              const SizedBox(width: 8),
              Text('Edit', style: TextStyle(fontSize: 11, color: c.muted)),
              Switch(value: _editMode, onChanged: (v) => setState(() => _editMode = v)),
            ]),
            const SizedBox(height: 8),
            for (int i = 0; i < 16; i++)
              _gateRow(c, i,
                  motionEnergy: (live != null && i < live.motionEnergyDb.length) ? live.motionEnergyDb[i] : null,
                  microEnergy: (live != null && i < live.microEnergyDb.length) ? live.microEnergyDb[i] : null),
            if (_editMode) ...[
              const SizedBox(height: 4),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _loading ? null : _loadAndStream,
                    child: const Text('Reload'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: (_saving || !_anyDirty) ? null : _save,
                    child: Text(_saving ? 'Saving…' : (_anyDirty ? 'Save to sensor' : 'Nothing to save')),
                  ),
                ),
              ]),
            ],
          ],
        ],
      ),
    );
  }

  final Set<int> _savingGate = {};

  // Writes just this one gate via the dedicated single-gate endpoint, rather
  // than the full-16 array the bottom "Save to sensor" button uses -- lets a
  // one-gate tweak be saved without re-sending every other gate's value.
  Future<void> _saveGate(int i) async {
    final api = widget.apiOf();
    if (api == null) return;
    setState(() => _savingGate.add(i));
    try {
      await api.setSensorGate(i, motionDb: _motion[i], microDb: _micro[i], save: true);
      _savedMotion[i] = _motion[i];
      _savedMicro[i] = _micro[i];
      if (mounted) showToast(context, 'Gate $i saved');
    } catch (e) {
      if (mounted) showToast(context, 'Failed: $e');
    } finally {
      if (mounted) setState(() => _savingGate.remove(i));
    }
  }

  Widget _gateRow(ClockColors c, int i, {double? motionEnergy, double? microEnergy}) {
    final saving = _savingGate.contains(i);
    final dirty = _gateDirty(i);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text('Gate $i · ${_gateRange(i)}',
                style: TextStyle(fontSize: 12, color: c.title, fontWeight: FontWeight.w500)),
            const Spacer(),
            // No point offering to save a gate that hasn't actually changed
            // since it was last loaded/saved -- nothing there to write. Also
            // only in edit mode -- can't dirty a gate while just viewing.
            if (_editMode && (dirty || saving))
              InkWell(
                onTap: saving ? null : () => _saveGate(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: saving
                      ? SizedBox(
                          width: 12, height: 12,
                          child: CircularProgressIndicator(strokeWidth: 1.5, color: c.accent),
                        )
                      : Text('Save this gate',
                          style: TextStyle(fontSize: 10.5, color: c.accent)),
                ),
              ),
          ]),
          _thresholdRow(c, 'Move', c.accent, motionEnergy, _motion[i],
              (v) => setState(() => _motion[i] = v)),
          _thresholdRow(c, 'Still', c.presence, microEnergy, _micro[i],
              (v) => setState(() => _micro[i] = v)),
        ],
      ),
    );
  }

  // Live energy bar with the threshold as a slider on the same 0–80 dB scale,
  // so "is the signal above the line" is visible at a glance.
  Widget _thresholdRow(ClockColors c, String label, Color color,
      double? energy, double threshold, ValueChanged<double> onChanged) {
    return Row(children: [
      SizedBox(width: 34, child: Text(label, style: TextStyle(fontSize: 10, color: c.muted))),
      Expanded(
        child: Stack(alignment: Alignment.center, children: [
          if (energy != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: (energy / _maxDb).clamp(0.0, 1.0),
                minHeight: 4,
                backgroundColor: c.divider,
                valueColor: AlwaysStoppedAnimation(color.withValues(alpha: 0.5)),
              ),
            ),
          // The marker itself stays visible while just viewing -- it's useful
          // info (where's the threshold relative to the signal) -- only
          // dragging it is gated on edit mode.
          IgnorePointer(
            ignoring: !_editMode,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 1,
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                activeTrackColor: Colors.transparent,
                inactiveTrackColor: Colors.transparent,
                thumbColor: color,
              ),
              child: Slider(
                value: threshold.clamp(0.0, _maxDb),
                min: 0, max: _maxDb,
                onChanged: onChanged,
              ),
            ),
          ),
        ]),
      ),
      SizedBox(
        width: 34,
        child: Text('${threshold.round()}',
            textAlign: TextAlign.right,
            style: TextStyle(fontSize: 10, color: c.muted)),
      ),
    ]);
  }
}
