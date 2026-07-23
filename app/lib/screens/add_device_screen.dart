import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/clock_controller.dart';
import '../services/device_store.dart';
import '../services/discovery_service.dart';
import '../theme/app_theme.dart';
import '../widgets/clock_card.dart';

/// Adds a clock that's already on your WiFi: scan for it, or type its address.
/// A brand-new clock is set up through its own browser portal (join the
/// `Clockwise-Setup` network), not from here.
class AddDeviceScreen extends StatefulWidget {
  const AddDeviceScreen({super.key});
  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  bool _scanning = false;
  List<FoundClock> _found = [];
  bool _scanned = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scan());
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _scanned = true;
    });
    final r = await DiscoveryService.scan();
    if (!mounted) return;
    setState(() {
      _found = r;
      _scanning = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<ClockColors>()!;

    return Scaffold(
      appBar: AppBar(title: const Text('Add a clock')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
        children: [
          GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(
                      child: Text('Clocks on this WiFi',
                          style: TextStyle(fontSize: 14, color: c.title)),
                    ),
                    if (_scanning)
                      const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                    else
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 18),
                        onPressed: _scan,
                        tooltip: 'Scan again',
                      ),
                  ]),
                  const SizedBox(height: 4),
                  if (_scanning)
                    Text('Searching…', style: TextStyle(fontSize: 11, color: c.muted))
                  else if (_found.isEmpty && _scanned)
                    Text(
                      'Nothing found. Make sure the clock is powered on and '
                      'this phone is on the same WiFi — or enter its IP below.',
                      style: TextStyle(fontSize: 11, color: c.muted),
                    ),
                  for (final f in _found)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.watch_outlined, color: c.accent),
                      title: Text(f.info.name, style: TextStyle(color: c.title)),
                      subtitle: Text(
                        '${f.host}  ·  fw ${f.info.fw}'
                        '${f.info.authRequired ? "  ·  PIN required" : ""}',
                        style: TextStyle(fontSize: 11, color: c.muted),
                      ),
                      trailing: const Icon(Icons.add_circle_outline),
                      onTap: () => _add(f),
                    ),
                ],
              ),
            ),
          const _ManualHostCard(),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Brand-new clock?',
                    style: TextStyle(fontSize: 14, color: c.title)),
                const SizedBox(height: 4),
                Text(
                  'A clock with no saved WiFi opens its own network, '
                  '"Clockwise-Setup". Join it from your phone\'s WiFi settings '
                  'and a setup page opens in your browser — choose your WiFi '
                  'there. Once it\'s online, come back here and scan.',
                  style: TextStyle(fontSize: 11, color: c.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _add(FoundClock f) async {
    String? pin;
    if (f.info.authRequired) {
      pin = await _askPin(context, f.info.name);
      if (pin == null) return;
    }
    if (!mounted) return;
    await context.read<ClockController>().addDevice(SavedDevice(
          chipId: f.info.chipId,
          name: f.info.name,
          host: f.host,
          pin: pin,
        ));
    if (mounted) Navigator.of(context).pop();
  }
}

Future<String?> _askPin(BuildContext context, String name) {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('PIN for $name'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        obscureText: true,
        decoration: const InputDecoration(labelText: 'App PIN'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
          child: const Text('Add'),
        ),
      ],
    ),
  );
}

/// Fallback for networks where mDNS and the subnet sweep both come up empty
/// (guest isolation, odd subnets) — just type the address.
class _ManualHostCard extends StatefulWidget {
  const _ManualHostCard();
  @override
  State<_ManualHostCard> createState() => _ManualHostCardState();
}

class _ManualHostCardState extends State<_ManualHostCard> {
  final _host = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _host.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final host = _host.text.trim();
    if (host.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final found = await DiscoveryService.probe(host);
    if (!mounted) return;
    setState(() => _busy = false);
    if (found == null) {
      setState(() => _error = 'No clock answered at $host');
      return;
    }
    String? pin;
    if (found.info.authRequired) {
      pin = await _askPin(context, found.info.name);
      if (pin == null) return;
    }
    if (!mounted) return;
    await context.read<ClockController>().addDevice(SavedDevice(
          chipId: found.info.chipId,
          name: found.info.name,
          host: host,
          pin: pin,
        ));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<ClockColors>()!;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Or enter the address', style: TextStyle(fontSize: 14, color: c.title)),
          const SizedBox(height: 8),
          TextField(
            controller: _host,
            decoration: const InputDecoration(
              labelText: 'IP or hostname',
              hintText: '192.168.1.50  or  clockwise-a1b2c3.local',
              isDense: true,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 6),
            Text(_error!, style: const TextStyle(fontSize: 11, color: Colors.red)),
          ],
          const SizedBox(height: 10),
          FilledButton(
            onPressed: _busy ? null : _connect,
            child: Text(_busy ? 'Checking…' : 'Connect'),
          ),
        ],
      ),
    );
  }
}
