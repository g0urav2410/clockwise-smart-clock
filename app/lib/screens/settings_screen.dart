import 'dart:async';
import 'dart:convert';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import '../main.dart' show ClockApp;
import '../services/clock_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/clock_card.dart';
import '../widgets/location_sheet.dart';
import 'add_device_screen.dart';
import 'debug_screen.dart';
import 'device_log_screen.dart';
import 'home_screen.dart' show showToast;
import 'sensor_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ctl = context.watch<ClockController>();
    final c = Theme.of(context).extension<ClockColors>()!;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _tile(context, Icons.palette_outlined, 'Appearance',
              'Theme, logo LED', const AppearancePage()),
          _tile(context, Icons.watch_outlined, 'Device',
              ctl.hasDevice ? ctl.current!.name : 'No clock added',
              const DevicePage()),
          _tile(context, Icons.tune, 'Advanced',
              'Address, App PIN', const AdvancedPage()),
          _tile(context, Icons.cloud_outlined, 'MQTT / Home Assistant',
              'Broker for the Home Assistant integration', const MqttPage()),
          _tile(context, Icons.sensors, 'Presence sensor',
              'Live radar data, calibration', const SensorScreen()),
          _tile(context, Icons.bug_report_outlined, 'Display tuning',
              'Brightness curve, PWM frequency, step test',
              const DebugScreen()),
          _tile(context, Icons.terminal, 'Device log',
              'Recent events, like a serial monitor', const DeviceLogScreen()),
          Divider(color: c.divider),
          _tile(context, Icons.devices_other, 'My clocks',
              '${ctl.devices.length} added', const DevicesPage()),
          Divider(color: c.divider),
          // GeoNames is CC BY 4.0, so the credit is a licence condition, not
          // a courtesy -- it has to ship with the app.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
            child: Text(
              'State and timezone data from GeoNames (geonames.org), '
              'licensed CC BY 4.0.',
              style: TextStyle(fontSize: 11, color: c.muted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, IconData icon, String title, String sub,
      Widget page) {
    final c = Theme.of(context).extension<ClockColors>()!;
    return ListTile(
      leading: Icon(icon, color: c.accent),
      title: Text(title, style: TextStyle(color: c.title)),
      subtitle: Text(sub, style: TextStyle(fontSize: 11, color: c.muted)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () =>
          Navigator.of(context).push(MaterialPageRoute(builder: (_) => page)),
    );
  }
}

// ── Appearance ──────────────────────────────────────────────────────

class AppearancePage extends StatelessWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = ClockApp.of(context);
    final ctl = context.watch<ClockController>();
    final c = Theme.of(context).extension<ClockColors>()!;
    final mode = app?.themeMode ?? ThemeMode.system;

    return Scaffold(
      appBar: AppBar(title: const Text('Appearance')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Theme', style: TextStyle(fontSize: 14, color: c.title)),
                const SizedBox(height: 8),
                SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(value: ThemeMode.system, label: Text('System')),
                    ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                    ButtonSegment(value: ThemeMode.dark, label: Text('AMOLED')),
                  ],
                  selected: {mode},
                  onSelectionChanged: (s) => app?.setThemeMode(s.first),
                ),
              ],
            ),
          ),
          GlassCard(
            child: Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Logo LED', style: TextStyle(fontSize: 13, color: c.title)),
                    const SizedBox(height: 2),
                    Text('The lit Ajanta logo on the clock face.',
                        style: TextStyle(fontSize: 11, color: c.muted)),
                  ],
                ),
              ),
              Switch(
                value: ctl.config?.logo ?? true,
                onChanged: ctl.isConnected && ctl.config != null
                    ? (v) => ctl.patchConfig({'logo': v})
                    : null,
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

// ── Device ──────────────────────────────────────────────────────────

class DevicePage extends StatelessWidget {
  const DevicePage({super.key});

  @override
  Widget build(BuildContext context) {
    final ctl = context.watch<ClockController>();
    final c = Theme.of(context).extension<ClockColors>()!;

    if (!ctl.hasDevice) {
      return Scaffold(
        appBar: AppBar(title: const Text('Device')),
        body: Center(child: Text('No clock added', style: TextStyle(color: c.muted))),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Device')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _kv(c, 'Name', ctl.current!.name),
                _kv(c, 'Address', ctl.current!.host),
                // The clock's own reported IP only earns a row when it's
                // actually drifted from the saved address (e.g. the router
                // handed out a new one) -- showing it unconditionally was
                // just the same value twice in the common case.
                if ((ctl.info?.ip.isNotEmpty ?? false) &&
                    ctl.info!.ip != ctl.current!.host)
                  _kv(c, 'Reported IP (differs — try re-adding)', ctl.info!.ip),
                _kv(c, 'Firmware', ctl.info?.fw ?? '—'),
                _kv(c, 'Chip ID', ctl.current!.chipId),
                _kv(c, 'Last NTP sync',
                    (ctl.state?.lastSync.isNotEmpty ?? false)
                        ? ctl.state!.lastSync
                        : 'never'),
                Divider(color: c.divider, height: 22),
                // Sits with NTP sync rather than under Sun mode: this decides
                // what time the clock shows, so it belongs with the other
                // "is the clock right?" settings, not behind a feature the
                // user may never switch on.
                Row(children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Location & timezone',
                            style: TextStyle(fontSize: 12, color: c.muted)),
                        const SizedBox(height: 2),
                        Text(
                          // What the user actually picked, not a guess back
                          // from the coordinates -- see SavedDevice.tzZone.
                          ctl.current?.placeLabel ??
                              (ctl.config == null
                                  ? '—'
                                  : 'Set on the clock · ${ctl.config!.tz}'),
                          style: TextStyle(fontSize: 13, color: c.title),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => showLocationSheet(context),
                    child: const Text('Change'),
                  ),
                ]),
                const SizedBox(height: 2),
                Text(
                  'Daylight saving is handled by the clock itself once this '
                  'is set — nothing to change twice a year.',
                  style: TextStyle(fontSize: 11, color: c.muted),
                ),
              ],
            ),
          ),
          GlassCard(
            child: Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Daily time sync',
                        style: TextStyle(fontSize: 13, color: c.title)),
                    const SizedBox(height: 2),
                    Text(
                      'Checks NTP once a day at 3am and only corrects the '
                      'clock if it has actually drifted.',
                      style: TextStyle(fontSize: 11, color: c.muted),
                    ),
                  ],
                ),
              ),
              Switch(
                value: ctl.config?.autoSync ?? true,
                onChanged: ctl.isConnected && ctl.config != null
                    ? (v) => ctl.patchConfig({'autoSync': v})
                    : null,
              ),
            ]),
          ),
          GlassCard(
            child: Column(children: [
              _action(context, Icons.edit_outlined, 'Rename clock',
                  () => _rename(context, ctl)),
              _action(context, Icons.sync, 'Sync time now', () async {
                final ok = await ctl.syncTime();
                if (context.mounted) showToast(context, ok ? 'Synced' : 'Failed');
              }),
              _action(context, Icons.restart_alt, 'Reboot clock', () async {
                final ok = await ctl.reboot();
                if (context.mounted) {
                  showToast(context, ok ? 'Rebooting…' : 'Failed');
                }
              }),
            ]),
          ),
          const _OtaCard(),
          const _DeviceHealthCard(),
        ],
      ),
    );
  }

  Widget _kv(ClockColors c, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Expanded(child: Text(k, style: TextStyle(fontSize: 12, color: c.muted))),
          Flexible(
            child: Text(v,
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 12, color: c.title)),
          ),
        ]),
      );

  Widget _action(BuildContext context, IconData i, String label, VoidCallback tap) {
    final c = Theme.of(context).extension<ClockColors>()!;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      leading: Icon(i, size: 18, color: c.accent),
      title: Text(label, style: TextStyle(fontSize: 13, color: c.title)),
      onTap: tap,
    );
  }

  Future<void> _rename(BuildContext context, ClockController ctl) async {
    final t = TextEditingController(text: ctl.current!.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename clock'),
        content: TextField(controller: t, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, t.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final ok = await ctl.rename(name);
    if (context.mounted) showToast(context, ok ? 'Renamed' : 'Failed');
  }
}

/// In-app OTA — picks a .bin and POSTs it to the firmware's /update endpoint.
/// No browser involved. Uses Basic auth when the clock has a PIN set, matching
/// `httpUpdater.setup(&httpServer, "/update", "admin", cfg.apiToken)`.
class _OtaCard extends StatefulWidget {
  const _OtaCard();
  @override
  State<_OtaCard> createState() => _OtaCardState();
}

enum _OtaPhase { idle, uploading, rebooting, done, failed }

class _OtaCardState extends State<_OtaCard> {
  _OtaPhase _phase = _OtaPhase.idle;
  String? _status;
  double _progress = 0; // 0..1, upload only

  bool get _busy =>
      _phase == _OtaPhase.uploading || _phase == _OtaPhase.rebooting;

  /// The clock drops off the network while it flashes and boots. Poll until it
  /// answers again, so the card can say the new firmware is actually running
  /// rather than leaving the user to guess from a silent screen.
  Future<void> _waitForReboot() async {
    final ctl = context.read<ClockController>();
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    // It is still answering on the old firmware for a moment after the reply.
    await Future<void>.delayed(const Duration(seconds: 3));
    while (DateTime.now().isBefore(deadline)) {
      await ctl.refresh();
      final up = ctl.state?.uptimeMinutes;
      if (ctl.status == ConnStatus.connected && up != null && up < 2) {
        if (mounted) {
          setState(() {
            _phase = _OtaPhase.done;
            _status = 'Done — the clock is back up on the new firmware.';
          });
        }
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    if (mounted) {
      setState(() {
        _phase = _OtaPhase.done;
        _status = 'Flashed, but the clock has not answered yet. '
            'Give it a moment, then pull to refresh on Home.';
      });
    }
  }

  Future<void> _upload() async {
    final ctl = context.read<ClockController>();
    final file = await openFile(acceptedTypeGroups: [
      const XTypeGroup(label: 'firmware', extensions: ['bin']),
    ]);
    if (file == null) return;

    if (!mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Flash firmware?'),
        content: Text(
          '${file.name}\n\nThe clock will reboot into this firmware. '
          'Do not power it off during the update.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Flash')),
        ],
      ),
    );
    if (go != true) return;

    setState(() {
      _phase = _OtaPhase.uploading;
      _progress = 0;
      _status = 'Uploading ${file.name}…';
    });

    try {
      final bytes = await file.readAsBytes();

      // Built by hand rather than with MultipartRequest because that sends the
      // whole file in one opaque call -- there is no way to observe how far it
      // has got, which left the card frozen on "Uploading..." for half a minute
      // and reading as a hang. Streaming it in chunks is the only way to report
      // progress at all.
      const boundary = '----ajantaClockFirmwareBoundary';
      final head = utf8.encode('--$boundary\r\n'
          'Content-Disposition: form-data; name="firmware"; '
          'filename="${file.name}"\r\n'
          'Content-Type: application/octet-stream\r\n\r\n');
      final tail = utf8.encode('\r\n--$boundary--\r\n');

      final req = http.StreamedRequest(
        'POST',
        Uri.parse('http://${ctl.current!.host}/update'),
      );
      req.headers['Content-Type'] = 'multipart/form-data; boundary=$boundary';
      req.contentLength = head.length + bytes.length + tail.length;
      final pin = ctl.current!.pin;
      if (pin != null && pin.isNotEmpty) {
        req.headers['Authorization'] =
            'Basic ${base64EncodeCreds('admin', pin)}';
      }

      // What this measures is bytes handed to the socket, not bytes the clock
      // has flashed -- addStream applies backpressure, so it tracks the real
      // transfer closely, but expect it to reach 100% slightly early and sit
      // there while the device finishes writing. Hence a separate "rebooting"
      // phase rather than pretending the bar means completion.
      Stream<List<int>> body() async* {
        yield head;
        const chunk = 4096;
        for (var i = 0; i < bytes.length; i += chunk) {
          final end = (i + chunk < bytes.length) ? i + chunk : bytes.length;
          yield bytes.sublist(i, end);
          if (mounted) setState(() => _progress = end / bytes.length);
        }
        yield tail;
      }

      unawaited(req.sink.addStream(body()).whenComplete(req.sink.close));
      final resp = await req.send().timeout(const Duration(minutes: 3));
      // Drain it: the updater replies before restarting, and an unread body can
      // leave the socket open across the reboot.
      await resp.stream.drain<void>();

      if (resp.statusCode != 200) {
        setState(() {
          _phase = _OtaPhase.failed;
          _status = 'Failed (HTTP ${resp.statusCode}) — the clock kept its '
              'existing firmware.';
        });
        return;
      }

      setState(() {
        _phase = _OtaPhase.rebooting;
        _progress = 1;
        _status = 'Flashed. Waiting for the clock to reboot…';
      });
      await _waitForReboot();
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _OtaPhase.failed;
          _status = 'Upload failed: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<ClockColors>()!;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Firmware update', style: TextStyle(fontSize: 14, color: c.title)),
          const SizedBox(height: 4),
          Text('Pick a .bin built by PlatformIO and send it over WiFi.',
              style: TextStyle(fontSize: 11, color: c.muted)),
          if (_phase == _OtaPhase.uploading) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(value: _progress, minHeight: 5),
            ),
            const SizedBox(height: 4),
            Text('${(_progress * 100).round()}%',
                style: TextStyle(fontSize: 11, color: c.muted)),
          ],
          // Indeterminate on purpose: nothing is measurable once the device is
          // flashing and booting, and a frozen percentage would read as stalled.
          if (_phase == _OtaPhase.rebooting) ...[
            const SizedBox(height: 10),
            const ClipRRect(
              borderRadius: BorderRadius.all(Radius.circular(3)),
              child: LinearProgressIndicator(minHeight: 5),
            ),
          ],
          if (_status != null) ...[
            const SizedBox(height: 8),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (_phase == _OtaPhase.done)
                Icon(Icons.check_circle, size: 15, color: c.accent)
              else if (_phase == _OtaPhase.failed)
                const Icon(Icons.error_outline, size: 15, color: Colors.red),
              if (_phase == _OtaPhase.done || _phase == _OtaPhase.failed)
                const SizedBox(width: 6),
              Expanded(
                child: Text(_status!,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: _phase == _OtaPhase.done
                            ? FontWeight.w500
                            : FontWeight.normal,
                        color: _phase == _OtaPhase.failed
                            ? Colors.red
                            : c.accent)),
              ),
            ]),
          ],
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _busy ? null : _upload,
            icon: Icon(
                _phase == _OtaPhase.done
                    ? Icons.check
                    : Icons.upload_file,
                size: 16),
            label: Text(switch (_phase) {
              _OtaPhase.uploading => 'Uploading…',
              _OtaPhase.rebooting => 'Rebooting…',
              _OtaPhase.done => 'Flash another',
              _ => 'Choose firmware file',
            }),
          ),
        ],
      ),
    );
  }
}

