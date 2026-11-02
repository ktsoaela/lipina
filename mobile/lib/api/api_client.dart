import 'dart:async';

import 'package:dio/dio.dart';

import '../services/offline_store.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

/// Thin Dio wrapper: JWT auth with transparent refresh, and offline fallback for GETs
/// (network-first, falling back to the last cached response).
class ApiClient {
  ApiClient(this.store) {
    dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
    ));
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        options.baseUrl = store.serverUrl;
        final token = store.accessToken;
        if (token != null && options.extra['noAuth'] != true) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(options);
      },
      onError: (err, handler) async {
        final req = err.requestOptions;
        if (err.response?.statusCode == 401 && req.extra['retried'] != true && store.refreshToken != null) {
          if (await _refresh()) {
            req.extra['retried'] = true;
            req.headers['Authorization'] = 'Bearer ${store.accessToken}';
            try {
              return handler.resolve(await dio.fetch(req));
            } on DioException catch (e) {
              return handler.next(e);
            }
          }
          onSessionExpired?.call();
        }
        handler.next(err);
      },
    ));
  }

  final OfflineStore store;
  late final Dio dio;
  void Function()? onSessionExpired;
  Completer<bool>? _refreshing;

  Future<bool> _refresh() async {
    if (_refreshing != null) return _refreshing!.future;
    final completer = _refreshing = Completer<bool>();
    try {
      final res = await Dio(BaseOptions(baseUrl: store.serverUrl))
          .post('/api/auth/token/refresh/', data: {'refresh': store.refreshToken});
      await store.saveTokens(res.data['access'] as String, (res.data['refresh'] ?? store.refreshToken) as String?);
      completer.complete(true);
    } catch (_) {
      await store.saveTokens(null, null);
      completer.complete(false);
    } finally {
      _refreshing = null;
    }
    return completer.future;
  }

  static bool isOfflineError(Object e) =>
      e is DioException &&
      (e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.unknown);

  ApiException _wrap(DioException e) {
    final data = e.response?.data;
    String msg = 'Something went wrong';
    if (isOfflineError(e)) {
      msg = "You're offline";
    } else if (data is Map && data['detail'] != null) {
      msg = '${data['detail']}';
    } else if (data is Map && data.isNotEmpty) {
      final first = data.values.first;
      msg = first is List && first.isNotEmpty ? '${first.first}' : '$first';
    }
    return ApiException(msg, statusCode: e.response?.statusCode);
  }

  /// GET with offline cache. Set [cache] false for volatile endpoints.
  Future<dynamic> get(String path, {Map<String, dynamic>? query, bool cache = true}) async {
    final key = '$path?${query ?? {}}';
    try {
      final res = await dio.get(path, queryParameters: query);
      if (cache) store.putCache(key, res.data);
      return res.data;
    } on DioException catch (e) {
      if (cache && isOfflineError(e)) {
        final cached = store.getCache(key);
        if (cached != null) return cached;
      }
      throw _wrap(e);
    }
  }

  /// Unwraps DRF limit/offset pagination into a list.
  Future<List<Map<String, dynamic>>> getList(String path, {Map<String, dynamic>? query, bool cache = true}) async {
    final data = await get(path, query: query, cache: cache);
    final list = data is Map ? (data['results'] as List? ?? []) : (data as List? ?? []);
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<dynamic> post(String path, [dynamic body, Map<String, dynamic>? extra]) =>
      _send(() => dio.post(path, data: body, options: Options(extra: extra)));
  Future<dynamic> put(String path, [dynamic body]) => _send(() => dio.put(path, data: body));
  Future<dynamic> patch(String path, [dynamic body]) => _send(() => dio.patch(path, data: body));
  Future<dynamic> delete(String path) => _send(() => dio.delete(path));

  Future<dynamic> _send(Future<Response> Function() call) async {
    try {
      return (await call()).data;
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  Future<dynamic> upload(String path, String filePath, {String field = 'file', Map<String, dynamic>? fields,
      void Function(int, int)? onProgress}) async {
    final form = FormData.fromMap({...?fields, field: await MultipartFile.fromFile(filePath)});
    try {
      final res = await dio.post(path, data: form, onSendProgress: onProgress,
          options: Options(receiveTimeout: const Duration(minutes: 5), sendTimeout: const Duration(minutes: 10)));
      return res.data;
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  /// Replays queued writes (play history, podcast progress) once back online.
  Future<void> flushOutbox() async {
    for (final key in store.outbox.keys.toList()) {
      final item = Map<String, dynamic>.from(store.outbox.get(key) as Map);
      try {
        await dio.post(item['path'] as String, data: item['body']);
        await store.outbox.delete(key);
      } on DioException catch (e) {
        if (isOfflineError(e)) return; // still offline, try later
        await store.outbox.delete(key); // permanent failure (4xx): drop
      }
    }
  }
}
