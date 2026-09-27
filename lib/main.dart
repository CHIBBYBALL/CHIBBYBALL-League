import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'supabase_config.dart';
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: supabaseUrl,
    publishableKey: supabasePublishableKey,
  );

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
// CHIBBYBALL production build      
      home: const LoginPage(),
    );
  }
}

class Player {
  final String id;
  final String name;
  final String gamerTag;
  final String password;
  final bool admin;

  Player({
    required this.id,
    required this.name,
    required this.gamerTag,
    required this.password,
    this.admin = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'gamerTag': gamerTag,
        'password': password,
        'admin': admin,
      };

  factory Player.fromJson(Map<String, dynamic> j) => Player(
        id: j['id'],
        name: j['name'],
        gamerTag: j['gamerTag'],
        password: j['password'],
        admin: j['admin'] ?? false,
      );
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
    this.status = 'Pending',
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

  factory MatchItem.fromJson(Map<String, dynamic> j) => MatchItem(
        id: j['id'],
        homeId: j['homeId'],
        awayId: j['awayId'],
        round: j['round'],
        homeScore: j['homeScore'],
        awayScore: j['awayScore'],
        homeClaimHome: j['homeClaimHome'],
        homeClaimAway: j['homeClaimAway'],
        awayClaimHome: j['awayClaimHome'],
        awayClaimAway: j['awayClaimAway'],
        homeProof: j['homeProof'],
        awayProof: j['awayProof'],
        status: j['status'] ?? 'Pending',
      );
}

class Store {
  static final Store instance = Store._();
  Store._();

  final List<Player> players = [];
  final List<MatchItem> matches = [];

  Player? current;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    final p = prefs.getString('players');
    final m = prefs.getString('matches');

    if (p != null) {
      players
        ..clear()
        ..addAll(
          (jsonDecode(p) as List)
              .map((e) => Player.fromJson(e))
              .toList(),
        );
    }

    if (m != null) {
      matches
        ..clear()
        ..addAll(
          (jsonDecode(m) as List)
              .map((e) => MatchItem.fromJson(e))
              .toList(),
        );
    }

    if (players.isEmpty) {
      players.add(
        Player(
          id: 'admin',
          name: 'CHIBBYBALL Admin',
          gamerTag: 'CHIBBY_ADMIN',
          password: 'admin123',
          admin: true,
        ),
      );
      await save();
    }
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(
      'players',
      jsonEncode(players.map((e) => e.toJson()).toList()),
    );

    await prefs.setString(
      'matches',
      jsonEncode(matches.map((e) => e.toJson()).toList()),
    );
  }

  Player? findPlayer(String id) {
    try {
      return players.firstWhere((p) => p.id == id);
    } catch (_) {
      return null;
    }
  }

  String playerName(String id) {
    return findPlayer(id)?.gamerTag ?? 'Unknown Player';
  }

  Future<bool> register(
    String name,
    String gamerTag,
    String password,
  ) async {
    if (players.any(
      (p) => p.gamerTag.toLowerCase() == gamerTag.toLowerCase(),
    )) {
      return false;
    }

    players.add(
      Player(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: name,
        gamerTag: gamerTag,
        password: password,
      ),
    );

    await save();
    return true;
  }

  Player? login(String gamerTag, String password) {
    try {
      final p = players.firstWhere(
        (p) =>
            p.gamerTag.toLowerCase() == gamerTag.toLowerCase() &&
            p.password == password,
      );
      current = p;
      return p;
    } catch (_) {
      return null;
    }
  }

  void generateFixtures() {
    if (players.length < 3) return;

    matches.clear();

    final list = players.where((p) => !p.admin).toList();

    final ids = list.map((p) => p.id).toList();

    if (ids.length.isOdd) {
      ids.add('BYE');
    }

    final n = ids.length;
    final rounds = n - 1;

    final rotation = List<String>.from(ids);

    for (int r = 0; r < rounds; r++) {
      for (int i = 0; i < n ~/ 2; i++) {
        final a = rotation[i];
        final b = rotation[n - 1 - i];

        if (a == 'BYE' || b == 'BYE') continue;

        final home = r.isEven ? a : b;
        final away = r.isEven ? b : a;

        matches.add(
          MatchItem(
            id: '${r + 1}-$i-${DateTime.now().millisecondsSinceEpoch}',
            homeId: home,
            awayId: away,
            round: r + 1,
          ),
        );
      }

      rotation.insert(1, rotation.removeLast());
    }
  }

