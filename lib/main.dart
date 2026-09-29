import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: supabaseUrl,
    publishableKey: supabasePublishableKey,
  );

  await Store.instance.load();
  runApp(const ChibbyballApp());
}

class ChibbyballApp extends StatelessWidget {
  const ChibbyballApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CHIBBYBALL League',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
      ),
      home: const LoginPage(),
    );
  }
}

// ============================================================
// MODELS
// ============================================================

class Player {
  final String id;
  final String name;
  final String gamerTag;
  final bool admin;

  const Player({
    required this.id,
    required this.name,
    required this.gamerTag,
    this.admin = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'gamerTag': gamerTag,
        'admin': admin,
      };

  factory Player.fromJson(Map<String, dynamic> json) => Player(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        gamerTag: json['gamerTag']?.toString() ?? '',
        admin: json['admin'] == true,
      );
}


class LeagueInfo {
  final String id;
  final String name;
  final String status;
  final DateTime? createdAt;

  const LeagueInfo({
    required this.id,
    required this.name,
    required this.status,
    this.createdAt,
  });
}

class MatchItem {
  final String id;
  final String homeId;
  final String awayId;
  final int round;

  int? homeScore;
  int? awayScore;
  int? homeClaimHome;
  int? homeClaimAway;
  int? awayClaimHome;
  int? awayClaimAway;
  String? homeProof;
  String? awayProof;
  String status;

  MatchItem({
    required this.id,
    required this.homeId,
    required this.awayId,
    required this.round,
    this.homeScore,
    this.awayScore,
    this.homeClaimHome,
    this.homeClaimAway,
    this.awayClaimHome,
    this.awayClaimAway,
    this.homeProof,
    this.awayProof,
    this.status = 'Scheduled',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'homeId': homeId,
        'awayId': awayId,
        'round': round,
        'homeScore': homeScore,
        'awayScore': awayScore,
        'homeClaimHome': homeClaimHome,
        'homeClaimAway': homeClaimAway,
        'awayClaimHome': awayClaimHome,
        'awayClaimAway': awayClaimAway,
        'homeProof': homeProof,
        'awayProof': awayProof,
        'status': status,
      };

  factory MatchItem.fromJson(Map<String, dynamic> json) => MatchItem(
        id: json['id']?.toString() ?? '',
        homeId: json['homeId']?.toString() ?? '',
        awayId: json['awayId']?.toString() ?? '',
        round: (json['round'] as num?)?.toInt() ?? 1,
        homeScore: (json['homeScore'] as num?)?.toInt(),
        awayScore: (json['awayScore'] as num?)?.toInt(),
        homeClaimHome: (json['homeClaimHome'] as num?)?.toInt(),
        homeClaimAway: (json['homeClaimAway'] as num?)?.toInt(),
        awayClaimHome: (json['awayClaimHome'] as num?)?.toInt(),
        awayClaimAway: (json['awayClaimAway'] as num?)?.toInt(),
        homeProof: json['homeProof']?.toString(),
        awayProof: json['awayProof']?.toString(),
        status: json['status']?.toString() ?? 'Scheduled',
      );
}

// ============================================================
// STORE
// ============================================================

class Store {
  static final Store instance = Store._();
  Store._();

  final SupabaseClient supabase = Supabase.instance.client;

  final List<Player> players = [];
  final List<MatchItem> matches = [];
  Player? current;
  final List<LeagueInfo> leagues = [];
  String? activeLeagueId;
  String? activeLeagueName;
  String? activeLeagueStatus;
  Set<String> activeLeagueMemberIds = {};

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    final savedPlayers = prefs.getString('local_players');
    final savedMatches = prefs.getString('local_matches');

    if (savedPlayers != null) {
      try {
        final decoded = jsonDecode(savedPlayers) as List;
        players
          ..clear()
          ..addAll(
            decoded.map(
              (e) => Player.fromJson(Map<String, dynamic>.from(e)),
            ),
          );
      } catch (_) {}
    }

    if (savedMatches != null) {
      try {
        final decoded = jsonDecode(savedMatches) as List;
        matches
          ..clear()
          ..addAll(
            decoded.map(
              (e) => MatchItem.fromJson(Map<String, dynamic>.from(e)),
            ),
          );
      } catch (_) {}
    }

    try {
      await refreshPlayers();
      await refreshLeagues();
      await loadMatchesFromSupabase();
    } catch (_) {}
  }

  Future<void> refreshLeagues() async {
    final data = await supabase
        .from('leagues')
        .select('id, name, status, created_at')
        .order('created_at', ascending: false);

    leagues
      ..clear()
      ..addAll((data as List).map((item) {
        final row = Map<String, dynamic>.from(item);
        return LeagueInfo(
          id: row['id'].toString(),
          name: row['name']?.toString() ?? '',
          status: row['status']?.toString() ?? 'open',
          createdAt: row['created_at'] == null
              ? null
              : DateTime.tryParse(row['created_at'].toString()),
        );
      }));

    final active = leagues.where((l) => l.status == 'active').toList();
    if (active.isNotEmpty) {
      activeLeagueId = active.first.id;
      activeLeagueName = active.first.name;
      activeLeagueStatus = active.first.status;
      try {
        activeLeagueMemberIds = (await leagueMemberIds(activeLeagueId!)).toSet();
      } catch (_) {
        activeLeagueMemberIds = {};
      }
    } else {
      activeLeagueId = null;
      activeLeagueName = null;
      activeLeagueStatus = null;
      activeLeagueMemberIds = {};
    }
  }

