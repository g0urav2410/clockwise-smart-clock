import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/clock_api.dart';
import '../services/clock_controller.dart';
import '../theme/app_theme.dart';

/// Commands that put the physical display into manual/test mode (it stops
/// showing the real time) or write the RTC directly -- these get a
/// confirmation dialog before sending, since there's no way to see the
/// clock's face right now to catch a mistake. Everything else (frequency,
/// logo, notice timing, NTP sync, reads) is a normal reversible-by-re-sending
/// setting change, same risk level as any other settings screen.
bool _isRiskyCmd(String cmd) {
  final c = cmd.trim();
  if (c.isEmpty) return false;
  final first = c[0];
  if (RegExp(r'^-?\d').hasMatch(c)) return true; // bare number -> manual pixel
  return first == 'c' || first == 'x' || first == 'n' || first == 'p' || first == 'u';
}

/// True for the subset of _isRiskyCmd that specifically enters manual/test
/// display mode (as opposed to 'u', which is risky but doesn't need the
/// auto-resume-on-exit safety net since it doesn't freeze the display).
bool _entersManualMode(String cmd) {
  final c = cmd.trim();
  if (c.isEmpty) return false;
  final first = c[0];
  if (RegExp(r'^-?\d').hasMatch(c)) return true;
  return first == 'c' || first == 'x' || first == 'n' || first == 'p';
}

const _commandRef = [
  ('s', 'NTP sync now'),
  ('t', 'Read current RTC time'),
  ('v', 'Read raw RTC registers'),
  ('l', 'Toggle tick log'),
  ('g', 'Toggle logo LED'),
  ('a <on> <off>', 'WiFi-down notice timing, seconds'),
  ('f <hz>', 'Set OE PWM frequency (100-40000)'),
  ('w', 'Set RTC to a known value'),
  ('u <yr> <mo> <dd> <h24> <mn> <s>', 'Set RTC to an exact time'),
  ('r', 'Resume normal display (undoes manual mode)'),
  ('<number>', 'Light one output (manual mode)'),
  ('n / p', 'Step manual output forward/back'),
  ('c <chip 0-6>', 'Light one chip (manual mode)'),
  ('x', 'Clear manual display'),
  ('+ / -', 'Nudge brightness'),
];

/// A simple serial-monitor-style view of the clock's small in-RAM event log,
/// plus a command input that mirrors the physical USB debug console -- for
/// debugging without a cable plugged in. Polls rather than streams: the
/// clock's HTTP server handles one request at a time, so a poll-based log is
/// the same tradeoff already made everywhere else in the app.
class DeviceLogScreen extends StatefulWidget {
  const DeviceLogScreen({super.key});
  @override
  State<DeviceLogScreen> createState() => _DeviceLogScreenState();
}

class _DeviceLogScreenState extends State<DeviceLogScreen> {
  Timer? _poll;
  List<String> _lines = [];
  String? _error;
  bool _loading = true;
  bool _autoRefresh = true;
  final _scrollCtl = ScrollController();
  final _cmdCtl = TextEditingController();
  bool _sending = false;

  // Tracks whether THIS screen instance is the one that put the clock into
  // manual mode, so leaving the screen can automatically send 'r' -- without
  // this, walking away after a manual-mode command leaves the real clock
  // face frozen indefinitely with nothing to notice it.
  bool _weEnteredManualMode = false;

  ClockApi? _api(BuildContext context) {
    final ctl = context.read<ClockController>();
    if (!ctl.hasDevice) return null;
    return ClockApi(ctl.current!.host, pin: ctl.current!.pin);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load();
      _poll = Timer.periodic(const Duration(seconds: 3), (_) {
        if (_autoRefresh) _load();
      });
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _scrollCtl.dispose();
    _cmdCtl.dispose();
    if (_weEnteredManualMode) {
      // Fire-and-forget: the screen is gone by the time this would resolve,
      // there's nothing left to update.
      _api(context)?.sendDebugCmd('r');
    }
    super.dispose();
  }

