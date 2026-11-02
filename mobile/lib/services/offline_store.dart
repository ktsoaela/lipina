import 'dart:convert';
import 'dart:math';

import 'package:hive_flutter/hive_flutter.dart';

/// Local persistence (Hive): settings, API response cache, downloads index,
/// device music index and the outbox of play events recorded while offline.
class OfflineStore {
  OfflineStore._(this.settings, this.cache, this.downloads, this.outbox, this.device);

  static late OfflineStore instance;

  final Box settings;
  final Box<String> cache;
  final Box downloads; // key -> PlayableItem json (with localPath)
  final Box outbox; // pending play events / progress updates
  final Box device; // key -> PlayableItem json for on-device files

  static Future<void> init() async {
    await Hive.initFlutter('lipina');
    instance = OfflineStore._(
      await Hive.openBox('settings'),
      await Hive.openBox<String>('api_cache'),
      await Hive.openBox('downloads'),
      await Hive.openBox('outbox'),
      await Hive.openBox('device_music'),
    );
  }

  String get serverUrl =>
      settings.get('server_url', defaultValue: const String.fromEnvironment('LIPINA_API', defaultValue: 'http://10.0.2.2:8000')) as String;
  set serverUrl(String v) => settings.put('server_url', v.replaceAll(RegExp(r'/+$'), ''));

  String? get accessToken => settings.get('access') as String?;
  String? get refreshToken => settings.get('refresh') as String?;
  Future<void> saveTokens(String? access, String? refresh) async {
    if (access == null) {
      await settings.delete('access');
    } else {
      await settings.put('access', access);
    }
    if (refresh == null) {
      await settings.delete('refresh');
    } else {
      await settings.put('refresh', refresh);
    }
  }

  void putCache(String key, dynamic data) => cache.put(key, jsonEncode(data));
  dynamic getCache(String key) {
    final raw = cache.get(key);
    return raw == null ? null : jsonDecode(raw);
  }

  /// Queue an API write for later (idempotent via client_id on the server).
  Future<void> enqueue(String path, Map<String, dynamic> body) async {
    final id = '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 30)}';
    await outbox.put(id, {'path': path, 'body': {...body, 'client_id': id}});
  }
}
