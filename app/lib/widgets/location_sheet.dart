import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../screens/home_screen.dart' show showToast;
import '../services/clock_controller.dart';
import '../services/phone_location.dart';
import '../services/world_places.dart';
import '../theme/app_theme.dart';

/// The one place a clock's location and timezone are set.
///
/// Both come from a single choice on purpose: the timezone rule decides what
/// time the clock shows (and it handles daylight saving itself from then on),
/// and the coordinates decide sunrise/sunset for sun mode. Setting them
/// separately let them disagree, which is how a clock ends up an hour out.
Future<bool> showLocationSheet(BuildContext context) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _LocationSheet(),
  );
  return result ?? false;
}

class _LocationSheet extends StatefulWidget {
  const _LocationSheet();
  @override
  State<_LocationSheet> createState() => _LocationSheetState();
}

class _LocationSheetState extends State<_LocationSheet> {
  String _q = '';
  bool _locating = false;
  List<WorldPlace>? _places;

  @override
  void initState() {
    super.initState();
    WorldPlaces.load().then((p) {
      if (mounted) setState(() => _places = p);
    });
  }

  Future<void> _useGps() async {
    setState(() => _locating = true);
    final ctl = context.read<ClockController>();
    try {
      final loc = await PhoneLocationService.read();
      // Label from the nearest region, purely for display -- the coordinates
      // stored are the GPS ones, not the region's.
      final near = _places == null
          ? null
          : WorldPlaces.nearest(_places!, loc.lat, loc.lon);
      final ok = await ctl.setLocation(
        lat: loc.lat,
        lon: loc.lon,
        tzPosix: loc.tzPosix,
        zone: loc.tzName,
        label: near?.label ?? loc.tzName,
      );
      if (!mounted) return;
      showToast(context, ok ? 'Set to ${near?.label ?? loc.tzName}' : 'Failed');
      if (ok) Navigator.pop(context, true);
    } on PhoneLocationException catch (e) {
      if (mounted) showToast(context, e.message);
    } catch (_) {
      if (mounted) showToast(context, "Couldn't read location");
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _usePlace(WorldPlace r) async {
    final ctl = context.read<ClockController>();
    final ok = await ctl.setLocation(
      lat: r.lat,
      lon: r.lon,
      tzPosix: PhoneLocationService.posixFor(r.zone),
      zone: r.zone,
      label: r.label,
    );
    if (!mounted) return;
    showToast(context, ok ? 'Set to ${r.name}' : 'Failed');
    if (ok) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<ClockColors>()!;
    final places = _places;
    final list =
        places == null ? const <WorldPlace>[] : WorldPlaces.search(places, _q);

    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
          left: 14,
          right: 14,
          top: 14),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(children: [
          Text('Location & timezone',
              style: TextStyle(fontSize: 15, color: c.title)),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: _locating ? null : _useGps,
              icon: _locating
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.my_location, size: 18),
              label: Text(_locating ? 'Reading…' : 'Use my location'),
            ),
          ),
          const SizedBox(height: 6),
          Text('Exact. Searching below is spot-on for the time; a state '
              'puts sunrise a few minutes out, a city does not.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: c.muted)),
          Divider(color: c.divider, height: 22),
          TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Or search a city, state or country',
              isDense: true,
            ),
            onChanged: (v) => setState(() => _q = v),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: places == null
                ? const Center(child: CircularProgressIndicator())
                : list.isEmpty
                    ? Center(
                        child: Text('No match for "$_q"',
                            style: TextStyle(fontSize: 13, color: c.muted)),
                      )
                    : ListView.builder(
                        itemCount: list.length,
                        itemBuilder: (_, i) => ListTile(
                          dense: true,
                          title: Text(list[i].name,
                              style: TextStyle(fontSize: 14, color: c.title)),
                          subtitle: Text(list[i].subtitle,
                              style: TextStyle(fontSize: 11, color: c.muted)),
                          onTap: () => _usePlace(list[i]),
                        ),
                      ),
          ),
        ]),
      ),
    );
  }
}
