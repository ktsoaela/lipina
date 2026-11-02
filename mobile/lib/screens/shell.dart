import 'package:flutter/material.dart';

import '../widgets/common.dart';
import '../widgets/mini_player.dart';
import 'home_screen.dart';
import 'library_screen.dart';
import 'podcasts_screen.dart';
import 'radio_screen.dart';
import 'search_screen.dart';

/// Bottom-nav shell. Each tab keeps its own navigation stack, and the mini player
/// stays docked above the nav bar on every screen.
class Shell extends StatefulWidget {
  const Shell({super.key});

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _index = 0;
  final _keys = List.generate(5, (_) => GlobalKey<NavigatorState>());
  static const _roots = <Widget>[HomeScreen(), SearchScreen(), RadioScreen(), PodcastsScreen(), LibraryScreen()];

  void _select(int i) {
    if (i == _index) {
      _keys[i].currentState?.popUntil((r) => r.isFirst);
    } else {
      setState(() => _index = i);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final nav = _keys[_index].currentState!;
        if (nav.canPop()) {
          nav.pop();
        } else if (_index != 0) {
          setState(() => _index = 0);
        }
      },
      child: Scaffold(
        body: Column(children: [
          const SafeArea(bottom: false, child: OfflineBanner()),
          Expanded(
            child: IndexedStack(
              index: _index,
              children: [
                for (var i = 0; i < _roots.length; i++)
                  Navigator(
                    key: _keys[i],
                    onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => _roots[i]),
                  ),
              ],
            ),
          ),
          const MiniPlayer(),
        ]),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: _select,
          height: 64,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home_rounded), label: 'Home'),
            NavigationDestination(icon: Icon(Icons.search_rounded), label: 'Search'),
            NavigationDestination(icon: Icon(Icons.radio_outlined), selectedIcon: Icon(Icons.radio), label: 'Radio'),
            NavigationDestination(icon: Icon(Icons.podcasts_outlined), selectedIcon: Icon(Icons.podcasts), label: 'Podcasts'),
            NavigationDestination(
                icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music), label: 'Library'),
          ],
        ),
      ),
    );
  }
}