  Future<String?> _activeLeagueId() async {
    if (activeLeagueId != null) return activeLeagueId;
    await refreshLeagues();
    return activeLeagueId;
  }

  Future<String?> createLeague(String name) async {
    final clean = name.trim();
    if (clean.isEmpty) return 'League name is required.';
    if (Store.instance.current?.admin != true) return 'Admin access required.';
    try {
      await supabase.from('leagues').insert({
        'name': clean,
        'status': 'open',
      });
      await refreshLeagues();
      return null;
    } on PostgrestException catch (e) {
      return 'Could not create league: ${e.message}';
    } catch (e) {
      return 'Could not create league: $e';
    }
  }

  Future<String?> setLeagueStatus(String leagueId, String status) async {
    if (Store.instance.current?.admin != true) return 'Admin access required.';
    try {
      if (status == 'active') {
        await supabase
            .from('leagues')
            .update({'status': 'open'})
            .eq('status', 'active')
            .neq('id', leagueId);
      }
      await supabase.from('leagues').update({'status': status}).eq('id', leagueId);
      await refreshLeagues();
      await loadMatchesFromSupabase();
      return null;
    } on PostgrestException catch (e) {
      return 'Could not update league: ${e.message}';
    } catch (e) {
      return 'Could not update league: $e';
    }
  }

  Future<List<String>> leagueMemberIds(String leagueId) async {
    final data = await supabase
        .from('league_members')
        .select('player_id')
        .eq('league_id', leagueId);
    return (data as List)
        .map((e) => Map<String, dynamic>.from(e)['player_id'].toString())
        .toList();
  }

  Future<String?> addLeagueMember(String leagueId, String playerId) async {
    if (Store.instance.current?.admin != true) return 'Admin access required.';
    try {
      await supabase.from('league_members').upsert({
        'league_id': leagueId,
        'player_id': playerId,
      });
      return null;
    } on PostgrestException catch (e) {
      return 'Could not add player: ${e.message}';
    } catch (e) {
      return 'Could not add player: $e';
    }
  }

  Future<String?> removeLeagueMember(String leagueId, String playerId) async {
    if (Store.instance.current?.admin != true) return 'Admin access required.';
    try {
      await supabase
          .from('league_members')
          .delete()
          .eq('league_id', leagueId)
          .eq('player_id', playerId);
      return null;
    } on PostgrestException catch (e) {
      return 'Could not remove player: ${e.message}';
    } catch (e) {
      return 'Could not remove player: $e';
    }
  }

  Future<void> loadMatchesFromSupabase() async {
    final leagueId = await _activeLeagueId();
    if (leagueId == null) {
      matches.clear();
      await save();
      return;
    }

    final data = await supabase
        .from('matches')
        .select(
          'id, round, home_player_id, away_player_id, status, home_score, away_score',
        )
        .eq('league_id', leagueId)
        .order('round')
        .order('created_at');

    final rows = (data as List).map((e) => Map<String, dynamic>.from(e)).toList();
    final loaded = <MatchItem>[];

    if (rows.isNotEmpty) {
      final matchIds = rows.map((r) => r['id'].toString()).toList();
      final submissions = await supabase
          .from('match_submissions')
          .select(
            'match_id, player_id, claimed_home_score, claimed_away_score, proof_path',
          )
          .inFilter('match_id', matchIds);

      final submissionsByMatch = <String, List<Map<String, dynamic>>>{};
      for (final item in (submissions as List)) {
        final row = Map<String, dynamic>.from(item);
        final id = row['match_id'].toString();
        submissionsByMatch.putIfAbsent(id, () => []).add(row);
      }

      for (final row in rows) {
        final match = MatchItem(
          id: row['id'].toString(),
          homeId: row['home_player_id'].toString(),
          awayId: row['away_player_id'].toString(),
          round: (row['round'] as num).toInt(),
          homeScore: (row['home_score'] as num?)?.toInt(),
          awayScore: (row['away_score'] as num?)?.toInt(),
          status: _dbStatusToLocal(row['status']?.toString()),
        );

        for (final sub in submissionsByMatch[match.id] ?? []) {
          final playerId = sub['player_id'].toString();
          final home = (sub['claimed_home_score'] as num?)?.toInt();
          final away = (sub['claimed_away_score'] as num?)?.toInt();
          final proof = sub['proof_path']?.toString();

          if (playerId == match.homeId) {
            match.homeClaimHome = home;
            match.homeClaimAway = away;
            match.homeProof = proof;
          } else if (playerId == match.awayId) {
            match.awayClaimHome = home;
            match.awayClaimAway = away;
            match.awayProof = proof;
          }
        }

        loaded.add(match);
      }
    }

    matches
      ..clear()
      ..addAll(loaded);

    await save();
  }

  String _dbStatusToLocal(String? status) {
    switch (status) {
      case 'awaiting_confirmation':
        return 'Awaiting Confirmation';
      case 'confirmed':
        return 'Confirmed';
      case 'disputed':
        return 'Disputed';
      default:
        return 'Scheduled';
    }
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(
      'local_players',
      jsonEncode(players.map((e) => e.toJson()).toList()),
    );

    await prefs.setString(
      'local_matches',
      jsonEncode(matches.map((e) => e.toJson()).toList()),
    );
  }

  String _emailFromGamerTag(String gamerTag) {
    final safe = gamerTag
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]'), '_');
    return '$safe@chibbyball.app';
  }

