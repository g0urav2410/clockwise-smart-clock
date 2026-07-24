import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Thin typed wrapper over the clock's local HTTP/JSON API.
///
/// Every call targets `http://<host>/api/...` where host is either the mDNS
/// name (`clockwise-a1b2c3.local`) or a raw IP. If the clock has a PIN set, it
/// goes out as the `X-Auth-Token` header (see `apiAuthOK()` in the firmware).
class ClockApi {
  /// One shared client for the whole app, so connections are reused.
  ///
  /// The top-level `http.post`/`http.get` helpers open and tear down a TCP
  /// connection per call. The ESP8266 serves one connection at a time and is
  /// slow to handshake, so a fresh connection per slider update was a large
  /// part of why dragging felt laggy.
  static final http.Client _client = http.Client();

  final String host;
  final String? pin;
  final Duration timeout;

  ClockApi(this.host, {this.pin, this.timeout = const Duration(seconds: 4)});

  Uri _u(String path) => Uri.parse('http://$host$path');

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    if (pin != null && pin!.isNotEmpty) 'X-Auth-Token': pin!,
  };

  Future<Map<String, dynamic>> _get(String path) async {
    final r = await _client.get(_u(path), headers: _headers).timeout(timeout);
    return _decode(r);
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body,
      {Duration? timeoutOverride}) async {
    final r = await _client
        .post(_u(path), headers: _headers, body: jsonEncode(body))
        .timeout(timeoutOverride ?? timeout);
    return _decode(r);
  }

  Map<String, dynamic> _decode(http.Response r) {
    if (r.statusCode == 401) throw ClockAuthException();
    if (r.statusCode >= 400) {
      throw ClockApiException('HTTP ${r.statusCode}: ${r.body}');
    }
    final v = jsonDecode(r.body);
    if (v is! Map<String, dynamic>) throw ClockApiException('unexpected response');
    return v;
  }

  /// Unauthenticated — used to probe whether a host is a Clockwise clock at all.
  Future<ClockInfo> info() async => ClockInfo.fromJson(await _get('/api/info'));

  Future<ClockStateData> state() async =>
      ClockStateData.fromJson(await _get('/api/state'));

  Future<ClockConfig> config() async =>
      ClockConfig.fromJson(await _get('/api/config'));

  /// Partial update — only the keys you pass are changed on the device.
  Future<void> setConfig(Map<String, dynamic> patch) => _post('/api/config', patch);

  /// Live brightness while dragging — applies immediately on the device and is
  /// deliberately *not* persisted. Persist the final value with [setConfig].
  Future<void> setBrightnessLive(int pct) =>
      _post('/api/brightness', {'v': pct});

  Future<void> setName(String name) => _post('/api/name', {'name': name});

  Future<void> command(String cmd) => _post('/api/cmd', {'cmd': cmd});

  Future<void> sync() => command('sync');
  Future<void> reboot() => command('reboot');

  // ── HLK-LD2402 presence radar ──
  Future<SensorState> sensorState() async =>
      SensorState.fromJson(await _get('/api/sensor'));

  Future<SensorConfig> sensorConfig() async =>
      SensorConfig.fromJson(await _get('/api/sensor/config'));

  /// Only the keys you pass are changed. `save: true` also commits to the
  /// sensor's own flash (separate from applying it live).
  Future<void> setSensorConfig(Map<String, dynamic> patch, {bool save = false}) =>
      _post('/api/sensor/config', {...patch, if (save) 'save': true});

  /// The 16 per-gate motion + micro thresholds, on demand (32 round-trips on
  /// the clock's side, so it's a deliberate load, not part of the settings
  /// screen opening). A null entry means that gate didn't read back.
  Future<({List<double?> motion, List<double?> micro})> sensorThresholds() async {
    final j = await _get('/api/sensor/thresholds');
    List<double?> parse(String k) => ((j[k] as List?) ?? [])
        .map((v) => v == null ? null : (v as num).toDouble())
        .toList();
    return (motion: parse('motionThresholdDb'), micro: parse('microThresholdDb'));
  }

  /// Writes one gate's threshold(s) without touching any other gate — unlike
  /// [setSensorConfig]'s array form, which writes positionally from index 0
  /// and would zero out earlier gates if you sent a short array just to
  /// change one. `save: true` also commits to the sensor's own flash.
  Future<void> setSensorGate(int gate, {double? motionDb, double? microDb, bool save = false}) =>
      _post('/api/sensor/gate', {
        'gate': gate,
        if (motionDb != null) 'motionThresholdDb': motionDb,
        if (microDb != null) 'microThresholdDb': microDb,
        if (save) 'save': true,
      });

  /// Blocks for the whole calibration run (up to ~120s on the clock's side --
  /// the sensor's own datasheet gives no fixed duration for threshold
  /// generation, it depends on the room, so the firmware doesn't cut it off
  /// early -- plus enter/exit-config-mode overhead). The default 4s client
  /// timeout used everywhere else would abort this long before the clock is
  /// done, which looked like a sensor error but was really just the app
  /// giving up too early.
  Future<Map<String, dynamic>> calibrateSensor({int trigger = 3, int hold = 3, int micro = 3}) =>
      _post('/api/sensor/calibrate', {'trigger': trigger, 'hold': hold, 'micro': micro},
          timeoutOverride: const Duration(seconds: 125));

  /// Same story as calibrateSensor -- worst case ~11.5s on the clock's side.
  Future<Map<String, dynamic>> autoGainSensor() =>
      _post('/api/sensor/autogain', {}, timeoutOverride: const Duration(seconds: 15));

  /// Recent notable events (NTP sync, calibration, radar recovery, boot) from
  /// the clock's small in-RAM log -- a stand-in for a serial monitor when
  /// there's no USB plugged in. Oldest first; lost on reboot.
  Future<List<String>> deviceLog() async {
    final j = await _get('/api/log');
    return ((j['log'] as List?) ?? []).map((e) => e.toString()).toList();
  }

  /// Runs one debug-console command (the same set the physical USB console
  /// takes) and returns its result text. See DeviceLogScreen for the command
  /// reference and which ones need confirmation before sending.
  Future<String> sendDebugCmd(String cmd) async {
    final j = await _post('/api/debugcmd', {'cmd': cmd});
    return (j['output'] ?? '').toString();
  }
}