  MatchItem? matchForPlayer(String playerId) {
    try {
      return matches.firstWhere(
        (m) =>
            (m.homeId == playerId || m.awayId == playerId) &&
            m.status != 'Confirmed',
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> submitResult({
    required MatchItem match,
    required Player player,
    required int homeScore,
    required int awayScore,
    required String proofPath,
  }) async {
    if (player.id == match.homeId) {
      match.homeClaimHome = homeScore;
      match.homeClaimAway = awayScore;
      match.homeProof = proofPath;
    } else if (player.id == match.awayId) {
      match.awayClaimHome = homeScore;
      match.awayClaimAway = awayScore;
      match.awayProof = proofPath;
    }

    final bothSubmitted =
        match.homeProof != null && match.awayProof != null;

    if (bothSubmitted) {
      final sameScore =
          match.homeClaimHome == match.awayClaimHome &&
          match.homeClaimAway == match.awayClaimAway;

      if (sameScore) {
        match.homeScore = match.homeClaimHome;
        match.awayScore = match.homeClaimAway;
        match.status = 'Confirmed';
      } else {
        match.status = 'Disputed';
      }
    } else {
      match.status = 'Awaiting Confirmation';
    }

    await save();
  }

  List<MatchItem> confirmedMatches() {
    return matches.where((m) => m.status == 'Confirmed').toList();
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final tag = TextEditingController();
  final password = TextEditingController();

  @override
  void initState() {
    super.initState();
    Store.instance.load();
  }

  void login() {
    final p = Store.instance.login(
      tag.text.trim(),
      password.text,
    );

    if (p == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid gamer tag or password')),
      );
      return;
    }

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const HomePage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Icon(
                Icons.sports_esports,
                size: 80,
                color: Colors.blue,
              ),
              const SizedBox(height: 16),
              const Text(
                'CHIBBYBALL',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Text('eFootball League'),
              const SizedBox(height: 40),
              TextField(
                controller: tag,
                decoration: const InputDecoration(
                  labelText: 'Gamer Tag',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: login,
                  child: const Text('LOGIN'),
                ),
              ),
              TextButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const RegisterPage(),
                    ),
                  );
                },
                child: const Text('Create Player Account'),
              ),
              const SizedBox(height: 20),
              const Text(
                'Admin: CHIBBY_ADMIN / admin123',
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final name = TextEditingController();
  final tag = TextEditingController();
  final password = TextEditingController();

  Future<void> register() async {
    if (name.text.trim().isEmpty ||
        tag.text.trim().isEmpty ||
        password.text.isEmpty) {
      return;
    }

    final ok = await Store.instance.register(
      name.text.trim(),
      tag.text.trim(),
      password.text,
    );

    if (!mounted) return;

    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Gamer tag already exists')),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Registration successful')),
    );

    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Player Registration')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: name,
            decoration: const InputDecoration(
              labelText: 'Full Name',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: tag,
            decoration: const InputDecoration(
              labelText: 'Unique Gamer Tag',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: password,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Password',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 22),
          FilledButton(
            onPressed: register,
            child: const Text('REGISTER'),
          ),
        ],
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int page = 0;

  @override
  Widget build(BuildContext context) {
    final current = Store.instance.current;

    final pages = [
      const DashboardPage(),
      const FixturesPage(),
      const TablePage(),
      const ProfilePage(),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('CHIBBYBALL League'),
        actions: [
          if (current?.admin == true)
            IconButton(
              icon: const Icon(Icons.admin_panel_settings),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const AdminPage(),
                  ),
                );
              },
            ),
        ],
      ),
      body: pages[page],
      bottomNavigationBar: NavigationBar(
        selectedIndex: page,
        onDestinationSelected: (i) {
          setState(() => page = i);
        },
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

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Store.instance;
    final p = s.current;

    final myMatches = p == null
        ? <MatchItem>[]
        : s.matches
            .where((m) => m.homeId == p.id || m.awayId == p.id)
            .toList();

    final confirmed = myMatches.where(
      (m) => m.status == 'Confirmed',
    );

    return ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Text(
          'Welcome, ${p?.gamerTag ?? ''}',
          style: const TextStyle(
            fontSize: 25,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 20),
        Card(
          child: ListTile(
            leading: const Icon(Icons.sports_esports),
            title: const Text('Your Matches'),
            subtitle: Text('${myMatches.length} fixtures'),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.check_circle),
            title: const Text('Confirmed Results'),
            subtitle: Text('${confirmed.length} confirmed'),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.photo),
            title: const Text('Result Proof'),
            subtitle: const Text(
              'Both players must submit screenshot proof.',
            ),
          ),
        ),
      ],
    );
  }
}

