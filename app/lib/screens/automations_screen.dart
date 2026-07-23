import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/clock_api.dart';
import '../services/clock_controller.dart';
import '../services/sun_math.dart';
import '../theme/app_theme.dart';
import '../widgets/clock_card.dart';
import '../widgets/day_curve.dart';
import '../widgets/location_sheet.dart';
import 'home_screen.dart' show ConnectionBanner;

/// Automations = the day/night brightness schedule.
///
/// Master toggle ON  → schedule fields (times + levels) + fade duration.
/// Master toggle OFF → a plain manual brightness slider instead. The two are
/// deliberately mutually exclusive; never both on screen at once.
///
/// The toggle is the clock's own `sched` setting, not an app preference — the
/// schedule runs on the device, so the device is the source of truth.
class AutomationsScreen extends StatefulWidget {
  const AutomationsScreen({super.key});
  @override
  State<AutomationsScreen> createState() => _AutomationsScreenState();
}

class _AutomationsScreenState extends State<AutomationsScreen> {
  // Live slider values during a drag, so the day strip moves with the finger.
  // Null means "not dragging -- use whatever the clock's config says".
  int? _dragSunFull, _dragSunNight;

  void _preview(bool isFull, int v) => setState(() {
        final val = v < 0 ? null : v;
        if (isFull) {
          _dragSunFull = val;
        } else {
          _dragSunNight = val;
        }
      });

