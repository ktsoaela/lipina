import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/api_client.dart';
import '../app.dart';
import '../models/models.dart';
import '../services/player_controller.dart';
import '../widgets/common.dart';

/// Live South African radio: browse by province or genre, favourites, now-playing.
class RadioScreen extends StatefulWidget {
  const RadioScreen({super.key});

  @override
  State<RadioScreen> createState() => _RadioScreenState();
}

class _RadioScreenState extends State<RadioScreen> {
  String? _state;
  String? _tag;
  bool _favorites = false;
  String _q = '';
  Timer? _debounce;
  Map? _facets;
  int _reload = 0;

  @override
  void initState() {
    super.initState();
    context.read<ApiClient>().get('/api/radio/stations/facets/').then((f) {
      if (mounted) setState(() => _facets = f as Map);
    }).catchError((_) {});
  }

  Future<List<Station>> _load() async {
    final list = await context.read<ApiClient>().getList('/api/radio/stations/', query: {
      'limit': 300,
      if (_q.isNotEmpty) 'q': _q,
      if (_state != null) 'state': _state,
      if (_tag != null) 'tag': _tag,
      if (_favorites) 'favorites': '1',
    });
    return list.map(Station.new).toList();
  }

  void _refresh() => setState(() => _reload++);

  @override
  Widget build(BuildContext context) {
    final states = ((_facets?['states'] as List?) ?? []).map((e) => '${e['name']}').toList();
    final tags = ((_facets?['tags'] as List?) ?? []).map((e) => '${e['name']}').toList();
    final player = context.watch<PlayerController>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('South African Radio', style: TextStyle(fontWeight: FontWeight.w800)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              decoration: const InputDecoration(hintText: 'Search stations', prefixIcon: Icon(Icons.search), contentPadding: EdgeInsets.zero),
              onChanged: (v) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 350), () {
                  _q = v.trim();
                  _refresh();
                });
              },
            ),
          ),
        ),
      ),
      body: Column(children: [
        SizedBox(
          height: 48,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FilterChip(
                avatar: const Icon(Icons.favorite, size: 16),
                label: const Text('Favourites'),
                selected: _favorites,
                onSelected: (v) {
                  _favorites = v;
                  _refresh();
                },
              ),
            ),
            for (final s in states)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: ChoiceChip(
                  label: Text(s),
                  selected: _state == s,
                  onSelected: (v) {
                    _state = v ? s : null;
                    _refresh();
                  },
                ),
              ),
          ]),
        ),
        if (tags.isNotEmpty)
          SizedBox(
            height: 44,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
              for (final t in tags.take(20))
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: ChoiceChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(t),
                    selected: _tag == t,
                    onSelected: (v) {
                      _tag = v ? t : null;
                      _refresh();
                    },
                  ),
                ),
            ]),
          ),
        Expanded(
          child: AsyncView<List<Station>>(
            key: ValueKey('$_reload-$_q-$_state-$_tag-$_favorites'),
            load: _load,
            builder: (context, stations, reload) => stations.isEmpty
                ? const EmptyState(icon: Icons.radio, title: 'No stations match')
                : RefreshIndicator(
                    onRefresh: reload,
                    child: ListView.builder(
                      itemCount: stations.length,
                      itemBuilder: (_, i) {
                        final s = stations[i];
                        final playing = player.current?.key == 'station:${s.id}';
                        return ListTile(
                          leading: Cover(s.favicon, size: 52, icon: Icons.radio),
                          title: Text(s.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: playing ? LipinaColors.accent : null, fontWeight: FontWeight.w600)),
                          subtitle: Text(
                            playing && player.liveTitle != null
                                ? '♪ ${player.liveTitle}'
                                : [s.state, ...s.tags.take(3), if (s.bitrate > 0) '${s.bitrate}kbps'].where((x) => x.isNotEmpty).join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: LipinaColors.muted),
                          ),
                          trailing: IconButton(
                            icon: Icon(s.isFavorite ? Icons.favorite : Icons.favorite_border,
                                color: s.isFavorite ? LipinaColors.accent : null),
                            onPressed: () async {
                              final api = context.read<ApiClient>();
                              setState(() => s.isFavorite = !s.isFavorite);
                              try {
                                s.isFavorite
                                    ? await api.post('/api/radio/stations/${s.id}/favorite/')
                                    : await api.delete('/api/radio/stations/${s.id}/favorite/');
                              } catch (e) {
                                if (mounted) setState(() => s.isFavorite = !s.isFavorite);
                              }
                            },
                          ),
                          onTap: () => player.playStation(s),
                        );
                      },
                    ),
                  ),
          ),
        ),
      ]),
    );
  }
}
