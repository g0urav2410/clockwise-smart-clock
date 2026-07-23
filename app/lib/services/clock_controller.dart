import 'dart:async';
import 'package:flutter/foundation.dart';
import 'clock_api.dart';
import 'device_store.dart';
import 'phone_location.dart';

enum ConnStatus { idle, searching, connected, unreachable, unauthorized }

/// The app's single source of truth: which clock is selected, its live state,
/// and its config. Talks to the clock's local HTTP API — no MQTT broker needed.
class ClockController extends ChangeNotifier {
  List<SavedDevice> devices = [];
  SavedDevice? current;

  ConnStatus status = ConnStatus.idle;
  ClockInfo? info;
  ClockStateData? state;
  ClockConfig? config;
  String? lastError;

  Timer? _poll;
  bool _foreground = true;

  /// The ESP8266's web server handles exactly one connection at a time. If the
  /// 4s poll lands while a config write is in flight, the loser is refused at
  /// the TCP level — before any handler runs, so nothing appears in the serial
  /// log and the app just says "can't reach the clock". Every request goes
  /// through here so that can't happen.
  Future<void> _queue = Future.value();

  Future<T> _serialized<T>(Future<T> Function() op) {
    final completer = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await op());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  ClockApi? get _api =>
      current == null ? null : ClockApi(current!.host, pin: current!.pin);

  bool get hasDevice => current != null;
  bool get isConnected => status == ConnStatus.connected;

  /// Called once at startup: restore the saved device list and connect.
  Future<void> init() async {
    devices = await DeviceStore.load();
    final selected = await DeviceStore.selectedChipId();
    current = devices.isEmpty
        ? null
        : devices.firstWhere((d) => d.chipId == selected, orElse: () => devices.first);
    notifyListeners();
    if (current != null) await refresh();
    _startPolling();
  }

  Future<void> selectDevice(String chipId) async {
    final match = devices.where((d) => d.chipId == chipId);
    if (match.isEmpty) return;
    current = match.first;
    await DeviceStore.select(chipId);
    state = null;
    config = null;
    status = ConnStatus.searching;
    notifyListeners();
    await refresh();
  }

  Future<void> addDevice(SavedDevice d) async {
    devices = await DeviceStore.upsert(d);
    await DeviceStore.select(d.chipId);
    current = d;
    notifyListeners();
    await refresh();
  }

  Future<void> removeDevice(String chipId) async {
    devices = await DeviceStore.remove(chipId);
    if (current?.chipId == chipId) {
      current = devices.isEmpty ? null : devices.first;
      state = null;
      config = null;
      status = ConnStatus.idle;
      if (current != null) {
        await DeviceStore.select(current!.chipId);
        await refresh();
      }
    }
    notifyListeners();
  }

  /// Updates the connection details of the current device (host or PIN).
  Future<void> updateCurrent({String? host, String? pin}) async {
    if (current == null) return;
    if (host != null) current!.host = host;
    if (pin != null) current!.pin = pin;
    devices = await DeviceStore.upsert(current!);
    notifyListeners();
    await refresh();
  }

  /// Full refresh: identity + live state + config.
  Future<void> refresh() async {
    final api = _api;
    if (api == null) return;
    if (status != ConnStatus.connected) {
      status = ConnStatus.searching;
      notifyListeners();
    }
    try {
      info = await _serialized(api.info);
      state = await _serialized(api.state);
      config = await _serialized(api.config);
      _consecutiveFailures = 0;
      status = ConnStatus.connected;
      lastError = null;
      // Keep the saved name in step with whatever the device reports.
      if (current!.name != info!.name) {
        current!.name = info!.name;
        devices = await DeviceStore.upsert(current!);
      }
    } on ClockAuthException {
      status = ConnStatus.unauthorized;
      lastError = 'This clock needs a PIN';
    } catch (e) {
      status = ConnStatus.unreachable;
      lastError = e.toString();
    }
    notifyListeners();
  }

  /// Sets where the clock is: coordinates for sunrise/sunset, and a POSIX rule
  /// the device applies itself (daylight saving included) on every NTP sync.
  ///
  /// [zone] and [label] are kept app-side so the UI never has to guess the
  /// place back from coordinates — see SavedDevice.tzZone.
  Future<bool> setLocation({
    required double lat,
    required double lon,
    required String tzPosix,
    required String zone,
    required String label,
  }) async {
    final ok = await patchConfig({'lat': lat, 'lon': lon, 'tz': tzPosix});
    if (!ok || current == null) return ok;
    current!.tzZone = zone;
    current!.placeLabel = label;
    devices = await DeviceStore.upsert(current!);
    notifyListeners();
    return true;
  }

  /// The clock's own wall time, off its RTC.
  ///
  /// The sun curve has to be drawn against this, not the phone's clock: the
  /// two are in different timezones whenever the device is set somewhere else,
  /// and using the phone's put the "now" marker hours from where the clock
  /// actually was — the curve said midday while the display had correctly
  /// dimmed for night. Null until the first poll, or if the RTC is unreadable.
  DateTime? get clockNow {
    final s = state;
    if (s == null || !s.rtcOk) return null;
    final d = s.date, t = s.time;
    if (d == null || t == null) return null;
    return DateTime.tryParse('$d $t');
  }