  @override
  Widget build(BuildContext context) {
    final ctl = context.watch<ClockController>();
    final c = Theme.of(context).extension<ClockColors>()!;

    if (!ctl.hasDevice) {
      return Center(
        child: Text('Add a clock first', style: TextStyle(color: c.muted)),
      );
    }

    final cfg = ctl.config;
    final mode = cfg?.mode ?? 0;

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
                Text('Brightness', style: TextStyle(fontSize: 14, color: c.title)),
                const SizedBox(height: 8),
                SegmentedButton<int>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 0, label: Text('Manual', style: TextStyle(fontSize: 12))),
                    ButtonSegment(value: 1, label: Text('Schedule', style: TextStyle(fontSize: 12))),
                    ButtonSegment(value: 2, label: Text('Sun', style: TextStyle(fontSize: 12))),
                  ],
                  selected: {mode},
                  onSelectionChanged: ctl.isConnected && cfg != null
                      ? (s) => ctl.patchConfig({'mode': s.first})
                      : null,
                ),
                const SizedBox(height: 8),
                Text(
                  switch (mode) {
                    2 => 'Follows the real sun for your location — brightest '
                        'around midday, easing down to dusk, dim overnight.',
                    1 => 'Two levels, day and night, with a timed ramp between.',
                    _ => 'Stays wherever you set it.',
                  },
                  style: TextStyle(fontSize: 11, color: c.muted),
                ),
              ],
            ),
          ),
          if (cfg == null)
            GlassCard(
              child: Text('Waiting for the clock’s config…',
                  style: TextStyle(fontSize: 12, color: c.muted)),
            )
          else if (mode == 2) ...[
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _label(c, 'BRIGHTNESS RANGE'),
                  _PercentRow(
                    label: 'Midday (sun high)',
                    value: cfg.sunFull,
                    configKey: 'sunFull',
                    onPreview: (v) => _preview(true, v),
                  ),
                  Divider(color: c.divider, height: 22),
                  _PercentRow(
                    label: 'Night (sun down)',
                    value: cfg.sunNight,
                    configKey: 'sunNight',
                    onPreview: (v) => _preview(false, v),
                  ),
                ],
              ),
            ),
            _SunStatusCard(
                cfg: cfg,
                fullOverride: _dragSunFull,
                nightOverride: _dragSunNight),
            _SunTwilightCard(
                dawn: cfg.sunDawn,
                dusk: cfg.sunDusk,
                lat: cfg.lat,
                lon: cfg.lon,
                tz: ctl.previewTzHours),
            const _LocationCard(),
          ]
          else if (mode == 1) ...[
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _label(c, 'DAY'),
                  _PercentRow(
                    label: 'Daytime brightness',
                    value: cfg.full,
                    configKey: 'full',
                  ),
                  Divider(color: c.divider, height: 22),
                  _label(c, 'NIGHT'),
                  _PercentRow(
                    label: 'Night brightness',
                    value: cfg.night,
                    configKey: 'night',
                  ),
                  _HourRow(
                    label: 'Night starts',
                    hour: cfg.nightStart,
                    onChanged: (h) => ctl.patchConfig({'nightStart': h}),
                  ),
                  _HourRow(
                    label: 'Night ends',
                    hour: cfg.nightEnd,
                    onChanged: (h) => ctl.patchConfig({'nightEnd': h}),
                  ),
                  // Allowed — you might genuinely want it — but it's usually a
                  // mistake, and silently doing the opposite of "dims at
                  // night" is worth saying out loud.
                  if (cfg.night > cfg.full) ...[
                    const SizedBox(height: 6),
                    Row(children: [
                      Icon(Icons.info_outline, size: 14, color: c.amber),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'Night is brighter than day — the clock will get '
                          'brighter at night, not dimmer.',
                          style: TextStyle(fontSize: 11, color: c.amber),
                        ),
                      ),
                    ]),
                  ],
                ],
              ),
            ),
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _label(c, 'TRANSITION'),
                  _TransitionRow(minutes: cfg.transitionMin),
                  const SizedBox(height: 4),
                  OutlinedButton.icon(
                    onPressed: () => _previewNight(ctl, cfg.night),
                    icon: const Icon(Icons.nightlight_outlined, size: 16),
                    label: const Text('Preview night mode'),
                  ),
                ],
              ),
            ),
            GlassCard(
              child: Row(children: [
                Icon(Icons.info_outline, size: 15, color: c.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'The schedule runs on the clock itself — it keeps working '
                    'even if your phone, WiFi or Home Assistant is off.',
                    style: TextStyle(fontSize: 11, color: c.muted),
                  ),
                ),
              ]),
            ),
          ] else
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _PercentRow(
                    label: 'Brightness',
                    value: cfg.manual,
                    configKey: 'manual',
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Shows the night level on the real clock without saving anything.
  ///
  /// This used to write `full` and rely on the user tapping "Restore" — if
  /// they didn't, their daytime brightness was silently left at the night
  /// value. The live endpoint doesn't persist, and the firmware's preview hold
  /// expires on its own, so the schedule takes back over by itself.
  void _previewNight(ClockController ctl, int night) {
    ctl.setBrightnessLive(night);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Showing night brightness — reverts in a moment'),
      duration: Duration(seconds: 3),
    ));
  }

  Widget _label(ClockColors c, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text,
            style: TextStyle(fontSize: 10, color: c.muted, letterSpacing: 1.2)),
      );
}

/// What the sun is doing right now, so sun mode isn't a black box.
class _SunStatusCard extends StatelessWidget {
  final ClockConfig cfg;

  /// Slider values mid-drag. The clock hasn't been told about these yet, so the
  /// strip has to use them directly rather than waiting for the config to come
  /// back on the next poll.
  final int? fullOverride, nightOverride;

  const _SunStatusCard(
      {required this.cfg, this.fullOverride, this.nightOverride});