  Future<void> _load() async {
    final api = _api(context);
    if (api == null) return;
    try {
      final lines = await api.deviceLog();
      if (!mounted) return;
      setState(() { _lines = lines; _error = null; _loading = false; });
      if (_scrollCtl.hasClients &&
          _scrollCtl.position.pixels >= _scrollCtl.position.maxScrollExtent - 40) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollCtl.hasClients) {
            _scrollCtl.jumpTo(_scrollCtl.position.maxScrollExtent);
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() { _error = '$e'; _loading = false; });
    }
  }

  Future<void> _send([String? explicitCmd]) async {
    final cmd = (explicitCmd ?? _cmdCtl.text).trim();
    if (cmd.isEmpty || _sending) return;

    if (_isRiskyCmd(cmd)) {
      final ok = await _confirmRisky(cmd);
      if (ok != true || !mounted) return;
    }

    final api = _api(context);
    if (api == null) return;
    setState(() => _sending = true);
    try {
      final result = await api.sendDebugCmd(cmd);
      if (_entersManualMode(cmd) && cmd != 'r') _weEnteredManualMode = true;
      if (cmd.trim() == 'r') _weEnteredManualMode = false;
      _cmdCtl.clear();
      if (mounted) {
        setState(() => _lines = [..._lines, '> $cmd']);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
      }
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<bool?> _confirmRisky(String cmd) {
    final entersManual = _entersManualMode(cmd);
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('This changes the physical display'),
        content: Text(
          entersManual
              ? '"$cmd" stops the clock from showing the real time and shows '
                'a test pattern instead, until you send "r" to resume. '
                'Since you can\'t see the clock right now, leaving this '
                'screen will automatically resume it for you -- but while '
                'you\'re on this screen it stays in test mode.'
              : '"$cmd" writes the clock\'s real-time clock directly. A wrong '
                'value will make the displayed time wrong until the next '
                'sync.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Send anyway')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<ClockColors>()!;
    final ctl = context.watch<ClockController>();

    if (!ctl.hasDevice) {
      return Scaffold(
        appBar: AppBar(title: const Text('Device log')),
        body: Center(child: Text('No clock added', style: TextStyle(color: c.muted))),
      );
    }

    final manualModeActive = ctl.state?.manualMode == true;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Device log'),
        actions: [
          IconButton(
            icon: const Icon(Icons.list_alt, size: 20),
            tooltip: 'Command reference',
            onPressed: () => _showReference(context, c),
          ),
          IconButton(
            icon: Icon(_autoRefresh ? Icons.pause : Icons.play_arrow, size: 20),
            tooltip: _autoRefresh ? 'Pause auto-refresh' : 'Resume auto-refresh',
            onPressed: () => setState(() => _autoRefresh = !_autoRefresh),
          ),
          IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: _load),
        ],
      ),
      body: Column(
        children: [
          if (manualModeActive)
            Container(
              width: double.infinity,
              color: Colors.orange.withValues(alpha: 0.15),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(children: [
                Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange.shade400),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Manual mode active — the clock is NOT showing the real time.',
                    style: TextStyle(fontSize: 12, color: Colors.orange.shade400, fontWeight: FontWeight.w500),
                  ),
                ),
                TextButton(
                  onPressed: _sending ? null : () => _send('r'),
                  child: const Text('Resume'),
                ),
              ]),
            ),
          Expanded(
            child: Container(
              width: double.infinity,
              color: Colors.black,
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text('Could not load the log', style: TextStyle(color: c.muted)),
                                const SizedBox(height: 6),
                                Text(_error!, style: TextStyle(fontSize: 11, color: c.muted), textAlign: TextAlign.center),
                                const SizedBox(height: 12),
                                FilledButton(onPressed: _load, child: const Text('Retry')),
                              ],
                            ),
                          ),
                        )
                      : _lines.isEmpty
                          ? Center(child: Text('No events logged yet', style: TextStyle(color: c.muted, fontSize: 12)))
                          : ListView.builder(
                              controller: _scrollCtl,
                              padding: const EdgeInsets.all(10),
                              itemCount: _lines.length,
                              itemBuilder: (context, i) {
                                final sent = _lines[i].startsWith('> ');
                                return Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 2),
                                  child: Text(
                                    _lines[i],
                                    style: TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 12,
                                      color: sent ? const Color(0xFF22D3EE) : const Color(0xFF34D399),
                                    ),
                                  ),
                                );
                              },
                            ),
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              color: c.card2,
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _cmdCtl,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'command, e.g. s, t, f3000, u 2026 7 24 16 30 0',
                      hintStyle: TextStyle(fontSize: 11, color: c.muted),
                      isDense: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _sending ? null : () => _send(),
                  icon: _sending
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.send, size: 18),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  void _showReference(BuildContext context, ClockColors c) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Commands', style: TextStyle(fontSize: 15, color: c.title, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text('Same set the physical USB console takes. Ones marked with '
                  '⚠ change what the display shows or write the RTC, and ask '
                  'for confirmation before sending.',
                  style: TextStyle(fontSize: 11, color: c.muted)),
              const SizedBox(height: 10),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.5),
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final (cmd, desc) in _commandRef)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            SizedBox(
                              width: 130,
                              child: Text(
                                (_isRiskyCmd(cmd.split(' ').first) ? '⚠ ' : '') + cmd,
                                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                              ),
                            ),
                            Expanded(child: Text(desc, style: TextStyle(fontSize: 12, color: c.muted))),
                          ]),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
