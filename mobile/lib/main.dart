import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'api/api_client.dart';
import 'app.dart';
import 'services/audio_handler.dart';
import 'services/auth_service.dart';
import 'services/connectivity_service.dart';
import 'services/download_service.dart';
import 'services/local_music_service.dart';
import 'services/offline_store.dart';
import 'services/player_controller.dart';
import 'services/tools_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await OfflineStore.init();

  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());

  final handler = await AudioService.init(
    builder: LipinaAudioHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'za.lipina.playback',
      androidNotificationChannelName: 'Lipina playback',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );

  final store = OfflineStore.instance;
  final api = ApiClient(store);
  final auth = AuthService(api, store);
  await auth.restore();
  final connectivity = ConnectivityService();
  final downloads = DownloadService(api, store);
  final player = PlayerController(handler, api, store, downloads, connectivity);

  runApp(
    MultiProvider(
      providers: [
        Provider.value(value: api),
        ChangeNotifierProvider.value(value: auth),
        ChangeNotifierProvider.value(value: connectivity),
        ChangeNotifierProvider.value(value: downloads),
        ChangeNotifierProvider.value(value: player),
        ChangeNotifierProvider(create: (_) => LocalMusicService(store)),
        ChangeNotifierProvider(create: (_) => ToolsService(player)),
      ],
      child: const LipinaApp(),
    ),
  );
}