  @override
  Widget build(BuildContext context) {
    final ctl = context.watch<ClockController>();
    final c = Theme.of(context).extension<ClockColors>()!;
    final elev = ctl.state?.sunElev;
    final full = fullOverride ?? cfg.sunFull;
    final night = nightOverride ?? cfg.sunNight;
    final dragging = fullOverride != null || nightOverride != null;
    final pct = ctl.state?.sunPct;

    if (elev == null) {
      return GlassCard(
        child: Text('Waiting for the clock…',
            style: TextStyle(fontSize: 12, color: c.muted)),
      );
    }

    // Only the app's own preview curve needs a plain number -- the real clock
    // gets a full POSIX rule (cfg.tz) and resolves DST itself. Taken from the
    // zone the user actually chose, not guessed back from the coordinates:
    // the nearest zone anchor to Jammu is Kabul, which drew this an hour out.
    final previewTz = ctl.previewTzHours;
    final facts = SunMath.dayFacts(
        lat: cfg.lat, lon: cfg.lon, tzHours: previewTz);

    // Height alone can't tell rising from setting -- 30 degrees up happens
    // twice a day. Compare against a little later to get the direction.
    //
    // The clock's own time, not the phone's: they're in different timezones
    // whenever the device is set somewhere else, and using the phone's drew
    // the "now" marker hours adrift from what the display was doing.
    final now = ctl.clockNow ?? DateTime.now();
    final soon = SunMath.elevation(
        lat: cfg.lat, lon: cfg.lon, tzHours: previewTz,
        local: now.add(const Duration(minutes: 15)));
    final nowCalc = SunMath.elevation(
        lat: cfg.lat, lon: cfg.lon, tzHours: previewTz, local: now);
    final rising = soon > nowCalc;

    // Describes the sun only, never the user's settings. It used to say
    // "After sunset" above cfg.sunLow and "Night" below it, so changing the
    // twilight setting made this label flip -- which read as the sun's
    // position depending on a brightness preference. It doesn't.
    //
    // "High in the sky" is measured against today's own peak, not the dead
    // cfg.sunHigh, which nothing uses since the curve started scaling to the
    // peak. Any fixed angle means something different in June and December.
    final String phase;
    if (elev >= facts.peakElev * 0.95) {
      phase = 'High in the sky';
    } else if (elev >= 0) {
      phase = rising ? 'Coming up' : 'Going down';
    } else {
      phase = 'Night';
    }

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(
                elev < 0
                    ? Icons.nightlight_outlined
                    : rising
                        ? Icons.wb_twilight
                        : Icons.wb_sunny_outlined,
                size: 16,
                color: elev >= 0 ? c.amber : c.muted),
            const SizedBox(width: 8),
            Text('Sun right now', style: TextStyle(fontSize: 13, color: c.title)),
          ]),
          const SizedBox(height: 8),
          Row(crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic, children: [
            Text('${pct ?? 0}',
                style: TextStyle(
                    fontSize: 24, fontWeight: FontWeight.w500, color: c.title)),
            const SizedBox(width: 4),
            Text('% now', style: TextStyle(fontSize: 13, color: c.muted)),
            const Spacer(),
            Text('$phase · ${elev.toStringAsFixed(1)}°',
                style: TextStyle(fontSize: 11, color: c.muted)),
          ]),
          const SizedBox(height: 4),
          DayCurve(
            // The shape is cached on location and date, so a drag only redoes
            // the cheap level maths -- no solar positions per frame.
            brightness: SunMath.brightnessFromShape(
              SunMath.dayShape(
                lat: cfg.lat,
                lon: cfg.lon,
                tzHours: previewTz,
                dawnDeg: cfg.sunDawn,
                duskDeg: cfg.sunDusk,
                segments: 96,
              ),
              night,
              full,
            ),
            nowMinute: now.hour * 60 + now.minute,
            riseMinute: facts.riseMin,
            setMinute: facts.setMin,
            peakMinute: facts.peakMin,
          ),
          const SizedBox(height: 9),
          Container(
            padding: const EdgeInsets.only(top: 9),
            decoration: BoxDecoration(
                border: Border(top: BorderSide(color: c.divider, width: 0.5))),
            child: Row(children: [
              _fact(c, 'Sunrise', SunFacts.hhmm(facts.riseMin)),
              _fact(c, 'Peak', SunFacts.hhmm(facts.peakMin)),
              _fact(c, 'Sunset', SunFacts.hhmm(facts.setMin)),
              _fact(c, dragging ? 'Adjusting' : 'Daylight',
                  dragging ? '$night–$full%' : _dur(facts.daylight)),
            ]),
          ),
          const SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            for (final t in ['12a', '6a', '12p', '6p', '12a'])
              Text(t, style: TextStyle(fontSize: 10, color: c.muted)),
          ]),
        ],
      ),
    );
  }
}