/// The ESP8266 has no real task scheduler and so no "CPU load %" to report —
/// see MANUAL.md "The clock face on Home" for why. Free heap / fragmentation
/// (the thing that actually causes long-uptime crashes) and the main-loop
/// rate (drops if something's blocking) are the closest useful equivalent.
class _DeviceHealthCard extends StatelessWidget {
  const _DeviceHealthCard();

  @override
  Widget build(BuildContext context) {
    final ctl = context.watch<ClockController>();
    final c = Theme.of(context).extension<ClockColors>()!;
    final info = ctl.info;
    final s = ctl.state;

    // All of these are on firmware added 2026-07-24 -- silently show nothing
    // rather than a card full of dashes on an older build.
    if (s?.freeHeap == null && info?.cpuFreqMHz == null) {
      return const SizedBox.shrink();
    }

    final fragPct = s?.heapFragPct;
    final fragWarn = fragPct != null && fragPct >= 40;

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Device health', style: TextStyle(fontSize: 13, color: c.title)),
          const SizedBox(height: 8),
          if (s?.freeHeap != null) _kv(c, 'Free memory', '${(s!.freeHeap! / 1024).toStringAsFixed(1)} KB'),
          if (fragPct != null)
            _kv(
              c,
              'Memory fragmentation',
              '$fragPct%',
              valueColor: fragWarn ? c.amber : null,
            ),
          if (s?.loopHz != null) _kv(c, 'Main loop rate', '${s!.loopHz} Hz'),
          if (info?.cpuFreqMHz != null) _kv(c, 'CPU speed', '${info!.cpuFreqMHz} MHz'),
          if (info?.sketchSize != null && info?.freeSketchSpace != null)
            _kv(c, 'Firmware storage used',
                '${(info!.sketchSize! / 1024).toStringAsFixed(0)} / '
                '${((info.sketchSize! + info.freeSketchSpace!) / 1024).toStringAsFixed(0)} KB'),
          if (info?.lastResetReason != null) _kv(c, 'Last reboot cause', info!.lastResetReason!),
          if (fragWarn) ...[
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.info_outline, size: 14, color: c.amber),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Memory is fairly fragmented. Usually harmless, but if the '
                  'clock ever freezes after days of uptime, a reboot clears it.',
                  style: TextStyle(fontSize: 11, color: c.amber),
                ),
              ),
            ]),
          ],
        ],
      ),
    );
  }

  Widget _kv(ClockColors c, String k, String v, {Color? valueColor}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(k, style: TextStyle(fontSize: 12, color: c.muted))),
          Text(v, style: TextStyle(fontSize: 12, color: valueColor ?? c.title, fontWeight: FontWeight.w500)),
        ]),
      );
}

