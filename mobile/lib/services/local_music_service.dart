import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import 'offline_store.dart';

/// Music files imported from the device (works with no account and no network).
class LocalMusicService extends ChangeNotifier {
  LocalMusicService(this.store);

  final OfflineStore store;
  final Map<String, double> uploads = {};

  List<PlayableItem> get items => store.device.values
      .map((e) => PlayableItem.fromJson(Map<String, dynamic>.from(e as Map)))
      .where((i) => i.localPath != null && File(i.localPath!).existsSync())
      .toList()
    ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));

  static (String title, String artist) _guess(String filename) {
    var stem = p.basenameWithoutExtension(filename).replaceAll('_', ' ');
    stem = stem.replaceFirst(RegExp(r'^\d+[\s._-]+'), '').trim();
    final i = stem.indexOf(' - ');
    return i > 0 ? (stem.substring(i + 3).trim(), stem.substring(0, i).trim()) : (stem, 'On this device');
  }

  /// Pick audio files and copy them into app storage so they survive cache clears.
  Future<int> importFiles() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.audio, allowMultiple: true);
    if (result == null) return 0;
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'device'));
    await dir.create(recursive: true);
    var added = 0;
    for (final f in result.files) {
      if (f.path == null) continue;
      final key = 'device:${f.name.hashCode}-${f.size}';
      if (store.device.containsKey(key)) continue;
      final target = p.join(dir.path, '${key.replaceAll(':', '_')}${p.extension(f.name)}');
      await File(f.path!).copy(target);
      final (title, artist) = _guess(f.name);
      final item = PlayableItem(
        key: key,
        kind: MediaKind.device,
        title: title,
        subtitle: artist,
        url: Uri.file(target).toString(),
        localPath: target,
        extra: {'filename': f.name},
      );
      await store.device.put(key, item.toJson());
      added++;
    }
    notifyListeners();
    return added;
  }

  Future<void> remove(PlayableItem item) async {
    final path = item.localPath;
    if (path != null && File(path).existsSync()) await File(path).delete();
    await store.device.delete(item.key);
    notifyListeners();
  }

  /// Push a device file to the user's cloud library so it syncs to the web app.
  Future<void> uploadToCloud(ApiClient api, PlayableItem item) async {
    uploads[item.key] = 0;
    notifyListeners();
    try {
      await api.upload('/api/tracks/', item.localPath!, onProgress: (sent, total) {
        if (total > 0) {
          uploads[item.key] = sent / total;
          notifyListeners();
        }
      });
    } finally {
      uploads.remove(item.key);
      notifyListeners();
    }
  }
}