Widget _fact(ClockColors c, String label, String value) => Expanded(
      child: Column(children: [
        Text(label, style: TextStyle(fontSize: 10, color: c.muted)),
        Text(value, style: TextStyle(fontSize: 12, color: c.title)),
      ]),
    );

String _dur(Duration? d) => d == null
    ? '—'
    : '${d.inHours}h ${(d.inMinutes % 60).toString().padLeft(2, '0')}m';

/// How far either side of sunrise and sunset the clock keeps some light.
///
/// This was called "Style" and set two angles. Only the lower one still does
/// anything -- the curve now scales to each day's own peak, so the upper angle
/// stopped mattering -- and a control that silently sets nothing is worse than
/// no control. So: one setting, named after what you actually see, showing the
/// window it produces rather than an angle nobody can picture.
///
/// The effect is symmetric: it starts brightening as long before sunrise as it
/// keeps light after sunset, so both ends are shown.
class _SunTwilightCard extends StatefulWidget {
  final double dawn, dusk, lat, lon, tz;
  const _SunTwilightCard(
      {required this.dawn,
      required this.dusk,
      required this.lat,
      required this.lon,
      required this.tz});

  // Stored as degrees below the horizon, shown as the time it produces today.
  //
  // Degrees rather than minutes because they are the real definition of
  // twilight and behave sensibly at any latitude -- "30 minutes after sunset"
  // stops meaning anything far north, where in summer the sun barely sets. The
  // cost is that the resulting time drifts a little through the year: measured
  // at this latitude, an angle worth 30 minutes today gives 28-33 across the
  // seasons. That is under a minute of change per three weeks, so the number
  // shown stays honest without ever visibly jumping.
  // Morning runs the other way to evening on purpose. Waiting until the sun is
  // properly up is what you want at dawn (positive angles, up to about 100 min
  // after sunrise); staying lit past sunset is what you want at dusk (negative,
  // to about 140 min after). Both then read as "how long after", counting up.
  //
  // Stopping at -24 rather than deeper because past roughly -30 the sun never
  // reaches the angle on some days and the setting silently does nothing.
  static const _dawnMax = 20.0, _duskMax = -24.0;

  @override
  State<_SunTwilightCard> createState() => _SunTwilightCardState();
}

class _SunTwilightCardState extends State<_SunTwilightCard> {
  double? _dragDawn, _dragDusk;

