import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

class ConnectivityService extends ChangeNotifier {
  ConnectivityService() {
    _sub = Connectivity().onConnectivityChanged.listen(_update);
    Connectivity().checkConnectivity().then(_update);
  }

  late final StreamSubscription _sub;
  bool online = true;
  final _onlineController = StreamController<void>.broadcast();

  /// Fires each time the device transitions from offline to online.
  Stream<void> get cameOnline => _onlineController.stream;

  void _update(List<ConnectivityResult> results) {
    final now = results.any((r) => r != ConnectivityResult.none);
    if (now == online) return;
    online = now;
    if (now) _onlineController.add(null);
    notifyListeners();
  }

  @override
  void dispose() {
    _sub.cancel();
    _onlineController.close();
    super.dispose();
  }
}