  Future<void> refreshPlayers() async {
    final data = await supabase
        .from('profiles')
        .select('id, full_name, gamer_tag, role, created_at')
        .order('created_at');

    players
      ..clear()
      ..addAll(
        (data as List).map((item) {
          final row = Map<String, dynamic>.from(item);
          return Player(
            id: row['id'].toString(),
            name: row['full_name']?.toString() ?? '',
            gamerTag: row['gamer_tag']?.toString() ?? '',
            admin: row['role']?.toString().toLowerCase() == 'admin',
          );
        }),
      );

    await save();
  }

  // IMPORTANT:
  // Registration relies on the Supabase auth.users -> profiles trigger.
  // We intentionally DO NOT upsert profiles from the client here.
  // That avoids hitting the UPDATE/USING side of profiles RLS.
  Future<String?> register(
    String name,
    String gamerTag,
    String password,
  ) async {
    try {
      final cleanName = name.trim();
      final cleanTag = gamerTag.trim();

      if (cleanName.isEmpty) {
        return 'Full name is required.';
      }
      if (cleanTag.isEmpty) {
        return 'Gamer tag is required.';
      }
      if (password.length < 6) {
        return 'Password must be at least 6 characters.';
      }

      // Gamer tags are unique in public.profiles.
      final existing = await supabase
          .from('profiles')
          .select('id')
          .eq('gamer_tag', cleanTag)
          .maybeSingle();

      if (existing != null) {
        return 'Gamer tag "$cleanTag" is already in use.';
      }

      final email = _emailFromGamerTag(cleanTag);

      final response = await supabase.auth.signUp(
        email: email,
        password: password,
        data: {
          'full_name': cleanName,
          'gamer_tag': cleanTag,
        },
      );

      final user = response.user;
      if (user == null) {
        return 'Supabase did not create the account.';
      }

      // The database trigger creates the profile.
      // Give the trigger a moment, then verify it exists.
      Map<String, dynamic>? profile;

      for (int attempt = 0; attempt < 5; attempt++) {
        try {
          final row = await supabase
              .from('profiles')
              .select('id, full_name, gamer_tag, role')
              .eq('id', user.id)
              .maybeSingle();

          if (row != null) {
            profile = Map<String, dynamic>.from(row);
            break;
          }
        } catch (_) {}

        await Future.delayed(const Duration(milliseconds: 400));
      }

      if (profile == null) {
        return 'Account was created, but the player profile was not created. Check the Supabase profile trigger.';
      }

      current = Player(
        id: user.id,
        name: profile['full_name']?.toString() ?? cleanName,
        gamerTag: profile['gamer_tag']?.toString() ?? cleanTag,
        admin: profile['role']?.toString().toLowerCase() == 'admin',
      );

      try {
        await refreshPlayers();
        await refreshLeagues();
        await loadMatchesFromSupabase();
      } catch (_) {
        players.removeWhere((p) => p.id == user.id);
        players.add(current!);
        await save();
      }

      if (response.session == null) {
        return 'Account created. Please sign in after confirming your email.';
      }

      return null;
    } on AuthException catch (e) {
      return 'Authentication error: ${e.message}';
    } on PostgrestException catch (e) {
      return 'Database error: ${e.message}';
    } catch (e) {
      return 'Registration error: $e';
    }
  }

  Future<Player?> login(String gamerTag, String password) async {
    try {
      final cleanTag = gamerTag.trim();

      if (cleanTag.isEmpty || password.isEmpty) {
        return null;
      }

      final email = _emailFromGamerTag(cleanTag);

      final response = await supabase.auth.signInWithPassword(
        email: email,
        password: password,
      );

      final user = response.user;
      if (user == null) return null;

      final profile = await supabase
          .from('profiles')
          .select('id, full_name, gamer_tag, role')
          .eq('id', user.id)
          .maybeSingle();

      if (profile == null) {
        return null;
      }

      current = Player(
        id: user.id,
        name: profile['full_name']?.toString() ?? '',
        gamerTag: profile['gamer_tag']?.toString() ?? cleanTag,
        admin: profile['role']?.toString().toLowerCase() == 'admin',
      );

      try {
        await refreshPlayers();
        await refreshLeagues();
        await loadMatchesFromSupabase();
      } catch (_) {}

      return current;
    } catch (_) {
      return null;
    }
  }

  Future<void> logout() async {
    try {
      await supabase.auth.signOut();
    } catch (_) {}
    current = null;
  }

  Player? findPlayer(String id) {
    for (final player in players) {
      if (player.id == id) return player;
    }
    return null;
  }

  String playerName(String id) {
    return findPlayer(id)?.gamerTag ?? 'Unknown Player';
  }

  Future<String?> generateFixtures() async {
    final leagueId = await _activeLeagueId();
    if (leagueId == null) {
      return 'No active league found.';
    }

    final memberIds = await leagueMemberIds(leagueId);
    final activePlayers = players.where((p) => !p.admin && memberIds.contains(p.id)).toList();

    if (activePlayers.length < 2) {
      return 'Add at least 2 players to the active league first.';
    }

    await loadMatchesFromSupabase();
    if (matches.isNotEmpty) {
      return 'Fixtures already exist in Supabase.';
    }

    final ids = activePlayers.map((p) => p.id).toList();
    if (ids.length.isOdd) ids.add('BYE');

    final total = ids.length;
    final rounds = total - 1;
    final rotation = List<String>.from(ids);
    final rows = <Map<String, dynamic>>[];

    for (int round = 0; round < rounds; round++) {
      for (int i = 0; i < total ~/ 2; i++) {
        final first = rotation[i];
        final second = rotation[total - 1 - i];
        if (first == 'BYE' || second == 'BYE') continue;

        final homeId = round.isEven ? first : second;
        final awayId = round.isEven ? second : first;

        rows.add({
          'league_id': leagueId,
          'round': round + 1,
          'home_player_id': homeId,
          'away_player_id': awayId,
          'status': 'scheduled',
        });
      }

      rotation.insert(1, rotation.removeLast());
    }

    try {
      await supabase.from('matches').insert(rows);
      await loadMatchesFromSupabase();
      return null;
    } on PostgrestException catch (e) {
      return 'Could not save fixtures: ${e.message}';
    } catch (e) {
      return 'Could not save fixtures: $e';
    }
  }