  @override
  Widget build(BuildContext context) {
    final ctl = context.read<ClockController>();
    final c = Theme.of(context).extension<ClockColors>()!;

    final dawn = _dragDawn ?? widget.dawn;
    final dusk = _dragDusk ?? widget.dusk;

    // Cheap: a scan over the day's cached elevations, so this can run on every
    // frame of a drag and show the time the angle actually produces.
    final elevs = SunMath.dayElevations(
        lat: widget.lat, lon: widget.lon, tzHours: widget.tz);
    final live = SunMath.crossings(elevs, dawn, dusk);
    final facts = SunMath.dayFacts(
        lat: widget.lat, lon: widget.lon, tzHours: widget.tz);

    // Shown as an offset, not a clock time. The clock time counts *down* in the
    // morning and *up* in the evening, so the two rows appeared to move in
    // opposite directions even though the setting was identical.
    final dawnOff = (live.$1 != null && facts.riseMin != null)
        ? live.$1! - facts.riseMin!
        : null;
    final duskOff = (live.$2 != null && facts.setMin != null)
        ? live.$2! - facts.setMin!
        : null;

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Twilight', style: TextStyle(fontSize: 14, color: c.title)),
          const SizedBox(height: 2),
          Text(
            'How far either side of sunrise and sunset the display keeps some '
            'light. Set separately — you are awake in the evening and asleep '
            'before dawn.',
            style: TextStyle(fontSize: 11, color: c.muted),
          ),
          const SizedBox(height: 8),
          _row(c, ctl, 'Brightens after sunrise', 'sunDawn', dawn,
              _SunTwilightCard._dawnMax, dawnOff, live.$1,
              (v) => setState(() => _dragDawn = v),
              () => setState(() => _dragDawn = null)),
          _row(c, ctl, 'Stays lit after sunset', 'sunDusk', dusk,
              _SunTwilightCard._duskMax, duskOff, live.$2,
              (v) => setState(() => _dragDusk = v),
              () => setState(() => _dragDusk = null)),
        ],
      ),
    );
  }

  Widget _row(
    ClockColors c,
    ClockController ctl,
    String label,
    String key,
    double value,
    double maxDeg,
    int? offset,
    int? when,
    ValueChanged<double> onDrag,
    VoidCallback onDone,
  ) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text(label, style: TextStyle(fontSize: 12, color: c.title)),
            const Spacer(),
            Text(offset == null ? '—' : '$offset min',
                style: TextStyle(fontSize: 12, color: c.accent)),
            const SizedBox(width: 8),
            Text(SunFacts.hhmm(when),
                style: TextStyle(fontSize: 11, color: c.muted)),
          ]),
          Slider(
            // Both rows run 0..1 of their own range, so dragging right always
            // means "more minutes", whichever direction the underlying angle
            // happens to go.
            value: (value / maxDeg).clamp(0.0, 1.0),
            onChanged: (x) => onDrag(x * maxDeg),
            onChangeEnd: (x) async {
              final deg = double.parse((x * maxDeg).toStringAsFixed(1));
              await ctl.patchConfig({key: deg});
              onDone();
            },
          ),
        ],
      );
}

/// Read-only here on purpose: location and timezone are one setting, and it
/// lives in Settings > Device because it decides what time the clock shows,
/// not just where the sun is. This card shows what's set and links there.
class _LocationCard extends StatelessWidget {
  const _LocationCard();

  @override
  Widget build(BuildContext context) {
    final ctl = context.watch<ClockController>();
    final c = Theme.of(context).extension<ClockColors>()!;
    final cfg = ctl.config;

    return GlassCard(
      child: Row(children: [
        Icon(Icons.place_outlined, size: 18, color: c.accent),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Sunrise and sunset are worked out for',
                  style: TextStyle(fontSize: 11, color: c.muted)),
              const SizedBox(height: 2),
              Text(
                ctl.current?.placeLabel ??
                    (cfg == null
                        ? '—'
                        : '${cfg.lat.toStringAsFixed(2)}, ${cfg.lon.toStringAsFixed(2)}'),
                style: TextStyle(fontSize: 14, color: c.title),
              ),
            ],
          ),
        ),
        TextButton(
          onPressed: () => showLocationSheet(context),
          child: const Text('Change'),
        ),
      ]),
    );
  }
}


/// How long the clock takes to ramp between day and night levels.
///
/// This replaced a "fade duration" slider that was bound straight to the saved
/// value with an empty onChanged, so the thumb couldn't follow your finger at
/// all. It also measures the right thing now: the ramp spreads across this
/// many minutes from each boundary, tied to the actual time of day.
class _TransitionRow extends StatefulWidget {
  final int minutes;
  const _TransitionRow({required this.minutes});

  @override
  State<_TransitionRow> createState() => _TransitionRowState();
}

class _TransitionRowState extends State<_TransitionRow> {
  int? _local;

  static String _fmt(int m) {
    if (m == 0) return 'Instant';
    if (m < 60) return '$m min';
    final h = m ~/ 60, r = m % 60;
    return r == 0 ? '${h}h' : '${h}h ${r}m';
  }