/// `/api/sensor` — live readings, cheap to poll.
class SensorState {
  final bool connected, presence, moving, still, engineering;
  final int distanceCm;
  final List<double> motionEnergyDb, microEnergyDb;

  SensorState({
    required this.connected,
    required this.presence,
    required this.moving,
    required this.still,
    required this.engineering,
    required this.distanceCm,
    this.motionEnergyDb = const [],
    this.microEnergyDb = const [],
  });

  factory SensorState.fromJson(Map<String, dynamic> j) => SensorState(
        connected: j['connected'] == true,
        presence: j['presence'] == true,
        moving: j['moving'] == true,
        still: j['still'] == true,
        engineering: j['engineering'] == true,
        distanceCm: (j['distanceCm'] ?? 0) as int,
        motionEnergyDb: ((j['motionEnergyDb'] as List?) ?? [])
            .map((v) => (v as num).toDouble())
            .toList(),
        microEnergyDb: ((j['microEnergyDb'] as List?) ?? [])
            .map((v) => (v as num).toDouble())
            .toList(),
      );
}

/// `/api/sensor/config` — lives mostly on the sensor's own flash, read
/// through the clock. Slow-ish to fetch (~35 small serial round-trips on the
/// clock's side); only load this when a settings screen actually opens.
class SensorConfig {
  final String? firmware, serial;
  final double maxDistanceM;
  final int disappearDelaySec;
  final int powerInterference; // 0 not run, 1 clear, 2 interference
  final bool engineering;
  final List<double> motionThresholdDb, microThresholdDb;