String base64EncodeCreds(String user, String pass) =>
    base64Encode(utf8.encode('$user:$pass'));

// ── Advanced ────────────────────────────────────────────────────────

class AdvancedPage extends StatefulWidget {
  const AdvancedPage({super.key});
  @override
  State<AdvancedPage> createState() => _AdvancedPageState();
}

class _AdvancedPageState extends State<AdvancedPage> {
  final _pin = TextEditingController();
  final _host = TextEditingController();
  bool _filled = false;

  void _fill(ClockController ctl) {
    if (_filled || ctl.config == null) return;
    _filled = true;
    _pin.text = ctl.current?.pin ?? '';
    _host.text = ctl.current?.host ?? '';
  }

  @override
  void dispose() {
    for (final t in [_pin, _host]) {
      t.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctl = context.watch<ClockController>();
    final c = Theme.of(context).extension<ClockColors>()!;
    _fill(ctl);

    return Scaffold(
      appBar: AppBar(title: const Text('Advanced')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Connection', style: TextStyle(fontSize: 14, color: c.title)),
                const SizedBox(height: 8),
                TextField(
                  controller: _host,
                  decoration: const InputDecoration(
                      labelText: 'Address (IP or .local)', isDense: true),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _pin,
                  decoration: const InputDecoration(
                    labelText: 'App PIN',
                    helperText: 'Must match the PIN set on the clock',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: ctl.hasDevice
                      ? () async {
                          await ctl.updateCurrent(
                            host: _host.text.trim(),
                            pin: _pin.text.trim(),
                          );
                          if (context.mounted) showToast(context, 'Saved');
                        }
                      : null,
                  child: const Text('Save & reconnect'),
                ),
              ],
            ),
          ),
          // PWM frequency deliberately lives only on the Display tuning page,
          // beside the pulse-width readout that is the reason to change it.
          // Having it in both places meant a value set in one showed up in the
          // other as whichever preset it wasn't.
          // MQTT / Home Assistant now has its own page (MqttPage) so the broker
          // fields aren't buried under Advanced.
        ],
      ),
    );
  }
}

