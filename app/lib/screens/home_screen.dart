import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/clock_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/clock_card.dart';
import 'add_device_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ctl = context.watch<ClockController>();
    final c = Theme.of(context).extension<ClockColors>()!;

    if (!ctl.hasDevice) return const _NoDeviceYet();

    return RefreshIndicator(
      onRefresh: ctl.refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
        children: [
          const ConnectionBanner(),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(
                    child: Text(ctl.current!.name,
                        style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w500,
                            color: c.title)),
                  ),
                  OnlinePill(online: ctl.isConnected),
                ]),
                const SizedBox(height: 3),
                Text(ctl.current!.host,
                    style: TextStyle(fontSize: 11, color: c.muted)),
              ],
            ),
          ),
          const _ClockTimeCard(),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.light_mode_outlined, size: 15, color: c.muted),
                  const SizedBox(width: 8),
                  Text('Brightness', style: TextStyle(fontSize: 13, color: c.title)),
                  const Spacer(),
                  Text('${ctl.state?.brightness ?? 0}%',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: c.accent)),
                ]),
                const SizedBox(height: 10),
                GradientBar(fraction: (ctl.state?.brightness ?? 0) / 100),
              ],
            ),
          ),
          GlassCard(
            child: GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 2.6,
              children: [
                StatChip(
                  value: ctl.state?.presence == true ? 'Detected' : 'Clear',
                  label: 'PRESENCE',
                  valueColor: ctl.state?.presence == true ? c.presence : null,
                ),
                StatChip(
                  value: ctl.state == null ? '—' : '${ctl.state!.rssi} dBm',
                  label: 'WIFI SIGNAL',
                ),
                StatChip(
                  value: ctl.state == null ? '—' : _uptime(ctl.state!.uptimeMinutes),
                  label: 'UPTIME',
                ),
                StatChip(
                  value: ctl.state?.mqttConnected == true ? 'Connected' : 'Off',
                  label: 'MQTT / HA',
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
                    Text('Time sync', style: TextStyle(fontSize: 13, color: c.title)),
                    const SizedBox(height: 2),
                    Text(
                      (ctl.state?.lastSync.isNotEmpty ?? false)
                          ? 'Last synced ${ctl.state!.lastSync}'
                          : 'Never synced',
                      style: TextStyle(fontSize: 11, color: c.muted),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: ctl.isConnected
                    ? () async {
                        final ok = await ctl.syncTime();
                        if (context.mounted) {
                          showToast(context, ok ? 'Synced' : 'Sync failed');
                        }
                      }
                    : null,
                icon: const Icon(Icons.sync, size: 16),
                label: const Text('Sync now'),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  static String _uptime(int minutes) {
    if (minutes < 60) return '$minutes min';
    final h = minutes ~/ 60;
    if (h < 24) return '${h}h ${minutes % 60}m';
    return '${h ~/ 24}d ${h % 24}h';
  }
}

/// What the clock itself thinks the time is. This is the whole point of the
/// device, so it leads the screen — and because it's the clock's own RTC and
/// not the phone's clock, drift shows up here instead of hiding.
class _ClockTimeCard extends StatelessWidget {
  const _ClockTimeCard();

  @override
  Widget build(BuildContext context) {
    final ctl = context.watch<ClockController>();
    final c = Theme.of(context).extension<ClockColors>()!;
    final s = ctl.state;

    // Older firmware doesn't send these — show nothing rather than a wrong time.
    if (s == null || !s.rtcOk || s.prettyTime == null) {
      return const SizedBox.shrink();
    }

    // Against what the clock's *own* timezone says it should be, not against
    // the phone. A clock deliberately set to London is 4h30 from an Indian
    // phone, and comparing the two called that drift and told the user to
    // re-sync a clock that was perfectly correct.
    //
    // Only when the offset is actually the clock's, though -- from the device
    // itself, or from a zone this phone saved. Without either it falls back to
    // this phone's own offset, which is the very comparison that produced the
    // false alarm. Better to say nothing than to accuse a correct clock.
    final knowsZone = ctl.knowsClockTz;
    final expected = DateTime.now()
        .toUtc()
        .add(Duration(minutes: (ctl.previewTzHours * 60).round()));
    final expectedMinutes = expected.hour * 60 + expected.minute;
    final parts = s.time!.split(':');
    final clockMinutes =
        (int.tryParse(parts[0]) ?? 0) * 60 + (int.tryParse(parts[1]) ?? 0);
    var diff = (expectedMinutes - clockMinutes).abs();
    if (diff > 720) diff = 1440 - diff; // wrap around midnight
    final drifted = knowsZone && diff >= 2;

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.prettyTime!,
              style: TextStyle(
                  fontSize: 40, fontWeight: FontWeight.w300, color: c.title)),
          const SizedBox(height: 2),
          Text(
            [s.dayName, s.date].whereType<String>().join(' · '),
            style: TextStyle(fontSize: 12, color: c.muted),
          ),
          if (drifted) ...[
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.error_outline, size: 14, color: c.amber),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Clock is ${diff}m off for its timezone — try Sync now.',
                  style: TextStyle(fontSize: 11, color: c.amber),
                ),
              ),
            ]),
          ],
        ],
      ),
    );
  }
}

void showToast(BuildContext context, String msg) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

/// Explicit connection state, so the UI never sits on stale values pretending
/// to be live.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final ctl = context.watch<ClockController>();
    final c = Theme.of(context).extension<ClockColors>()!;

    final String text;
    final Color color;
    final IconData icon;

    switch (ctl.status) {
      case ConnStatus.connected:
      case ConnStatus.idle:
        return const SizedBox.shrink();
      case ConnStatus.searching:
        text = 'Looking for ${ctl.current?.name ?? "the clock"}…';
        color = c.amber;
        icon = Icons.wifi_find;
      case ConnStatus.unauthorized:
        text = 'PIN required — set it in Settings → Advanced';
        color = Colors.red;
        icon = Icons.lock_outline;
      case ConnStatus.unreachable:
        text = "Can't reach the clock. Same WiFi? Tap to retry.";
        color = Colors.red;
        icon = Icons.cloud_off;
    }

    return GestureDetector(
      onTap: ctl.refresh,
      // Long-press shows the underlying error. Failures here are usually
      // refused/timed-out connections, which never reach the firmware and so
      // leave nothing in its serial log — this is the only place to see them.
      onLongPress: ctl.lastError == null
          ? null
          : () => showDialog(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Last connection error'),
                  content: SelectableText(ctl.lastError!),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          border: Border.all(color: color.withValues(alpha: 0.3), width: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 12, color: color, fontWeight: FontWeight.w500)),
          ),
        ]),
      ),
    );
  }
}

class _NoDeviceYet extends StatelessWidget {
  const _NoDeviceYet();

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<ClockColors>()!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.watch_outlined, size: 48, color: c.muted),
            const SizedBox(height: 16),
            Text('No clock added yet', style: TextStyle(fontSize: 16, color: c.title)),
            const SizedBox(height: 6),
            Text(
              'Add your clock to see its status and control it.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: c.muted),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AddDeviceScreen()),
              ),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add a clock'),
            ),
          ],
        ),
      ),
    );
  }
}