  Future<String?> submitResult({
    required MatchItem match,
    required Player player,
    required int homeScore,
    required int awayScore,
    required File proofFile,
  }) async {
    if (player.id != match.homeId && player.id != match.awayId) {
      return 'You are not a player in this match.';
    }

    try {
      final proofPath =
          '${player.id}/${match.id}/${DateTime.now().millisecondsSinceEpoch}.jpg';

      await supabase.storage.from('match-proofs').upload(
            proofPath,
            proofFile,
            fileOptions: const FileOptions(upsert: true),
          );

      await supabase.from('match_submissions').upsert(
        {
          'match_id': match.id,
          'player_id': player.id,
          'claimed_home_score': homeScore,
          'claimed_away_score': awayScore,
          'proof_path': proofPath,
        },
        onConflict: 'match_id,player_id',
      );

      await loadMatchesFromSupabase();
      return null;
    } on StorageException catch (e) {
      return 'Proof upload failed: ${e.message}';
    } on PostgrestException catch (e) {
      return 'Result save failed: ${e.message}';
    } catch (e) {
      return 'Result submission failed: $e';
    }
  }

  List<MatchItem> confirmedMatches() {
    return matches.where((m) => m.status == 'Confirmed').toList();
  }

  Map<String, int> statsForPlayer(String playerId) {
    final table = buildTable();
    return Map<String, int>.from(table[playerId] ?? {
      'played': 0,
      'won': 0,
      'drawn': 0,
      'lost': 0,
      'gf': 0,
      'ga': 0,
      'gd': 0,
      'points': 0,
    });
  }

  List<MatchItem> confirmedMatchesForPlayer(String playerId) {
    final result = confirmedMatches()
        .where((m) => m.homeId == playerId || m.awayId == playerId)
        .toList();
    result.sort((a, b) {
      final roundCompare = b.round.compareTo(a.round);
      if (roundCompare != 0) return roundCompare;
      return b.id.compareTo(a.id);
    });
    return result;
  }

  Map<String, Map<String, int>> buildTable() {
    final table = <String, Map<String, int>>{};

    // The matches list is already loaded only for the active league.
    // Include active-league members AND any players appearing in those
    // matches so an existing confirmed result can never disappear from
    // the table just because membership was edited later.
    final participantIds = <String>{...activeLeagueMemberIds};
    for (final match in matches) {
      participantIds.add(match.homeId);
      participantIds.add(match.awayId);
    }

    for (final player in players.where(
      (p) => !p.admin && participantIds.contains(p.id),
    )) {
      table[player.id] = {
        'played': 0,
        'won': 0,
        'drawn': 0,
        'lost': 0,
        'gf': 0,
        'ga': 0,
        'gd': 0,
        'points': 0,
      };
    }

    for (final match in confirmedMatches()) {
      final home = table[match.homeId];
      final away = table[match.awayId];

      if (home == null || away == null) continue;

      final hs = match.homeScore ?? 0;
      final as = match.awayScore ?? 0;

      home['played'] = home['played']! + 1;
      away['played'] = away['played']! + 1;

      home['gf'] = home['gf']! + hs;
      home['ga'] = home['ga']! + as;
      away['gf'] = away['gf']! + as;
      away['ga'] = away['ga']! + hs;

      if (hs > as) {
        home['won'] = home['won']! + 1;
        away['lost'] = away['lost']! + 1;
        home['points'] = home['points']! + 3;
      } else if (hs < as) {
        away['won'] = away['won']! + 1;
        home['lost'] = home['lost']! + 1;
        away['points'] = away['points']! + 3;
      } else {
        home['drawn'] = home['drawn']! + 1;
        away['drawn'] = away['drawn']! + 1;
        home['points'] = home['points']! + 1;
        away['points'] = away['points']! + 1;
      }
    }

    for (final stats in table.values) {
      stats['gd'] = stats['gf']! - stats['ga']!;
    }

    return table;
  }
}

