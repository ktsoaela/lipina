import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../api/api_client.dart';
import '../models/models.dart';
import 'offline_store.dart';

/// Saves tracks and podcast episodes to app storage for offline listening.
class DownloadService extends ChangeNotifier {
  DownloadService(this.api, this.store);

  final ApiClient api;
  final OfflineStore store;
  final Map<String, double> progress = {}; // key -> 0..1 while downloading
  final Map<String, CancelToken> _tokens = {};

  bool isDownloaded(String key) => store.downloads.containsKey(key);
  bool isDownloading(String key) => progress.containsKey(key);

  String? localPathFor(String key) {
    final raw = store.downloads.get(key);
    if (raw == null) return null;
    final path = (raw as Map)['localPath'] as String?;
    return (path != null && File(path).existsSync()) ? path : null;
  }

  List<PlayableItem> get all => store.downloads.values
      .map((e) => PlayableItem.fromJson(Map<String, dynamic>.from(e as Map)))
      .where((i) => i.localPath != null && File(i.localPath!).existsSync())
      .toList()
      .reversed
      .toList();

  int get totalBytes => all.fold(0, (sum, i) => sum + File(i.localPath!).lengthSync());

  static String _ext(PlayableItem item) {
    final mime = item.extra['mime'] as String? ?? '';
    if (mime.contains('mp4') || mime.contains('m4a') || mime.contains('aac')) return '.m4a';
    if (mime.contains('flac')) return '.flac';
    if (mime.contains('ogg')) return '.ogg';
    if (mime.contains('wav')) return '.wav';
    final fromUrl = p.extension(Uri.tryParse(item.url)?.path ?? '');
    return fromUrl.isNotEmpty && fromUrl.length <= 5 ? fromUrl : '.mp3';
  }

  Future<void> download(PlayableItem item) async {
    if (item.isLive || isDownloaded(item.key) || isDownloading(item.key)) return;
    final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'downloads'));
    await dir.create(recursive: true);
    final target = p.join(dir.path, '${item.key.replaceAll(':', '_')}${_ext(item)}');
    final tmp = '$target.part';
    final url = item.extra['download_url'] as String? ?? item.url;
    final token = _tokens[item.key] = CancelToken();
    progress[item.key] = 0;
    notifyListeners();
    try {
      // Library streams carry their own signed token; podcast URLs are public.
      await Dio().download(url, tmp, cancelToken: token, onReceiveProgress: (got, total) {
        if (total > 0) {
          progress[item.key] = got / total;
          notifyListeners();
        }
      });
      await File(tmp).rename(target);
      await store.downloads.put(item.key, (item.toJson()..['localPath'] = target));
    } catch (e) {
      final f = File(tmp);
      if (f.existsSync()) await f.delete();
      if (e is! DioException || e.type != DioExceptionType.cancel) rethrow;
    } finally {
      progress.remove(item.key);
      _tokens.remove(item.key);
      notifyListeners();
    }
  }

  Future<void> downloadAll(Iterable<PlayableItem> items) async {
    for (final item in items) {
      try {
        await download(item);
      } catch (_) {
        continue; // keep going; one bad file shouldn't stop a playlist download
      }
    }
  }

  void cancel(String key) => _tokens[key]?.cancel();

  Future<void> remove(String key) async {
    final path = localPathFor(key);
    if (path != null) await File(path).delete();
    await store.downloads.delete(key);
    notifyListeners();
  }

  Future<void> clear() async {
    for (final key in store.downloads.keys.toList()) {
      await remove(key as String);
    }
  }
}