  SensorConfig({
    this.firmware,
    this.serial,
    required this.maxDistanceM,
    required this.disappearDelaySec,
    required this.powerInterference,
    required this.engineering,
    this.motionThresholdDb = const [],
    this.microThresholdDb = const [],
  });

  factory SensorConfig.fromJson(Map<String, dynamic> j) => SensorConfig(
        firmware: j['firmware'] as String?,
        serial: j['serial'] as String?,
        maxDistanceM: ((j['maxDistanceM'] ?? 5.0) as num).toDouble(),
        disappearDelaySec: (j['disappearDelaySec'] ?? 5) as int,
        powerInterference: (j['powerInterference'] ?? 0) as int,
        engineering: j['engineering'] == true,
        motionThresholdDb: ((j['motionThresholdDb'] as List?) ?? [])
            .map((v) => (v as num).toDouble())
            .toList(),
        microThresholdDb: ((j['microThresholdDb'] as List?) ?? [])
            .map((v) => (v as num).toDouble())
            .toList(),
      );
}

class ClockApiException implements Exception {
  final String message;
  ClockApiException(this.message);
  @override String toString() => message;
}

class ClockAuthException extends ClockApiException {
  ClockAuthException() : super('Wrong or missing PIN');
}

/// `/api/info` — identity, reachable without a PIN.
class ClockInfo {
  final String name, fw, ip, chipId;
  final bool authRequired;

  /// Static device-health facts (don't change while running) — null on
  /// firmware predating them.
  final String? lastResetReason;
  final int? cpuFreqMHz, sketchSize, freeSketchSpace, flashChipSize;

  ClockInfo({
    required this.name,
    required this.fw,
    required this.ip,
    required this.chipId,
    required this.authRequired,
    this.lastResetReason,
    this.cpuFreqMHz,
    this.sketchSize,
    this.freeSketchSpace,
    this.flashChipSize,
  });

  factory ClockInfo.fromJson(Map<String, dynamic> j) => ClockInfo(
    name: j['name'] ?? 'Clockwise',
    fw: j['fw'] ?? '?',
    ip: j['ip'] ?? '',
    chipId: j['chipId'] ?? '',
    authRequired: j['authRequired'] == true,
    lastResetReason: j['lastResetReason'] as String?,
    cpuFreqMHz: (j['cpuFreqMHz'] as num?)?.toInt(),
    sketchSize: (j['sketchSize'] as num?)?.toInt(),
    freeSketchSpace: (j['freeSketchSpace'] as num?)?.toInt(),
    flashChipSize: (j['flashChipSize'] as num?)?.toInt(),
  );
}

/// `/api/state` — live values, polled while Home is foregrounded.
class ClockStateData {
  final int brightness, rssi, uptimeMinutes;
  final bool presence, mqttConnected;
  final String lastSync;

  /// The clock's own time, read off its RTC — deliberately not the phone's
  /// clock, so drift or a failed sync is actually visible. Null on firmware
  /// older than the change that added these fields, or if the RTC read failed.
  final String? time, date;
  final int? dow; // 0=Sun..6=Sat
  final bool rtcOk;

  /// Sun position the clock is reacting to in sun mode.
  final double? sunElev;
  final int? sunPct;

  /// The clock's own current UTC offset, DST already applied by the device.
  /// Null on firmware predating it — callers fall back to the saved zone.
  final double? tzOffsetHours;

  /// True while the presence overlay currently has brightness dimmed for an
  /// empty room -- null on firmware predating the feature.
  final bool? presenceDimActive;

  /// Rough device-health readout -- see MANUAL.md "The clock face on Home"
  /// for why there's no real "CPU load %" on this chip. Null on firmware
  /// predating them.
  final int? freeHeap, heapFragPct, loopHz;

  /// True while a debug command has put the display into manual/test mode --
  /// no auto-timeout on the clock's side, so this is how the app knows to
  /// warn/offer to resume rather than the display silently staying frozen.
  final bool? manualMode;

