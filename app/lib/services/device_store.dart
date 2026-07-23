import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// A clock the user has added. `host` is what we actually connect to — either
/// `clockwise-xxxx.local` or a raw IP if mDNS isn't resolving on their network.
class SavedDevice {
  final String chipId;
  String name;
  String host;
  String? pin;

  /// What the user actually chose for this clock's location: the IANA zone
  /// ("Asia/Kolkata") and a readable label ("Jammu and Kashmir, India").
  ///
  /// Remembered rather than re-derived from the coordinates, because
  /// re-deriving is wrong: the nearest zone anchor to Jammu is Kabul, so the
  /// clock got labelled Afghanistan and its sun curve drawn an hour out. The
  /// clock itself only stores a POSIX rule, which can't be mapped back to a
  /// zone name, so the app has to keep this. Null for a clock set up
  /// elsewhere — fall back to nearest-region then.
  String? tzZone;
  String? placeLabel;

  SavedDevice({
    required this.chipId,
    required this.name,
    required this.host,
    this.pin,
    this.tzZone,
    this.placeLabel,
  });

  Map<String, dynamic> toJson() => {
    'chipId': chipId,
    'name': name,
    'host': host,
    'pin': pin,
    'tzZone': tzZone,
    'placeLabel': placeLabel,
  };

  factory SavedDevice.fromJson(Map<String, dynamic> j) => SavedDevice(
    chipId: j['chipId'] ?? '',
    name: j['name'] ?? 'Clockwise',
    host: j['host'] ?? '',
    pin: j['pin'],
    tzZone: j['tzZone'],
    placeLabel: j['placeLabel'],
  );
}

/// Persists the device list + which one is selected. Devices are keyed by
/// chipId so a DHCP address change doesn't create a duplicate entry.
class DeviceStore {
  static const _kDevices = 'devices';
  static const _kSelected = 'selected_chip';

  static Future<List<SavedDevice>> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getStringList(_kDevices) ?? [];
    return raw
        .map((s) => SavedDevice.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  static Future<void> save(List<SavedDevice> devices) async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(
      _kDevices,
      devices.map((d) => jsonEncode(d.toJson())).toList(),
    );
  }

  /// Adds, or updates the existing entry with the same chipId.
  static Future<List<SavedDevice>> upsert(SavedDevice d) async {
    final list = await load();
    final i = list.indexWhere((e) => e.chipId == d.chipId);
    if (i >= 0) {
      list[i] = d;
    } else {
      list.add(d);
    }
    await save(list);
    return list;
  }

  static Future<List<SavedDevice>> remove(String chipId) async {
    final list = await load();
    list.removeWhere((e) => e.chipId == chipId);
    await save(list);
    return list;
  }

  static Future<String?> selectedChipId() async =>
      (await SharedPreferences.getInstance()).getString(_kSelected);

  static Future<void> select(String chipId) async =>
      (await SharedPreferences.getInstance()).setString(_kSelected, chipId);
}