// ── MQTT / Home Assistant ───────────────────────────────────────────

class MqttPage extends StatefulWidget {
  const MqttPage({super.key});
  @override
  State<MqttPage> createState() => _MqttPageState();
}

class _MqttPageState extends State<MqttPage> {
  final _mqttHost = TextEditingController();
  final _mqttPort = TextEditingController();
  final _mqttUser = TextEditingController();
  final _mqttPass = TextEditingController();
  bool _filled = false;

  void _fill(ClockController ctl) {
    if (_filled || ctl.config == null) return;
    _filled = true;
    _mqttHost.text = ctl.config!.mqttHost;
    _mqttPort.text = ctl.config!.mqttPort.toString();
    _mqttUser.text = ctl.config!.mqttUser;
  }

  @override
  void dispose() {
    for (final t in [_mqttHost, _mqttPort, _mqttUser, _mqttPass]) {
      t.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctl = context.watch<ClockController>();
    final c = Theme.of(context).extension<ClockColors>()!;
    _fill(ctl);

    return Scaffold(
      appBar: AppBar(title: const Text('MQTT / Home Assistant')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Broker',
                    style: TextStyle(fontSize: 14, color: c.title)),
                const SizedBox(height: 4),
                Text(
                  'Optional. The clock connects to the broker itself — the app '
                  'does not need it. Leave the host empty to disable.',
                  style: TextStyle(fontSize: 11, color: c.muted),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _mqttHost,
                  decoration:
                      const InputDecoration(labelText: 'Broker host', isDense: true),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _mqttPort,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Port', isDense: true),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _mqttUser,
                  decoration:
                      const InputDecoration(labelText: 'Username', isDense: true),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _mqttPass,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    helperText: 'Leave blank to keep the saved one',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  ctl.state?.mqttConnected == true
                      ? 'Broker connected'
                      : 'Broker not connected',
                  style: TextStyle(
                    fontSize: 11,
                    color: ctl.state?.mqttConnected == true ? c.presence : c.muted,
                  ),
                ),
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: ctl.isConnected
                      ? () async {
                          final ok = await ctl.patchConfig({
                            'mqttHost': _mqttHost.text.trim(),
                            'mqttPort':
                                int.tryParse(_mqttPort.text.trim()) ?? 1883,
                            'mqttUser': _mqttUser.text.trim(),
                            if (_mqttPass.text.isNotEmpty)
                              'mqttPass': _mqttPass.text,
                          });
                          if (context.mounted) {
                            showToast(context, ok ? 'Saved to clock' : 'Failed');
                          }
                        }
                      : null,
                  child: const Text('Save broker settings'),
                ),
                // Explicitly wipe the saved login back to empty -- for a broker
                // with no auth. (A blank password field means "keep", so this
                // is the only way to actually clear it.)
                TextButton(
                  onPressed: ctl.isConnected
                      ? () async {
                          final ok = await ctl.patchConfig(
                              {'mqttUser': '', 'mqttPass': ''});
                          if (ok) {
                            _mqttUser.clear();
                            _mqttPass.clear();
                          }
                          if (context.mounted) {
                            showToast(context,
                                ok ? 'Login cleared' : 'Failed');
                          }
                        }
                      : null,
                  child: const Text('Clear saved login (no auth)'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Device switcher ─────────────────────────────────────────────────

class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final ctl = context.watch<ClockController>();
    final c = Theme.of(context).extension<ClockColors>()!;

    return Scaffold(
      appBar: AppBar(title: const Text('My clocks')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const AddDeviceScreen())),
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
      body: ListView(
        children: [
          for (final d in ctl.devices)
            ListTile(
              leading: Icon(
                d.chipId == ctl.current?.chipId
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: c.accent,
              ),
              title: Text(d.name, style: TextStyle(color: c.title)),
              subtitle:
                  Text(d.host, style: TextStyle(fontSize: 11, color: c.muted)),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => ctl.removeDevice(d.chipId),
              ),
              onTap: () => ctl.selectDevice(d.chipId),
            ),
          if (ctl.devices.isEmpty)
            Padding(
              padding: const EdgeInsets.all(28),
              child: Text('No clocks yet.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: c.muted)),
            ),
        ],
      ),
    );
  }
}
