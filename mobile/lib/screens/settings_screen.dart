import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app.dart';
import '../services/auth_service.dart';
import '../services/download_service.dart';
import '../services/offline_store.dart';
import '../widgets/common.dart';
import '../widgets/track_tile.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final downloads = context.watch<DownloadService>();
    final store = OfflineStore.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(children: [
        ListTile(
          leading: const CircleAvatar(backgroundColor: LipinaColors.accent, child: Icon(Icons.person, color: Colors.black)),
          title: Text(auth.displayName),
          subtitle: Text('${auth.user?['email'] ?? ''}'),
        ),
        ListTile(
          leading: const Icon(Icons.badge_outlined),
          title: const Text('Display name'),
          onTap: () async {
            final name = await promptText(context, 'Display name', 'Your name', initial: auth.displayName);
            if (name == null) return;
            await auth.updateDisplayName(name);
          },
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: const Text('Server'),
          subtitle: Text(store.serverUrl),
          onTap: () async {
            final url = await promptText(context, 'Server URL', 'https://music.example.com', initial: store.serverUrl);
            if (url != null && url.isNotEmpty) {
              store.serverUrl = url;
              if (context.mounted) toast(context, 'Server updated');
            }
          },
        ),
        ListTile(
          leading: const Icon(Icons.sd_storage_outlined),
          title: const Text('Downloads'),
          subtitle: Text('${downloads.all.length} items · ${(downloads.totalBytes / 1048576).toStringAsFixed(1)} MB'),
          trailing: TextButton(
            onPressed: downloads.all.isEmpty
                ? null
                : () async {
                    await downloads.clear();
                    if (context.mounted) toast(context, 'Downloads cleared');
                  },
            child: const Text('Clear'),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.cached),
          title: const Text('Clear offline cache'),
          subtitle: const Text('Cached pages for browsing offline'),
          onTap: () async {
            await store.cache.clear();
            if (context.mounted) toast(context, 'Cache cleared');
          },
        ),
        const Divider(),
        const AboutListTile(
          icon: Icon(Icons.info_outline),
          applicationName: 'Lipina',
          applicationVersion: '1.0.0',
          aboutBoxChildren: [
            Text('Radio directory by radio-browser.info · Lyrics by LRCLIB · Podcast directory by Apple Podcasts · '
                'Song recognition by AudD.'),
          ],
        ),
        ListTile(
          leading: const Icon(Icons.logout, color: Colors.redAccent),
          title: const Text('Log out', style: TextStyle(color: Colors.redAccent)),
          onTap: () async {
            await auth.logout();
            if (context.mounted) Navigator.of(context, rootNavigator: true).popUntil((r) => r.isFirst);
          },
        ),
      ]),
    );
  }
}