class FixturesPage extends StatefulWidget {
  const FixturesPage({super.key});

  @override
  State<FixturesPage> createState() => _FixturesPageState();
}

class _FixturesPageState extends State<FixturesPage> {
  @override
  Widget build(BuildContext context) {
    final s = Store.instance;

    if (s.matches.isEmpty) {
      return Center(
        child: FilledButton.icon(
          icon: const Icon(Icons.auto_awesome),
          label: const Text('Generate Fixtures'),
          onPressed: () async {
            s.generateFixtures();
            await s.save();
            setState(() {});
          },
        ),
      );
    }

    final rounds = s.matches.map((m) => m.round).toSet().toList()
      ..sort();

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final round in rounds) ...[
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(
              'MATCHDAY $round',
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ...s.matches
              .where((m) => m.round == round)
              .map(
                (m) => Card(
                  child: ListTile(
                    title: Text(
                      '${s.playerName(m.homeId)}  vs  ${s.playerName(m.awayId)}',
                    ),
                    subtitle: Text(
                      m.status == 'Confirmed'
                          ? '${m.homeScore} - ${m.awayScore}'
                          : m.status,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ResultPage(match: m),
                        ),
                      ).then((_) => setState(() {}));
                    },
                  ),
                ),
              ),
        ],
      ],
    );
  }
}

class ResultPage extends StatefulWidget {
  final MatchItem match;

  const ResultPage({
    super.key,
    required this.match,
  });

  @override
  State<ResultPage> createState() => _ResultPageState();
}

class _ResultPageState extends State<ResultPage> {
  final home = TextEditingController();
  final away = TextEditingController();

  File? proof;
  bool loading = false;

  Future<void> pickProof() async {
    final picker = ImagePicker();

    final image = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 70,
    );

    if (image != null) {
      setState(() {
        proof = File(image.path);
      });
    }
  }

  Future<void> submit() async {
    final player = Store.instance.current;

    if (player == null) return;

    final h = int.tryParse(home.text);
    final a = int.tryParse(away.text);

    if (h == null || a == null || proof == null) {
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

    await Store.instance.submitResult(
      match: widget.match,
      player: player,
      homeScore: h,
      awayScore: a,
      proofPath: proof!.path,
    );

    if (!mounted) return;

    setState(() => loading = false);

    final status = widget.match.status;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Result status: $status')),
    );

    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.match;
    final s = Store.instance;

    final isHome = s.current?.id == m.homeId;

    return Scaffold(
      appBar: AppBar(title: const Text('Submit Result')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            '${s.playerName(m.homeId)} vs ${s.playerName(m.awayId)}',
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text('Current status: ${m.status}'),
          const SizedBox(height: 24),
          TextField(
            controller: home,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText:
                  '${s.playerName(m.homeId)} score',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: away,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText:
                  '${s.playerName(m.awayId)} score',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: pickProof,
            icon: const Icon(Icons.photo_library),
            label: Text(
              proof == null
                  ? 'Choose Screenshot Proof'
                  : 'Screenshot Selected',
            ),
          ),
          if (proof != null) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 180,
              child: Image.file(
                proof!,
                fit: BoxFit.contain,
              ),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: loading ? null : submit,
            icon: const Icon(Icons.send),
            label: Text(
              isHome
                  ? 'Submit My Home Result'
                  : 'Submit My Away Result',
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'IMPORTANT\n'
            'The match will NOT enter the league table until BOTH '
            'players submit screenshot proof. If both players submit '
            'different scores, the match becomes DISPUTED for admin review.',
            style: TextStyle(color: Colors.orange),
          ),
        ],
      ),
    );
  }
}

class TablePage extends StatelessWidget {
  const TablePage({super.key});

