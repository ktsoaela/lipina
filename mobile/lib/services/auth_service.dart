import 'package:flutter/foundation.dart';

import '../api/api_client.dart';
import 'offline_store.dart';

class AuthService extends ChangeNotifier {
  AuthService(this.api, this.store) {
    api.onSessionExpired = () {
      user = null;
      notifyListeners();
    };
  }

  final ApiClient api;
  final OfflineStore store;
  Map<String, dynamic>? user;

  bool get isLoggedIn => store.refreshToken != null;
  String get displayName {
    final name = user?['display_name'] as String?;
    return (name != null && name.isNotEmpty) ? name : (user?['username'] as String? ?? 'Listener');
  }

  Future<void> restore() async {
    if (!isLoggedIn) return;
    try {
      user = Map<String, dynamic>.from(await api.get('/api/auth/me/') as Map);
    } catch (_) {
      // Offline: stay "logged in" with cached profile so the app works offline-first.
      final cached = store.getCache('/api/auth/me/?{}');
      if (cached is Map) user = Map<String, dynamic>.from(cached);
    }
  }

  Future<void> login(String username, String password) async {
    final res = await api.post('/api/auth/token/', {'username': username, 'password': password}, {'noAuth': true});
    await store.saveTokens(res['access'] as String, res['refresh'] as String);
    await restore();
    notifyListeners();
  }

  Future<void> register(String username, String email, String password) async {
    final res = await api.post(
        '/api/auth/register/', {'username': username, 'email': email, 'password': password}, {'noAuth': true});
    await store.saveTokens(res['access'] as String, res['refresh'] as String);
    user = Map<String, dynamic>.from(res['user'] as Map);
    notifyListeners();
  }

  Future<void> updateDisplayName(String name) async {
    user = Map<String, dynamic>.from(await api.patch('/api/auth/me/', {'display_name': name}) as Map);
    notifyListeners();
  }

  Future<void> logout() async {
    await store.saveTokens(null, null);
    await store.cache.clear();
    user = null;
    notifyListeners();
  }
}