  ClockStateData({
    required this.brightness,
    required this.presence,
    required this.lastSync,
    required this.rssi,
    required this.uptimeMinutes,
    required this.mqttConnected,
    this.time,
    this.date,
    this.dow,
    this.rtcOk = false,
    this.sunElev,
    this.sunPct,
    this.tzOffsetHours,
    this.presenceDimActive,
    this.freeHeap,
    this.heapFragPct,
    this.loopHz,
    this.manualMode,
  });

  factory ClockStateData.fromJson(Map<String, dynamic> j) => ClockStateData(
    brightness: (j['brightness'] ?? 0) as int,
    presence: j['presence'] == true,
    lastSync: (j['lastSync'] ?? '').toString(),
    rssi: (j['rssi'] ?? 0) as int,
    uptimeMinutes: (j['uptime'] ?? 0) as int,
    mqttConnected: j['mqttConnected'] == true,
    time: j['time'] as String?,
    date: j['date'] as String?,
    dow: j['dow'] as int?,
    rtcOk: j['rtcOk'] == true,
    sunElev: (j['sunElev'] as num?)?.toDouble(),
    sunPct: (j['sunPct'] as num?)?.toInt(),
    tzOffsetHours: (j['tzOff'] as num?)?.toDouble(),
    presenceDimActive: j['presenceDimActive'] as bool?,
    freeHeap: (j['freeHeap'] as num?)?.toInt(),
    heapFragPct: (j['heapFragPct'] as num?)?.toInt(),
    loopHz: (j['loopHz'] as num?)?.toInt(),
    manualMode: j['manualMode'] as bool?,
  );

  static const _days = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday',
                        'Friday', 'Saturday'];

  String? get dayName =>
      (dow != null && dow! >= 0 && dow! < 7) ? _days[dow!] : null;

  /// "13:45:02" → "1:45 PM". Seconds are dropped; the clock face has no
  /// seconds display either.
  String? get prettyTime {
    final t = time;
    if (t == null) return null;
    final p = t.split(':');
    if (p.length < 2) return t;
    final h = int.tryParse(p[0]);
    if (h == null) return t;
    final h12 = h % 12 == 0 ? 12 : h % 12;
    return '$h12:${p[1]} ${h < 12 ? 'AM' : 'PM'}';
  }
}

/// `/api/config` — persisted settings (LittleFS `/cfg.json`).
class ClockConfig {
  final String name, mqttHost, mqttUser;
  final int mqttPort, full, dim, night, nightStart, nightEnd, timeout, fade;

  /// The day/night scheduler runs on the clock itself, so this is the device's
  /// state, not an app preference.
  final bool sched;
  final bool autoSync;
  final int oeFreq;
  final bool logo;
  final int transitionMin;
  final int gammaX100;
  final int mode;      // 0=manual 1=schedule 2=sun
  final double lat, lon;
  final double sunLow, sunHigh;

  /// Twilight floors, separately for each end of the day. `sunLow` is the old
  /// single-value form, still sent by the firmware as an alias for dusk.
  final double sunDawn, sunDusk;

  /// Sun mode keeps its own brightness pair, separate from the scheduler's
  /// full/night — editing one mode must not move the other.
  final int sunFull, sunNight;

  /// Manual mode's own level, likewise separate.
  final int manual;

  /// POSIX TZ rule (e.g. "IST-5:30", or "EST5EDT,M3.2.0,M11.1.0" for a
  /// DST-observing region). Set once via the city picker in Location;
  /// newlib on the clock resolves DST from this on every NTP resync, no
  /// ongoing app involvement needed. See ISSUES.md #5.
  final String tz;

  /// Presence dimming overlay -- works on top of whichever mode (manual,
  /// schedule, sun) is active. Off by default.
  final bool presenceDim;
  final int presenceAway, presenceTimeout;

  /// The one UART is either the radar's (false, default) or a USB debug
  /// console's (true) -- never both. Turning debug on pauses the sensor.
  final bool serialDebug;