// ============================================================
// LOGIN
// ============================================================

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final tagController = TextEditingController();
  final passwordController = TextEditingController();
  bool loading = false;

  Future<void> login() async {
    if (tagController.text.trim().isEmpty ||
        passwordController.text.isEmpty) {
      showMessage('Enter your gamer tag and password.');
      return;
    }

    setState(() => loading = true);

    final player = await Store.instance.login(
      tagController.text.trim(),
      passwordController.text,
    );

    if (!mounted) return;

    setState(() => loading = false);

    if (player == null) {
      showMessage('Invalid gamer tag or password.');
      return;
    }

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const HomePage()),
    );
  }

  void showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    tagController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Icon(Icons.sports_soccer,
                    size: 90, color: Colors.blue),
                const SizedBox(height: 18),
                const Text(
                  'CHIBBYBALL',
                  style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Text('eFootball League'),
                const SizedBox(height: 40),
                TextField(
                  controller: tagController,
                  decoration: const InputDecoration(
                    labelText: 'Gamer Tag',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.person),
                  ),
                ),
                const SizedBox(height: 15),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.lock),
                  ),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    onPressed: loading ? null : login,
                    child: loading
                        ? const CircularProgressIndicator()
                        : const Text('LOGIN'),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const RegisterPage(),
                    ),
                  ),
                  child: const Text('Create Player Account'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// REGISTER
// ============================================================

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final nameController = TextEditingController();
  final tagController = TextEditingController();
  final passwordController = TextEditingController();

  bool loading = false;

  Future<void> register() async {
    final name = nameController.text.trim();
    final tag = tagController.text.trim();
    final password = passwordController.text;

    if (name.isEmpty || tag.isEmpty || password.length < 6) {
      showMessage(
        'Enter your name, gamer tag and a password of at least 6 characters.',
      );
      return;
    }

    setState(() => loading = true);

    final error = await Store.instance.register(name, tag, password);

    if (!mounted) return;

    setState(() => loading = false);

    if (error != null) {
      showMessage(error);
      return;
    }

    showMessage('Account created successfully.');

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const HomePage()),
    );
  }

  void showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    nameController.dispose();
    tagController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Player Registration')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: nameController,
            decoration: const InputDecoration(
              labelText: 'Full Name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 15),
          TextField(
            controller: tagController,
            decoration: const InputDecoration(
              labelText: 'Unique Gamer Tag',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 15),
          TextField(
            controller: passwordController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Password',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 25),
          SizedBox(
            height: 52,
            child: FilledButton(
              onPressed: loading ? null : register,
              child: loading
                  ? const CircularProgressIndicator()
                  : const Text('REGISTER'),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// HOME
// ============================================================

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final player = Store.instance.current;

    final pages = const [
      DashboardPage(),
      FixturesPage(),
      TablePage(),
      ProfilePage(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('CHIBBYBALL League'),
        actions: [
          if (player?.admin == true)
            IconButton(
              icon: const Icon(Icons.admin_panel_settings),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const AdminPage(),
                ),
              ).then((_) => setState(() {})),
            ),
        ],
      ),
      body: pages[selectedIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: (index) =>
            setState(() => selectedIndex = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.sports_soccer),
            label: 'Fixtures',
          ),
          NavigationDestination(
            icon: Icon(Icons.leaderboard),
            label: 'Table',
          ),
          NavigationDestination(
            icon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}

// ============================================================
// DASHBOARD
// ============================================================

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = Store.instance;
    final player = store.current;

    final myMatches = player == null
        ? <MatchItem>[]
        : store.matches
            .where(
              (m) => m.homeId == player.id || m.awayId == player.id,
            )
            .toList();

    final confirmed =
        myMatches.where((m) => m.status == 'Confirmed').length;
    final awaiting =
        myMatches.where((m) => m.status == 'Awaiting Confirmation').length;
    final disputed =
        myMatches.where((m) => m.status == 'Disputed').length;

    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Text(
          'Welcome, ${player?.gamerTag ?? ''}',
          style: const TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 22),
        _card(
          context,
          Icons.sports_soccer,
          'Your Fixtures',
          '${myMatches.length}',
        ),
        _card(
          context,
          Icons.check_circle,
          'Confirmed Results',
          '$confirmed',
          statusFilter: 'Confirmed',
        ),
        _card(
          context,
          Icons.hourglass_top,
          'Awaiting Confirmation',
          '$awaiting',
          statusFilter: 'Awaiting Confirmation',
        ),
        _card(
          context,
          Icons.warning,
          'Disputed',
          '$disputed',
          statusFilter: 'Disputed',
        ),
        const SizedBox(height: 12),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(18),
            child: Text(
              'RESULT RULE\n\n'
              'Both players must submit the result with screenshot proof '
              'before the match becomes confirmed.\n\n'
              'Different scores make the match DISPUTED for admin review.',
            ),
          ),
        ),
      ],
    );
  }

  Widget _card(
    BuildContext context,
    IconData icon,
    String title,
    String value, {
    String? statusFilter,
  }) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right),
          ],
        ),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => FixturesPage(statusFilter: statusFilter),
            ),
          );
        },
      ),
    );
  }
}

// ============================================================
// FIXTURES
// ============================================================

class FixturesPage extends StatefulWidget {
  final String? statusFilter;

  const FixturesPage({super.key, this.statusFilter});

  @override
  State<FixturesPage> createState() => _FixturesPageState();
}

class _FixturesPageState extends State<FixturesPage> {
  @override
  Widget build(BuildContext context) {
    final store = Store.instance;

    if (store.matches.isEmpty) {
      return Center(
        child: FilledButton.icon(
          icon: const Icon(Icons.auto_awesome),
          label: const Text('Generate Fixtures'),
          onPressed: () async {
            final error = await store.generateFixtures();
            if (!mounted) return;
            setState(() {});
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  error ?? 'Fixtures saved to Supabase successfully.',
                ),
              ),
            );
          },
        ),
      );
    }

    final player = store.current;
    var visibleMatches = store.matches;

    if (player != null) {
      visibleMatches = visibleMatches
          .where((m) => m.homeId == player.id || m.awayId == player.id)
          .toList();
    }

    if (widget.statusFilter != null) {
      visibleMatches = visibleMatches
          .where((m) => m.status == widget.statusFilter)
          .toList();
    }

    if (visibleMatches.isEmpty) {
      return Center(
        child: Text(
          widget.statusFilter == null
              ? 'No fixtures found.'
              : 'No ${widget.statusFilter!.toLowerCase()} matches found.',
          style: const TextStyle(fontSize: 16),
        ),
      );
    }

    final rounds = visibleMatches.map((m) => m.round).toSet().toList()
      ..sort();

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (widget.statusFilter != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
            child: Text(
              widget.statusFilter!.toUpperCase(),
              style: const TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        for (final round in rounds) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
            child: Text(
              'MATCHDAY $round',
              style: const TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ...visibleMatches
              .where((m) => m.round == round)
              .map(
                (match) => Card(
                  child: ListTile(
                    title: Text(
                      '${store.playerName(match.homeId)}  vs  '
                      '${store.playerName(match.awayId)}',
                    ),
                    subtitle: Text(
                      match.status == 'Confirmed'
                          ? '${match.homeScore} - ${match.awayScore}'
                          : match.status,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ResultPage(match: match),
                      ),
                    ).then((_) => setState(() {})),
                  ),
                ),
              ),
        ],
      ],
    );
  }
}