  @override
  Widget build(BuildContext context) {
    final s = Store.instance;
    final players = s.players.where((p) => !p.admin).toList();

    final stats = <String, Map<String, int>>{};

    for (final p in players) {
      stats[p.id] = {
        'p': 0,
        'w': 0,
        'd': 0,
        'l': 0,
        'gf': 0,
        'ga': 0,
        'gd': 0,
        'pts': 0,
      };
    }

    for (final m in s.confirmedMatches()) {
      final h = stats[m.homeId];
      final a = stats[m.awayId];

      if (h == null || a == null) continue;

      final hs = m.homeScore!;
      final as = m.awayScore!;

      h['p'] = h['p']! + 1;
      a['p'] = a['p']! + 1;

      h['gf'] = h['gf']! + hs;
      h['ga'] = h['ga']! + as;

      a['gf'] = a['gf']! + as;
      a['ga'] = a['ga']! + hs;

      if (hs > as) {
        h['w'] = h['w']! + 1;
        a['l'] = a['l']! + 1;
        h['pts'] = h['pts']! + 3;
      } else if (as > hs) {
        a['w'] = a['w']! + 1;
        h['l'] = h['l']! + 1;
        a['pts'] = a['pts']! + 3;
      } else {
        h['d'] = h['d']! + 1;
        a['d'] = a['d']! + 1;
        h['pts'] = h['pts']! + 1;
        a['pts'] = a['pts']! + 1;
      }
    }

    for (final x in stats.values) {
      x['gd'] = x['gf']! - x['ga']!;
    }

    players.sort((a, b) {
      final x = stats[a.id]!;
      final y = stats[b.id]!;

      final points = y['pts']!.compareTo(x['pts']!);
      if (points != 0) return points;

      final gd = y['gd']!.compareTo(x['gd']!);
      if (gd != 0) return gd;

      return y['gf']!.compareTo(x['gf']!);
    });

    return ListView(
      padding: const EdgeInsets.all(10),
      children: [
        const Padding(
          padding: EdgeInsets.all(8),
          child: Text(
            'LEAGUE TABLE',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('#')),
              DataColumn(label: Text('Player')),
              DataColumn(label: Text('P')),
              DataColumn(label: Text('W')),
              DataColumn(label: Text('D')),
              DataColumn(label: Text('L')),
              DataColumn(label: Text('GD')),
              DataColumn(label: Text('PTS')),
            ],
            rows: [
              for (int i = 0; i < players.length; i++)
                DataRow(
                  cells: [
                    DataCell(Text('${i + 1}')),
                    DataCell(Text(players[i].gamerTag)),
                    DataCell(Text('${stats[players[i].id]!['p']}')),
                    DataCell(Text('${stats[players[i].id]!['w']}')),
                    DataCell(Text('${stats[players[i].id]!['d']}')),
                    DataCell(Text('${stats[players[i].id]!['l']}')),
                    DataCell(Text('${stats[players[i].id]!['gd']}')),
                    DataCell(Text('${stats[players[i].id]!['pts']}')),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Store.instance.current;

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
            p?.gamerTag ?? '',
            style: const TextStyle(
              fontSize: 25,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(height: 10),
        Center(child: Text(p?.name ?? '')),
        const SizedBox(height: 25),
        Card(
          child: ListTile(
            leading: const Icon(Icons.lock),
            title: const Text('Gamer Tag'),
            subtitle: const Text(
              'Locked after registration',
            ),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.verified),
            title: const Text('Account'),
            subtitle: Text(
              p?.admin == true ? 'Administrator' : 'Player',
            ),
          ),
        ),
        const SizedBox(height: 20),
        FilledButton.tonal(
          onPressed: () {
            Store.instance.current = null;
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(
                builder: (_) => const LoginPage(),
              ),
              (_) => false,
            );
          },
          child: const Text('LOG OUT'),
        ),
      ],
    );
  }
}

class AdminPage extends StatefulWidget {
  const AdminPage({super.key});

  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  @override
  Widget build(BuildContext context) {
    final s = Store.instance;

    final disputed =
        s.matches.where((m) => m.status == 'Disputed').toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Dashboard'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.people),
              title: const Text('Registered Players'),
              subtitle: Text(
                '${s.players.where((p) => !p.admin).length}',
              ),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.sports_soccer),
              title: const Text('Fixtures'),
              subtitle: Text('${s.matches.length}'),
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(
                Icons.warning,
                color: Colors.orange,
              ),
              title: const Text('Disputed Results'),
              subtitle: Text('${disputed.length}'),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () async {
              s.generateFixtures();
              await s.save();
              setState(() {});
            },
            icon: const Icon(Icons.refresh),
            label: const Text('Generate New Fixtures'),
          ),
          const SizedBox(height: 20),
          for (final m in disputed)
            Card(
              child: ListTile(
                title: Text(
                  '${s.playerName(m.homeId)} vs ${s.playerName(m.awayId)}',
                ),
                subtitle: Text(
                  'Player 1: ${m.homeClaimHome}-${m.homeClaimAway}\n'
                  'Player 2: ${m.awayClaimHome}-${m.awayClaimAway}',
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.restart_alt),
                  onPressed: () async {
                    m.homeClaimHome = null;
                    m.homeClaimAway = null;
                    m.awayClaimHome = null;
                    m.awayClaimAway = null;
                    m.homeProof = null;
                    m.awayProof = null;
                    m.status = 'Pending';
                    await s.save();
                    setState(() {});
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}