  /// Optional scheduled restart, off by default -- resets heap fragmentation
  /// to 0 rather than trying to eliminate it. autoRebootDays is free-form
  /// (the UI offers day/week/month presets: 1/7/30).
  final bool autoReboot;
  final int autoRebootDays, autoRebootHour;

  ClockConfig({
    required this.name,
    required this.mqttHost,
    required this.mqttPort,
    required this.mqttUser,
    required this.full,
    required this.dim,
    required this.night,
    required this.nightStart,
    required this.nightEnd,
    required this.timeout,
    required this.fade,
    this.sched = false,
    this.autoSync = true,
    this.oeFreq = 20000,
    this.logo = true,
    this.transitionMin = 30,
    this.gammaX100 = 180,
    this.mode = 0,
    this.lat = 51.48,   // near Greenwich, replaced at setup
    this.lon = 0.0,
    this.sunLow = -6,
    this.sunHigh = 25,
    this.sunDawn = -6,
    this.sunDusk = -6,
    this.sunFull = 100,
    this.sunNight = 0,
    this.manual = 100,
    this.tz = 'IST-5:30',
    this.presenceDim = false,
    this.presenceAway = 0,
    this.presenceTimeout = 5,
    this.serialDebug = false,
    this.autoReboot = false,
    this.autoRebootDays = 7,
    this.autoRebootHour = 4,
  });

  factory ClockConfig.fromJson(Map<String, dynamic> j) => ClockConfig(
    name: j['name'] ?? 'Clockwise',
    mqttHost: j['mqttHost'] ?? '',
    mqttPort: (j['mqttPort'] ?? 1883) as int,
    mqttUser: j['mqttUser'] ?? '',
    full: (j['full'] ?? 100) as int,
    dim: (j['dim'] ?? 10) as int,
    night: (j['night'] ?? 0) as int,
    nightStart: (j['nightStart'] ?? 23) as int,
    nightEnd: (j['nightEnd'] ?? 6) as int,
    timeout: (j['timeout'] ?? 300) as int,
    fade: (j['fade'] ?? 1500) as int,
    sched: j['sched'] == true,
    transitionMin: (j['transition'] ?? 30) as int,
    gammaX100: (j['gamma'] ?? 180) as int,
    mode: (j['mode'] ?? 0) as int,
    lat: ((j['lat'] ?? 51.48) as num).toDouble(),
    lon: ((j['lon'] ?? 0.0) as num).toDouble(),
    sunLow: ((j['sunLow'] ?? -6) as num).toDouble(),
    sunHigh: ((j['sunHigh'] ?? 25) as num).toDouble(),
    // Fall back to the single legacy value, so a clock on older firmware still
    // shows the right thing on both ends.
    sunDawn: ((j['sunDawn'] ?? j['sunLow'] ?? -6) as num).toDouble(),
    sunDusk: ((j['sunDusk'] ?? j['sunLow'] ?? -6) as num).toDouble(),
    // Fall back to the shared pair so a clock on older firmware still shows
    // sensible numbers instead of 100/0.
    sunFull: (j['sunFull'] ?? j['full'] ?? 100) as int,
    sunNight: (j['sunNight'] ?? j['night'] ?? 0) as int,
    manual: (j['manual'] ?? j['full'] ?? 100) as int,
    autoSync: j['autoSync'] != false,
    oeFreq: (j['oeFreq'] ?? 20000) as int,
    logo: j['logo'] != false,
    tz: j['tz'] ?? 'IST-5:30',
    presenceDim: j['presenceDim'] == true,
    presenceAway: (j['presenceAway'] ?? 0) as int,
    presenceTimeout: (j['presenceTimeout'] ?? 5) as int,
    serialDebug: j['serialDebug'] == true,
    autoReboot: j['autoReboot'] == true,
    autoRebootDays: (j['autoRebootDays'] ?? 7) as int,
    autoRebootHour: (j['autoRebootHour'] ?? 4) as int,
  );
}