  @override
  Widget build(BuildContext context) {
    final ctl = context.read<ClockController>();
    final c = Theme.of(context).extension<ClockColors>()!;
    final v = _local ?? widget.minutes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(
              child: Text('Transition length',
                  style: TextStyle(fontSize: 13, color: c.title))),
          Text(_fmt(v), style: TextStyle(fontSize: 12, color: c.accent)),
        ]),
        Slider(
          value: v.toDouble().clamp(0, 120),
          max: 120,
          onChanged: (x) => setState(() => _local = x.round()),
          onChangeEnd: (x) async {
            await ctl.patchConfig({'transition': x.round()});
            if (mounted) setState(() => _local = null);
          },
        ),
        Text(
          v == 0
              ? 'Brightness switches the moment night starts and ends.'
              : 'Brightness eases over ${_fmt(v)} from each boundary, so it '
                  'follows the time of day instead of snapping.',
          style: TextStyle(fontSize: 11, color: c.muted),
        ),
      ],
    );
  }
}

class _PercentRow extends StatefulWidget {
  final String label;
  final int value;
  final String configKey;   // 'full' or 'night'

  /// Fired continuously while dragging, so the day strip can track the finger
  /// instead of only updating on release.
  final ValueChanged<int>? onPreview;

  const _PercentRow(
      {required this.label,
      required this.value,
      required this.configKey,
      this.onPreview});

  @override
  State<_PercentRow> createState() => _PercentRowState();
}

class _PercentRowState extends State<_PercentRow> {
  int? _local;

  void _emit(int v) {
    setState(() => _local = v);
    widget.onPreview?.call(v);
  }

  @override
  Widget build(BuildContext context) {
    // read, not watch — the 4s poll must not rebuild this mid-drag.
    final ctl = context.read<ClockController>();
    final c = Theme.of(context).extension<ClockColors>()!;
    final v = _local ?? widget.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(
              child: Text(widget.label,
                  style: TextStyle(fontSize: 13, color: c.title))),
          Text('$v%', style: TextStyle(fontSize: 12, color: c.accent)),
        ]),
        Slider(
          value: v.toDouble(),
          max: 100,
          // No `divisions`: it makes the thumb snap in 1% steps with a haptic
          // tick each step, which is what made this feel chopppy. Motion is
          // continuous; the value is still rounded to an int before sending.
          onChangeStart: (_) => ctl.beginBrightnessDrag(),
          onChanged: (x) {
            _emit(x.round());
            ctl.setBrightnessLive(x.round());   // preview on the real clock
          },
          onChangeEnd: (x) async {
            await ctl.endBrightnessDrag(x.round(), key: widget.configKey);
            if (!mounted) return;
            setState(() => _local = null);
            widget.onPreview?.call(-1);   // -1 = drag over, fall back to config
          },
        ),
      ],
    );
  }
}

class _HourRow extends StatelessWidget {
  final String label;
  final int hour;
  final ValueChanged<int> onChanged;
  const _HourRow(
      {required this.label, required this.hour, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<ClockColors>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Expanded(
            child: Text(label, style: TextStyle(fontSize: 13, color: c.title))),
        TextButton(
          // Deliberately an hour list, not showTimePicker: the firmware stores
          // whole hours, so a time picker would let you choose 11:30 PM and
          // then silently save 11:00 PM.
          onPressed: () async {
            final picked = await showDialog<int>(
              context: context,
              builder: (ctx) => SimpleDialog(
                title: Text(label),
                children: [
                  SizedBox(
                    height: 320,
                    width: 200,
                    child: ListView.builder(
                      itemCount: 24,
                      controller: ScrollController(
                        initialScrollOffset: (hour * 48.0 - 120).clamp(0, 24 * 48.0),
                      ),
                      itemBuilder: (_, h) => ListTile(
                        dense: true,
                        selected: h == hour,
                        title: Text(TimeOfDay(hour: h, minute: 0).format(ctx)),
                        onTap: () => Navigator.pop(ctx, h),
                      ),
                    ),
                  ),
                ],
              ),
            );
            if (picked != null) onChanged(picked);
          },
          child: Text(TimeOfDay(hour: hour, minute: 0).format(context)),
        ),
      ]),
    );
  }
}