// ============================================================
// RESULT
// ============================================================

class ResultPage extends StatefulWidget {
  final MatchItem match;

  const ResultPage({super.key, required this.match});

  @override
  State<ResultPage> createState() => _ResultPageState();
}

class _ResultPageState extends State<ResultPage> {
  final homeController = TextEditingController();
  final awayController = TextEditingController();

  File? proof;
  bool loading = false;

  Future<void> chooseProof() async {
    final image = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 70,
    );

    if (image == null || !mounted) return;

    setState(() => proof = File(image.path));
  }

  Future<void> submit() async {
    final player = Store.instance.current;

    if (player == null) return;

    final homeScore = int.tryParse(homeController.text.trim());
    final awayScore = int.tryParse(awayController.text.trim());

    if (homeScore == null ||
        awayScore == null ||
        homeScore < 0 ||
        awayScore < 0 ||
        proof == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Enter both scores and select screenshot proof.',
          ),
        ),
      );
      return;
    }

    setState(() => loading = true);

    final error = await Store.instance.submitResult(
      match: widget.match,
      player: player,
      homeScore: homeScore,
      awayScore: awayScore,
      proofFile: proof!,
    );

    if (!mounted) return;

    setState(() => loading = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          error ?? 'Result saved. Status: ${widget.match.status}',
        ),
      ),
    );

    Navigator.pop(context);
  }

  @override
  void dispose() {
    homeController.dispose();
    awayController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = Store.instance;
    final match = widget.match;

    return Scaffold(
      appBar: AppBar(title: const Text('Submit Result')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            '${store.playerName(match.homeId)} vs '
            '${store.playerName(match.awayId)}',
            style: const TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          Text('Status: ${match.status}'),
          const SizedBox(height: 24),
          TextField(
            controller: homeController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText:
                  '${store.playerName(match.homeId)} score',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 15),
          TextField(
            controller: awayController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText:
                  '${store.playerName(match.awayId)} score',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: loading ? null : chooseProof,
            icon: const Icon(Icons.photo_library),
            label: Text(
              proof == null
                  ? 'Choose Screenshot Proof'
                  : 'Screenshot Selected',
            ),
          ),
          if (proof != null) ...[
            const SizedBox(height: 15),
            SizedBox(
              height: 200,
              child: Image.file(
                proof!,
                fit: BoxFit.contain,
              ),
            ),
          ],
          const SizedBox(height: 22),
          FilledButton.icon(
            onPressed: loading ? null : submit,
            icon: const Icon(Icons.send),
            label: const Text('SUBMIT RESULT'),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// TABLE
// ============================================================

class TablePage extends StatelessWidget {
  const TablePage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = Store.instance;
    final table = store.buildTable();

    final ordered = table.keys.toList()
      ..sort((a, b) {
        final x = table[a]!;
        final y = table[b]!;

        final p = y['points']!.compareTo(x['points']!);
        if (p != 0) return p;

        final gd = y['gd']!.compareTo(x['gd']!);
        if (gd != 0) return gd;

        return y['gf']!.compareTo(x['gf']!);
      });

    if (ordered.isEmpty) {
      return const Center(
        child: Text('No players in the league yet.'),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text(
            'LEAGUE TABLE',
            style: TextStyle(
              fontSize: 23,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Card(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 10,
              horizontalMargin: 8,
              dataRowMinHeight: 48,
              dataRowMaxHeight: 56,
              headingRowHeight: 48,
              columns: const [
                DataColumn(label: Text('#')),
                DataColumn(label: Text('PLAYER')),
                DataColumn(label: Text('P')),
                DataColumn(label: Text('W')),
                DataColumn(label: Text('D')),
                DataColumn(label: Text('L')),
                DataColumn(label: Text('GD')),
                DataColumn(label: Text('PTS')),
              ],
              rows: [
                for (int i = 0; i < ordered.length; i++)
                  DataRow(
                    cells: [
                      DataCell(Text('${i + 1}')),
                      DataCell(
                        SizedBox(
                          width: 82,
                          child: Text(
                            store.playerName(ordered[i]),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      DataCell(
                        Text('${table[ordered[i]]!['played']}'),
                      ),
                      DataCell(
                        Text('${table[ordered[i]]!['won']}'),
                      ),
                      DataCell(
                        Text('${table[ordered[i]]!['drawn']}'),
                      ),
                      DataCell(
                        Text('${table[ordered[i]]!['lost']}'),
                      ),
                      DataCell(
                        Text('${table[ordered[i]]!['gd']}'),
                      ),
                      DataCell(
                        Text(
                          '${table[ordered[i]]!['points']}',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 15),
        const Text(
          'Only CONFIRMED matches count toward the table.',
          style: TextStyle(color: Colors.grey),
        ),
      ],
    );
  }
}

// ============================================================
// PROFILE
// ============================================================

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  Future<void> logout(BuildContext context) async {
    await Store.instance.logout();

    if (!context.mounted) return;

    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final player = Store.instance.current;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const CircleAvatar(
          radius: 45,
          child: Icon(Icons.person, size: 50),
        ),
        const SizedBox(height: 20),
        Center(
          child: Text(
            player?.gamerTag ?? '',
            style: const TextStyle(
              fontSize: 25,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Center(
          child: Text(
            player?.name ?? '',
            style: const TextStyle(color: Colors.grey),
          ),
        ),
        const SizedBox(height: 25),
        Card(
          child: ListTile(
            leading: const Icon(Icons.badge),
            title: const Text('Gamer Tag'),
            subtitle: Text(player?.gamerTag ?? ''),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.person),
            title: const Text('Full Name'),
            subtitle: Text(player?.name ?? ''),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.security),
            title: const Text('Account Role'),
            subtitle: Text(
              player?.admin == true
                  ? 'Administrator'
                  : 'Player',
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.bar_chart),
            title: const Text('My Stats & Match History'),
            subtitle: const Text('View your confirmed results and league statistics.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const PlayerStatsPage(),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: () => logout(context),
          icon: const Icon(Icons.logout),
          label: const Text('LOG OUT'),
        ),
      ],
    );
  }
}

// ============================================================
// PLAYER STATS & MATCH HISTORY
// ============================================================

class PlayerStatsPage extends StatelessWidget {
  const PlayerStatsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = Store.instance;
    final player = store.current;

    if (player == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('My Stats')),
        body: const Center(child: Text('No player is signed in.')),
      );
    }

    final stats = store.statsForPlayer(player.id);
    final history = store.confirmedMatchesForPlayer(player.id);

    return Scaffold(
      appBar: AppBar(title: const Text('My Stats & History')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Text(
              player.gamerTag,
              style: const TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 18),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.65,
            children: [
              _statCard('Played', stats['played']!),
              _statCard('Points', stats['points']!),
              _statCard('Wins', stats['won']!),
              _statCard('Draws', stats['drawn']!),
              _statCard('Losses', stats['lost']!),
              _statCard('Goals For', stats['gf']!),
              _statCard('Goals Against', stats['ga']!),
              _statCard('Goal Difference', stats['gd']!),
            ],
          ),
          const SizedBox(height: 25),
          const Text(
            'CONFIRMED MATCH HISTORY',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          if (history.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(18),
                child: Text(
                  'No confirmed matches yet.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            for (final match in history) _historyCard(store, player, match),
          const SizedBox(height: 12),
          const Text(
            'Only CONFIRMED matches are included in these statistics.',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }

  static Widget _statCard(String label, int value) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '$value',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(label, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  static Widget _historyCard(
    Store store,
    Player player,
    MatchItem match,
  ) {
    final isHome = match.homeId == player.id;
    final opponentId = isHome ? match.awayId : match.homeId;
    final opponent = store.playerName(opponentId);
    final homeScore = match.homeScore ?? 0;
    final awayScore = match.awayScore ?? 0;
    final myScore = isHome ? homeScore : awayScore;
    final opponentScore = isHome ? awayScore : homeScore;

    String result;
    IconData icon;
    if (myScore > opponentScore) {
      result = 'WIN';
      icon = Icons.emoji_events;
    } else if (myScore < opponentScore) {
      result = 'LOSS';
      icon = Icons.close;
    } else {
      result = 'DRAW';
      icon = Icons.remove;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: CircleAvatar(child: Icon(icon, size: 20)),
        title: Text(
          '${player.gamerTag} vs $opponent',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text('Matchday ${match.round} • $result'),
        trailing: Text(
          '$homeScore - $awayScore',
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

// ============================================================
// LEAGUE MANAGEMENT
// ============================================================

class LeagueManagementPage extends StatefulWidget {
  const LeagueManagementPage({super.key});

  @override
  State<LeagueManagementPage> createState() => _LeagueManagementPageState();
}

class _LeagueManagementPageState extends State<LeagueManagementPage> {
  final nameController = TextEditingController();
  bool loading = false;
  String? selectedLeagueId;
  Set<String> memberIds = {};

  Store get store => Store.instance;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    nameController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => loading = true);
    try {
      await store.refreshPlayers();
      await store.refreshLeagues();
      if (store.leagues.isNotEmpty) {
        selectedLeagueId ??= store.leagues.first.id;
        if (!store.leagues.any((l) => l.id == selectedLeagueId)) {
          selectedLeagueId = store.leagues.first.id;
        }
        memberIds = (await store.leagueMemberIds(selectedLeagueId!)).toSet();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Refresh error: $e')),
        );
      }
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _createLeague() async {
    final name = nameController.text.trim();
    if (name.isEmpty) return;
    setState(() => loading = true);
    final error = await store.createLeague(name);
    if (!mounted) return;
    if (error == null) {
      nameController.clear();
      await _refresh();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('League created.')),
      );
    } else {
      setState(() => loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
    }
  }

  Future<void> _changeStatus(String status) async {
    if (selectedLeagueId == null) return;
    setState(() => loading = true);
    final error = await store.setLeagueStatus(selectedLeagueId!, status);
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    }
    await _refresh();
  }

  Future<void> _selectLeague(String id) async {
    setState(() {
      selectedLeagueId = id;
      loading = true;
    });
    try {
      memberIds = (await store.leagueMemberIds(id)).toSet();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load members: $e')),
        );
      }
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _togglePlayer(Player player, bool selected) async {
    final leagueId = selectedLeagueId;
    if (leagueId == null) return;
    setState(() => loading = true);
    final error = selected
        ? await store.addLeagueMember(leagueId, player.id)
        : await store.removeLeagueMember(leagueId, player.id);
    if (error == null) {
      if (selected) {
        memberIds.add(player.id);
      } else {
        memberIds.remove(player.id);
      }
    }
    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    }
    setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final selectedList = store.leagues.where((l) => l.id == selectedLeagueId).toList();
    final selected = selectedList.isEmpty ? null : selectedList.first;
    final playerList = store.players.where((p) => !p.admin).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('League Management')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'CREATE NEW LEAGUE',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: nameController,
                    decoration: const InputDecoration(
                      labelText: 'League name',
                      hintText: 'e.g. CHIBBYBALL Season 1',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  height: 56,
                  child: FilledButton(
                    onPressed: loading ? null : _createLeague,
                    child: const Text('CREATE'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const Text(
              'LEAGUES',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            if (store.leagues.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(18),
                  child: Text('No leagues created yet.'),
                ),
              )
            else
              ...store.leagues.map(
                (league) => Card(
                  child: ListTile(
                    selected: league.id == selectedLeagueId,
                    onTap: () => _selectLeague(league.id),
                    leading: Icon(
                      league.status == 'active'
                          ? Icons.play_circle_fill
                          : league.status == 'completed'
                              ? Icons.check_circle
                              : Icons.lock_open,
                    ),
                    title: Text(league.name),
                    subtitle: Text('Status: ${league.status.toUpperCase()}'),
                    trailing: league.id == selectedLeagueId
                        ? const Icon(Icons.check)
                        : null,
                  ),
                ),
              ),
            if (selected != null) ...[
              const SizedBox(height: 18),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        selected.name,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text('Current status: ${selected.status.toUpperCase()}'),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: loading || selected.status == 'active'
                                ? null
                                : () => _changeStatus('active'),
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('ACTIVATE'),
                          ),
                          OutlinedButton.icon(
                            onPressed: loading || selected.status == 'completed'
                                ? null
                                : () => _changeStatus('completed'),
                            icon: const Icon(Icons.check),
                            label: const Text('COMPLETE'),
                          ),
                          OutlinedButton.icon(
                            onPressed: loading || selected.status == 'open'
                                ? null
                                : () => _changeStatus('open'),
                            icon: const Icon(Icons.lock_open),
                            label: const Text('REOPEN'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'PLAYERS (${memberIds.length})',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Card(
                child: Column(
                  children: playerList.map((player) {
                    final checked = memberIds.contains(player.id);
                    return CheckboxListTile(
                      value: checked,
                      onChanged: loading
                          ? null
                          : (value) => _togglePlayer(player, value == true),
                      title: Text(player.gamerTag),
                      subtitle: Text(player.name),
                      secondary: const Icon(Icons.person),
                    );
                  }).toList(),
                ),
              ),
              const SizedBox(height: 12),
              if (selected.status == 'active')
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(14),
                    child: Text(
                      'This is the active league. Add players here before generating fixtures.',
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

// ============================================================
// ADMIN
// ============================================================

class AdminPage extends StatefulWidget {
  const AdminPage({super.key});

  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  bool loading = false;

  Future<void> refresh() async {
    setState(() => loading = true);

    try {
      await Store.instance.refreshPlayers();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Refresh error: $e')),
        );
      }
    }

    if (mounted) setState(() => loading = false);
  }

  Future<void> generateFixtures() async {
    setState(() => loading = true);

    final error = await Store.instance.generateFixtures();

    if (!mounted) return;

    setState(() => loading = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          error ?? 'Fixtures saved to Supabase successfully.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = Store.instance;

    return Scaffold(
      appBar: AppBar(title: const Text('Admin Dashboard')),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'CHIBBYBALL ADMIN',
              style: TextStyle(
                fontSize: 25,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 18),
            Card(
              child: ListTile(
                leading: const Icon(Icons.people),
                title: const Text('Players'),
                trailing: Text(
                  '${store.players.where((p) => !p.admin).length}',
                ),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.sports_soccer),
                title: const Text('Fixtures'),
                trailing: Text('${store.matches.length}'),
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.check_circle),
                title: const Text('Confirmed Results'),
                trailing: Text(
                  '${store.confirmedMatches().length}',
                ),
              ),
            ),
            const SizedBox(height: 15),
            SizedBox(
              height: 50,
              child: FilledButton.icon(
                onPressed: loading
                    ? null
                    : () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const LeagueManagementPage(),
                          ),
                        ).then((_) async {
                          await store.refreshLeagues();
                          await store.loadMatchesFromSupabase();
                          if (mounted) setState(() {});
                        }),
                icon: const Icon(Icons.emoji_events),
                label: const Text('MANAGE LEAGUES'),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 50,
              child: FilledButton.icon(
                onPressed: loading ? null : refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('REFRESH PLAYERS'),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 50,
              child: FilledButton.icon(
                onPressed: loading ? null : generateFixtures,
                icon: const Icon(Icons.auto_awesome),
                label: const Text('GENERATE FIXTURES'),
              ),
            ),
            const SizedBox(height: 25),
            const Text(
              'REGISTERED PLAYERS',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            ...store.players
                .where((p) => !p.admin)
                .map(
                  (player) => Card(
                    child: ListTile(
                      leading: const CircleAvatar(
                        child: Icon(Icons.person),
                      ),
                      title: Text(player.gamerTag),
                      subtitle: Text(player.name),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