  /// Hours east of UTC that the clock is running on, daylight saving included —
  /// what the app's own sun-curve preview draws with, so it matches the device.
  ///
  /// The device's own report wins: it comes from the POSIX rule the clock is
  /// actually using, so it stays right even on a fresh install or a second
  /// phone that never saved a zone. The saved zone is the fallback for firmware
  /// too old to report it, and the phone's own offset only as a last resort.
  double get previewTzHours {
    final reported = state?.tzOffsetHours;
    if (reported != null) return reported;
    final phone = DateTime.now().timeZoneOffset.inMinutes / 60.0;
    final zone = current?.tzZone;
    if (zone == null) return phone;
    return PhoneLocationService.offsetHoursFor(zone, fallback: phone);
  }

  /// Whether [previewTzHours] reflects the clock's timezone rather than a
  /// guess from this phone. Drift can only be judged when it does.
  bool get knowsClockTz =>
      state?.tzOffsetHours != null || current?.tzZone != null;

  // ── live brightness dragging ──

  bool _dragging = false;
  int? _pendingBrightness;
  bool _sendingBrightness = false;

  /// Brightness the UI should show — the in-flight drag value if the user is
  /// currently dragging, otherwise whatever the device last reported. Without
  /// this the slider snaps back to a stale poll value mid-drag.
  int? get liveBrightness => _pendingBrightness;

  void beginBrightnessDrag() => _dragging = true;

  /// Called continuously while dragging. Coalesces: only one request is ever
  /// in flight, and the newest value wins — so a fast drag doesn't queue up a
  /// backlog of stale requests the LEDs would have to chase through.
  ///
  /// Deliberately does NOT notifyListeners: the slider already tracks the
  /// finger from its own local state, and notifying here rebuilt every card on
  /// the screen dozens of times a second for no visible benefit.
  void setBrightnessLive(int pct) {
    _pendingBrightness = pct;
    _flushBrightness();
  }

  Future<void> _flushBrightness() async {
    if (_sendingBrightness || _api == null) return;
    _sendingBrightness = true;
    try {
      while (_pendingBrightness != null) {
        final v = _pendingBrightness!;
        await _serialized(() => _api!.setBrightnessLive(v));
        // Anything newer arrived while that was in flight? Send that instead.
        if (_pendingBrightness == v) break;
      }
    } catch (_) {
      // A dropped live update doesn't matter; the next one supersedes it, and
      // the value is persisted on release anyway.
    } finally {
      _sendingBrightness = false;
    }
  }

  /// Drag finished — persist the final value under [key] ('full' or 'night'),
  /// then let polling take over again.
  Future<void> endBrightnessDrag(int pct, {String key = 'full'}) async {
    _pendingBrightness = pct;
    await _flushBrightness();
    await patchConfig({key: pct});
    _dragging = false;
    _pendingBrightness = null;
    notifyListeners();
  }

  /// Consecutive failed polls. A single dropped packet on WiFi is normal and
  /// shouldn't throw a scary banner up; only a sustained run means the clock is
  /// genuinely gone.
  int _consecutiveFailures = 0;
  static const _failuresBeforeUnreachable = 3;

  /// Cheap poll — live state only, no config re-fetch.
  Future<void> _pollState() async {
    final api = _api;
    if (api == null || !_foreground) return;
    if (_dragging) return;   // don't fight the user's finger
    try {
      state = await _serialized(api.state);
      _consecutiveFailures = 0;
      if (status != ConnStatus.connected) {
        status = ConnStatus.connected;
        lastError = null;
      }
      notifyListeners();
    } on ClockAuthException {
      status = ConnStatus.unauthorized;
      notifyListeners();
    } catch (e) {
      _consecutiveFailures++;
      // Always record it. This used to be swallowed, which is why a failure
      // left nothing to look at anywhere.
      lastError = '$e';
      debugPrint('poll failed (${_consecutiveFailures}x): $e');
      if (_consecutiveFailures >= _failuresBeforeUnreachable &&
          status == ConnStatus.connected) {
        status = ConnStatus.unreachable;
        notifyListeners();
      }
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _pollState());
  }

  /// Wired to app lifecycle so a backgrounded app stops hitting the clock.
  /// Coming back does a *full* refresh, not just state: the config may have
  /// been changed from Home Assistant, the serial console, or another phone
  /// while we weren't looking.
  void setForeground(bool v) {
    _foreground = v;
    if (v) refresh();
  }

  // ── writes ──

  Future<bool> patchConfig(Map<String, dynamic> patch) => _guard(() async {
    await _serialized(() => _api!.setConfig(patch));
    config = await _serialized(_api!.config);
    state = await _serialized(_api!.state);
  });

  Future<bool> rename(String name) => _guard(() async {
    await _serialized(() => _api!.setName(name));
    current!.name = name;
    devices = await DeviceStore.upsert(current!);
    info = await _serialized(_api!.info);
  });

  Future<bool> syncTime() => _guard(() async {
    await _serialized(_api!.sync);
    state = await _serialized(_api!.state);
  });

  Future<bool> reboot() => _guard(() async {
    await _serialized(_api!.reboot);
    status = ConnStatus.searching;
  });

  /// Runs a write, mapping failures onto [lastError]/[status] instead of throwing.
  Future<bool> _guard(Future<void> Function() action) async {
    if (_api == null) return false;
    try {
      await action();
      lastError = null;
      notifyListeners();
      return true;
    } on ClockAuthException {
      status = ConnStatus.unauthorized;
      lastError = 'This clock needs a PIN';
      notifyListeners();
      return false;
    } catch (e) {
      lastError = e.toString();
      notifyListeners();
      return false;
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }
}
