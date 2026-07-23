import 'dart:async';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'clock_api.dart';

/// A clock found on the LAN but not yet added.
class FoundClock {
  final String host;   // mDNS name if we got one, else the IP
  final ClockInfo info;
  FoundClock(this.host, this.info);
}

/// Finds clocks on the local network.
///
/// mDNS first (fast, gives us the `.local` name so the device survives a DHCP
/// address change). Android's multicast handling is unreliable on some ROMs,
/// so if mDNS turns up nothing we sweep the phone's /24 and probe `/api/info`
/// — slower, but it works everywhere.
class DiscoveryService {
  static const _serviceType = '_http._tcp.local';

  static Future<List<FoundClock>> scan({
    Duration mdnsTimeout = const Duration(seconds: 4),
  }) async {
    final viaMdns = await _scanMdns(mdnsTimeout);
    if (viaMdns.isNotEmpty) return viaMdns;
    return _scanSubnet();
  }

  static Future<List<FoundClock>> _scanMdns(Duration timeout) async {
    final found = <String, FoundClock>{};
    final client = MDnsClient();
    try {
      await client.start();
      final ptrStream = client.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer(_serviceType),
      );
      await for (final ptr in ptrStream.timeout(timeout, onTimeout: (s) => s.close())) {
        // The firmware registers as `clockwise-<chipid>` (startMDNS in main.cpp).
        if (!ptr.domainName.toLowerCase().startsWith('clockwise-')) continue;
        final host = ptr.domainName.replaceAll(RegExp(r'\._http\._tcp\.local\.?$'), '');
        final probed = await _probe('$host.local');
        if (probed == null) continue;
        // The probe that just verified this is a Clockwise clock already got its
        // real IP back in the same response -- use that instead of the .local
        // name. Android's mDNS resolution is per-request and slow (each API
        // call re-triggers a multicast lookup), which read as the whole app
        // lagging by about a second on every interaction. The IP can go stale
        // if the router reassigns it, but that's what re-scanning is for.
        final ip = probed.info.ip;
        found[probed.info.chipId] =
            ip.isNotEmpty ? FoundClock(ip, probed.info) : probed;
      }
    } catch (_) {
      // mDNS unsupported or blocked — caller falls through to the subnet sweep.
    } finally {
      client.stop();
    }
    return found.values.toList();
  }

  static Future<List<FoundClock>> _scanSubnet() async {
    final ip = await NetworkInfo().getWifiIP();
    if (ip == null || !ip.contains('.')) return [];
    final prefix = ip.substring(0, ip.lastIndexOf('.'));

    // Probe the whole /24 at once; each probe has its own short timeout so the
    // sweep finishes in about as long as one request.
    final results = await Future.wait([
      for (var i = 1; i < 255; i++)
        _probe('$prefix.$i', timeout: const Duration(milliseconds: 1200)),
    ]);
    return results.whereType<FoundClock>().toList();
  }

  /// Returns a FoundClock if `host` answers `/api/info` like a Clockwise clock.
  static Future<FoundClock?> _probe(
    String host, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      final info = await ClockApi(host, timeout: timeout).info();
      if (info.chipId.isEmpty) return null;
      return FoundClock(host, info);
    } catch (_) {
      return null;
    }
  }

  /// Public single-host probe — used when the user types an IP manually.
  static Future<FoundClock?> probe(String host) => _probe(host);
}
