import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_config.dart';

Future<FirebaseApp>? _firebaseInitialization;


class ScreenshotCheck {
  final bool valid;
  final bool hasFullTime;
  final int? scoreA;
  final int? scoreB;
  final String text;
  final String reason;
  final Set<String> tokens;

  const ScreenshotCheck({
    required this.valid,
    required this.hasFullTime,
    required this.scoreA,
    required this.scoreB,
    required this.text,
    required this.reason,
    required this.tokens,
  });
}

Set<String> _meaningfulOcrTokens(String text) {
  const ignored = {
    'full', 'time', 'score', 'goal', 'goals', 'match', 'home', 'away',
    'online', 'efootball', 'konami', 'game', 'pause', 'settings', 'resume',
    'minutes', 'minute', 'player', 'players', 'result', 'final', 'ft',
  };
  return text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
      .split(RegExp(r'\s+'))
      .where((t) => t.length >= 4 && !ignored.contains(t))
      .toSet();
}

Future<ScreenshotCheck> analyzeResultScreenshot(
  File file,
  int claimedHome,
  int claimedAway,
) async {
  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  try {
    final image = InputImage.fromFilePath(file.path);
    final recognized = await recognizer.processImage(image);
    final raw = recognized.text;
    final text = raw.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

    final hasFullTime = RegExp(r'\bfull\s*time\b').hasMatch(text) ||
        RegExp(r'(?<![a-z])ft(?![a-z])').hasMatch(text);

    final normalized = text.replaceAll('—', '-').replaceAll('–', '-');
    final scoreRegex = RegExp(r'(?<!\d)(\d{1,2})\s*[-:]\s*(\d{1,2})(?!\d)');
    final fullTimeIndex = text.indexOf('full time');
    final window = fullTimeIndex >= 0
        ? normalized.substring(
            (fullTimeIndex - 100).clamp(0, normalized.length),
            (fullTimeIndex + 140).clamp(0, normalized.length),
          )
        : normalized;

    final matches = scoreRegex.allMatches(window).toList();
    RegExpMatch? chosen;
    if (matches.isNotEmpty) {
      chosen = matches.first;
    } else {
      final all = scoreRegex.allMatches(normalized).toList();
      if (all.isNotEmpty) chosen = all.first;
    }

    final a = chosen == null ? null : int.tryParse(chosen.group(1)!);
    final b = chosen == null ? null : int.tryParse(chosen.group(2)!);

    if (!hasFullTime) {
      return ScreenshotCheck(
        valid: false,
        hasFullTime: false,
        scoreA: a,
        scoreB: b,
        text: raw,
        reason: 'Screenshot does not show Full Time.',
        tokens: _meaningfulOcrTokens(raw),
      );
    }

    if (a == null || b == null) {
      return ScreenshotCheck(
        valid: false,
        hasFullTime: true,
        scoreA: a,
        scoreB: b,
        text: raw,
        reason: 'Could not read the final score from the screenshot.',
        tokens: _meaningfulOcrTokens(raw),
      );
    }

    final scoreMatches = (a == claimedHome && b == claimedAway) ||
        (a == claimedAway && b == claimedHome);

    return ScreenshotCheck(
      valid: scoreMatches,
      hasFullTime: true,
      scoreA: a,
      scoreB: b,
      text: raw,
      reason: scoreMatches
          ? 'Full Time and score verified.'
          : 'Screenshot score does not match the submitted score.',
      tokens: _meaningfulOcrTokens(raw),
    );
  } finally {
    await recognizer.close();
  }
}

Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Start Firebase without blocking the first screen, but keep the same
  // initialization Future so login/register can safely wait for it.
  _firebaseInitialization ??= Firebase.initializeApp();
  _firebaseInitialization!.then((_) {
    FirebaseMessaging.onBackgroundMessage(
      _firebaseMessagingBackgroundHandler,
    );
  }).catchError((e) {
    debugPrint('Firebase initialization failed: $e');
  });

  // Supabase is required by the login/register actions, so initialize it
  // before showing the main app.
  await Supabase.initialize(
    url: supabaseUrl,
    publishableKey: supabasePublishableKey,
  );

  // Load cached/server data without blocking the first screen.
  Store.instance.load().catchError((e) {
    debugPrint('Store load failed: $e');
  });

  runApp(const ChibbyballApp());
}

class _ChibbyballBackgroundPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final bg = Paint()..shader = const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF02050B), Color(0xFF071225), Color(0xFF02040A)],
    ).createShader(rect);
    canvas.drawRect(rect, bg);

    void stroke(List<Offset> points, Color color, double width) {
      final paint = Paint()
        ..color = color
        ..strokeWidth = width
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7);
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (var i = 1; i < points.length; i++) {
        path.lineTo(points[i].dx, points[i].dy);
      }
      canvas.drawPath(path, paint);
    }

    stroke([Offset(-80, size.height * .18), Offset(size.width * .42, -20)], const Color(0x55008CFF), 26);
    stroke([Offset(size.width * .58, -30), Offset(size.width + 80, size.height * .18)], const Color(0x443B5CFF), 22);
    stroke([Offset(-70, size.height * .86), Offset(size.width * .42, size.height * .55)], const Color(0x3322C8FF), 18);
    stroke([Offset(size.width * .55, size.height * .96), Offset(size.width + 70, size.height * .72)], const Color(0x44FFC400), 15);

    final blueGlow = Paint()..color = const Color(0x2200C8FF)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 45);
    canvas.drawCircle(Offset(size.width * .12, size.height * .28), 75, blueGlow);
    final yellowGlow = Paint()..color = const Color(0x18FFD000)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 50);
    canvas.drawCircle(Offset(size.width * .9, size.height * .72), 90, yellowGlow);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class ChibbyballApp extends StatelessWidget {
  const ChibbyballApp({super.key});

  @override
  Widget build(BuildContext context) {
    const cyan = Color(0xFF00D9FF);
    const purple = Color(0xFF8B3DFF);
    const yellow = Color(0xFFFFD21F);
    final base = ThemeData.dark(useMaterial3: true);

    return MaterialApp(
      title: 'CHIBBYBALL League',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        textTheme: base.textTheme,
        scaffoldBackgroundColor: Colors.transparent,
        colorScheme: ColorScheme.fromSeed(
          seedColor: cyan,
          brightness: Brightness.dark,
          primary: cyan,
          secondary: purple,
          tertiary: yellow,
          surface: const Color(0xFF09101E),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xCC02050B),
          foregroundColor: Colors.white,
          elevation: 0,
          titleTextStyle: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: .6),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xE6091221),
          elevation: 10,
          shadowColor: Color(0x6600C8FF),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: Color(0x6600C8FF))),
          margin: EdgeInsets.symmetric(vertical: 7),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xE6091221),
          labelStyle: const TextStyle(color: Color(0xFFB9C7DA)),
          prefixIconColor: cyan,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0x6600C8FF))),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0x6600C8FF))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: cyan, width: 2)),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: cyan,
            foregroundColor: const Color(0xFF001018),
            minimumSize: const Size.fromHeight(54),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            textStyle: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: .7),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(foregroundColor: cyan, side: const BorderSide(color: cyan, width: 1.4), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Color(0xF2080D17),
          indicatorColor: Color(0x4428DFFF),
          labelTextStyle: WidgetStatePropertyAll(TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
        ),
        dividerTheme: const DividerThemeData(color: Color(0x3322BFFF)),
        snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating, backgroundColor: Color(0xFF101C2D)),
      ),
      builder: (context, child) => Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: _ChibbyballBackgroundPainter())),
          if (child != null) child,
        ],
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
  final String phoneNumber;
  final String country;
  final String countryCode;
  final String whatsappNumber;
  final DateTime? lastSeen;
  final bool isOnline;
  final String avatarUrl;

  const Player({
    required this.id,
    required this.name,
    required this.gamerTag,
    this.admin = false,
    this.phoneNumber = '',
    this.country = '',
    this.countryCode = '',
    this.whatsappNumber = '',
    this.lastSeen,
    this.isOnline = false,
    this.avatarUrl = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'gamerTag': gamerTag,
        'admin': admin,
        'phoneNumber': phoneNumber,
        'country': country,
        'countryCode': countryCode,
        'whatsappNumber': whatsappNumber,
        'lastSeen': lastSeen?.toIso8601String(),
        'isOnline': isOnline,
        'avatarUrl': avatarUrl,
      };

  factory Player.fromJson(Map<String, dynamic> json) => Player(
        id: json['id']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        gamerTag: json['gamerTag']?.toString() ?? '',
        admin: json['admin'] == true,
        phoneNumber: json['phoneNumber']?.toString() ?? '',
        country: json['country']?.toString() ?? '',
        countryCode: json['countryCode']?.toString() ?? '',
        whatsappNumber: json['whatsappNumber']?.toString() ?? '',
        lastSeen: json['lastSeen'] == null
            ? null
            : DateTime.tryParse(json['lastSeen'].toString()),
        isOnline: json['isOnline'] == true,
        avatarUrl: json['avatarUrl']?.toString() ?? '',
      );
}


class MessageItem {
  final String id;
  final String senderId;
  final String recipientId;
  final String body;
  final DateTime createdAt;
  final bool isRead;

  const MessageItem({
    required this.id,
    required this.senderId,
    required this.recipientId,
    required this.body,
    required this.createdAt,
    required this.isRead,
  });

  factory MessageItem.fromJson(Map<String, dynamic> row) => MessageItem(
    id: row['id'].toString(),
    senderId: row['sender_id'].toString(),
    recipientId: row['recipient_id'].toString(),
    body: row['body']?.toString() ?? '',
    createdAt: DateTime.tryParse(row['created_at']?.toString() ?? '') ?? DateTime.now(),
    isRead: row['is_read'] == true,
  );
}

class NotificationItem {
  final String id;
  final String? leagueId;
  final String? matchId;
  final String type;
  final String title;
  final String message;
  final bool isRead;
  final DateTime createdAt;

  const NotificationItem({
    required this.id,
    this.leagueId,
    this.matchId,
    required this.type,
    required this.title,
    required this.message,
    required this.isRead,
    required this.createdAt,
  });

  factory NotificationItem.fromJson(Map<String, dynamic> row) {
    return NotificationItem(
      id: row['id'].toString(),
      leagueId: row['league_id']?.toString(),
      matchId: row['match_id']?.toString(),
      type: row['type']?.toString() ?? 'general',
      title: row['title']?.toString() ?? 'Notification',
      message: row['message']?.toString() ?? '',
      isRead: row['is_read'] == true,
      createdAt: DateTime.tryParse(row['created_at']?.toString() ?? '') ?? DateTime.now(),
    );
  }
}

class LeagueInfo {
  final String id;
  final String name;
  final String status;
  final bool isPaid;
  final double entryFee;
  final String currency;
  final DateTime? createdAt;
  const LeagueInfo({required this.id, required this.name, required this.status, this.isPaid = false, this.entryFee = 0, this.currency = 'NGN', this.createdAt});
  String get feeLabel => isPaid ? '$currency ${entryFee.toStringAsFixed(0)} entry fee' : 'FREE ENTRY';
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
  String? scheduledDate;
  String startTime;
  String endTime;
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
    this.scheduledDate,
    this.startTime = '17:00:00',
    this.endTime = '23:59:00',
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
        'scheduledDate': scheduledDate,
        'startTime': startTime,
        'endTime': endTime,
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
        scheduledDate: json['scheduledDate']?.toString(),
        startTime: json['startTime']?.toString() ?? '17:00:00',
        endTime: json['endTime']?.toString() ?? '23:59:00',
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
        .select('id, name, status, is_paid, entry_fee, currency, created_at')
        .order('created_at', ascending: false);

    leagues
      ..clear()
      ..addAll((data as List).map((item) {
        final row = Map<String, dynamic>.from(item);
        return LeagueInfo(
          id: row['id'].toString(),
          name: row['name']?.toString() ?? '',
          status: row['status']?.toString() ?? 'open',
          isPaid: row['is_paid'] == true,
          entryFee: (row['entry_fee'] as num?)?.toDouble() ?? 0,
          currency: row['currency']?.toString() ?? 'NGN',
          createdAt: row['created_at'] == null
              ? null
              : DateTime.tryParse(row['created_at'].toString()),
        );
      }));

    // Multiple leagues can be ACTIVE at the same time. Keep the currently
    // selected league when it still exists; otherwise select the first active
    // league (or the first league if none are active).
    final active = leagues.where((l) => l.status == 'active').toList();
    final selectedStillExists = activeLeagueId != null &&
        leagues.any((l) => l.id == activeLeagueId);

    if (!selectedStillExists) {
      final fallback = active.isNotEmpty ? active.first : (leagues.isNotEmpty ? leagues.first : null);
      activeLeagueId = fallback?.id;
    }

    final selected = activeLeagueId == null
        ? null
        : leagues.where((l) => l.id == activeLeagueId).firstOrNull;

    activeLeagueName = selected?.name;
    activeLeagueStatus = selected?.status;
    if (activeLeagueId != null) {
      try {
        activeLeagueMemberIds = (await leagueMemberIds(activeLeagueId!)).toSet();
      } catch (_) {
        activeLeagueMemberIds = {};
      }
    } else {
      activeLeagueMemberIds = {};
    }
  }

  Future<String?> _activeLeagueId() async {
    if (activeLeagueId != null) return activeLeagueId;
    await refreshLeagues();
    return activeLeagueId;
  }

  Future<String?> selectLeague(String leagueId) async {
    final league = leagues.where((l) => l.id == leagueId).firstOrNull;
    if (league == null) return 'League not found.';

    activeLeagueId = league.id;
    activeLeagueName = league.name;
    activeLeagueStatus = league.status;
    try {
      activeLeagueMemberIds = (await leagueMemberIds(league.id)).toSet();
      await loadMatchesFromSupabase();
      return null;
    } catch (e) {
      return 'Could not load league: $e';
    }
  }

  Future<String?> createLeague(String name, {required bool isPaid, required double entryFee, String currency = 'NGN'}) async {
    final clean = name.trim();
    if (clean.isEmpty) return 'League name is required.';
    if (Store.instance.current?.admin != true) return 'Admin access required.';
    if (isPaid && entryFee <= 0) return 'Enter a valid entry fee for a paid league.';
    if (!isPaid) entryFee = 0;
    try {
      await supabase.from('leagues').insert({'name': clean, 'status': 'open', 'is_paid': isPaid, 'entry_fee': entryFee, 'currency': currency});
      await refreshLeagues();
      return null;
    } on PostgrestException catch (e) { return 'Could not create league: ${e.message}'; }
      catch (e) { return 'Could not create league: $e'; }
  }

  Future<String?> setLeagueStatus(String leagueId, String status) async {
    if (Store.instance.current?.admin != true) return 'Admin access required.';
    try {
      // Multiple leagues are allowed to be ACTIVE at the same time.
      // Activating this league must never deactivate another league.
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

  Future<String?> disregisterPlayerFromAllLeagues(String playerId) async {
    if (Store.instance.current?.admin != true) return 'Admin access required.';
    try {
      await supabase.from('league_members').delete().eq('player_id', playerId);
      return null;
    } on PostgrestException catch (e) {
      return 'Could not disregister player: ${e.message}';
    } catch (e) {
      return 'Could not disregister player: $e';
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
          'id, round, home_player_id, away_player_id, status, home_score, away_score, scheduled_date, match_start_time, match_end_time',
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
          scheduledDate: row['scheduled_date']?.toString(),
          startTime: row['match_start_time']?.toString() ?? '17:00:00',
          endTime: row['match_end_time']?.toString() ?? '23:59:00',
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

  Future<void> setPresence(bool online) async {
    final player = current;
    if (player == null) return;
    final now = DateTime.now().toUtc();
    try {
      await supabase.from('profiles').update({
        'is_online': online,
        'last_seen': now.toIso8601String(),
      }).eq('id', player.id);
      final updated = Player(
        id: player.id, name: player.name, gamerTag: player.gamerTag, admin: player.admin,
        phoneNumber: player.phoneNumber, country: player.country, countryCode: player.countryCode,
        whatsappNumber: player.whatsappNumber, lastSeen: now, isOnline: online, avatarUrl: player.avatarUrl,
      );
      current = updated;
      final index = players.indexWhere((p) => p.id == player.id);
      if (index >= 0) players[index] = updated;
    } catch (e) {
      debugPrint('Presence update failed: $e');
    }
  }

  Future<List<MessageItem>> fetchConversation(String otherPlayerId) async {
    final me = current?.id;
    if (me == null) return [];
    final data = await supabase.from('messages').select(
      'id, sender_id, recipient_id, body, created_at, is_read',
    ).or(
      'and(sender_id.eq.$me,recipient_id.eq.$otherPlayerId),and(sender_id.eq.$otherPlayerId,recipient_id.eq.$me)',
    ).order('created_at');
    final list = (data as List).map((e) => MessageItem.fromJson(Map<String,dynamic>.from(e))).toList();
    try {
      await supabase.from('messages').update({'is_read': true}).eq('sender_id', otherPlayerId).eq('recipient_id', me).eq('is_read', false);
    } catch (_) {}
    return list;
  }

  Future<String?> sendMessage(String recipientId, String body) async {
    final me = current?.id;
    final clean = body.trim();
    if (me == null) return 'Please log in again.';
    if (clean.isEmpty) return 'Message cannot be empty.';
    try {
      await supabase.from('messages').insert({
        'sender_id': me,
        'recipient_id': recipientId,
        'body': clean,
      });
      return null;
    } on PostgrestException catch (e) {
      return 'Could not send message: ${e.message}';
    } catch (e) {
      return 'Could not send message: $e';
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

  Future<void> registerFcmToken() async {
    final player = current;
    if (player == null || !Platform.isAndroid) return;

    try {
      // Firebase is started in the background at app launch. Wait for that
      // same initialization here so login cannot race Firebase startup.
      _firebaseInitialization ??= Firebase.initializeApp();
      await _firebaseInitialization;

      final messaging = FirebaseMessaging.instance;

      await messaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );

      final token = await messaging.getToken();

      if (token != null && token.isNotEmpty) {
        await supabase
            .from('profiles')
            .update({'fcm_token': token})
            .eq('id', player.id);

        debugPrint('FCM token saved for player ${player.id}');
      } else {
        debugPrint('FCM getToken returned no token');
      }

      FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
        final signedInPlayer = current;
        if (signedInPlayer == null || newToken.isEmpty) return;

        try {
          await supabase
              .from('profiles')
              .update({'fcm_token': newToken})
              .eq('id', signedInPlayer.id);
        } catch (e) {
          debugPrint('FCM token refresh save failed: $e');
        }
      });
    } catch (e) {
      debugPrint('FCM token registration failed: $e');
    }
  }

  Future<void> refreshPlayers() async {
    final data = await supabase
        .from('profiles')
        .select('id, full_name, gamer_tag, role, phone_number, country, country_code, whatsapp_number, avatar_url, last_seen, is_online, created_at')
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
            phoneNumber: row['phone_number']?.toString() ?? '',
            country: row['country']?.toString() ?? '',
            countryCode: row['country_code']?.toString() ?? '',
            whatsappNumber: row['whatsapp_number']?.toString() ?? '',
            lastSeen: row['last_seen'] == null
                ? null
                : DateTime.tryParse(row['last_seen'].toString()),
            isOnline: row['is_online'] == true,
            avatarUrl: row['avatar_url']?.toString() ?? '',
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
              .select('id, full_name, gamer_tag, role, phone_number, country, country_code, whatsapp_number, last_seen, is_online')
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
        phoneNumber: profile['phone_number']?.toString() ?? '',
        country: profile['country']?.toString() ?? '',
        countryCode: profile['country_code']?.toString() ?? '',
        whatsappNumber: profile['whatsapp_number']?.toString() ?? '',
        lastSeen: profile['last_seen'] == null
            ? null
            : DateTime.tryParse(profile['last_seen'].toString()),
        isOnline: profile['is_online'] == true,
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

      if (response.session != null) {
        await registerFcmToken();
        await setPresence(true);
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
          .select('id, full_name, gamer_tag, role, phone_number, country, country_code, whatsapp_number, last_seen, is_online')
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
        phoneNumber: profile['phone_number']?.toString() ?? '',
        country: profile['country']?.toString() ?? '',
        countryCode: profile['country_code']?.toString() ?? '',
        whatsappNumber: profile['whatsapp_number']?.toString() ?? '',
        lastSeen: profile['last_seen'] == null
            ? null
            : DateTime.tryParse(profile['last_seen'].toString()),
        isOnline: profile['is_online'] == true,
      );

      try {
        await refreshPlayers();
        await refreshLeagues();
        await loadMatchesFromSupabase();
      } catch (_) {}

      await registerFcmToken();

      return current;
    } catch (_) {
      return null;
    }
  }

  Future<List<NotificationItem>> fetchNotifications({int limit = 100}) async {
    final player = current;
    if (player == null) return [];

    final data = await supabase
        .from('notifications')
        .select('id, league_id, match_id, type, title, message, is_read, created_at')
        .eq('player_id', player.id)
        .order('created_at', ascending: false)
        .limit(limit);

    return (data as List)
        .map((e) => NotificationItem.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<int> unreadNotificationCount() async {
    final player = current;
    if (player == null) return 0;

    final data = await supabase
        .from('notifications')
        .select('id')
        .eq('player_id', player.id)
        .eq('is_read', false);

    return (data as List).length;
  }

  Future<String?> markNotificationRead(String notificationId) async {
    final player = current;
    if (player == null) return 'No player is signed in.';

    try {
      await supabase
          .from('notifications')
          .update({'is_read': true})
          .eq('id', notificationId)
          .eq('player_id', player.id);
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> markAllNotificationsRead() async {
    final player = current;
    if (player == null) return 'No player is signed in.';

    try {
      await supabase
          .from('notifications')
          .update({'is_read': true})
          .eq('player_id', player.id)
          .eq('is_read', false);
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }

  Future<String?> uploadMyAvatar(XFile file) async {
    final player = current;
    if (player == null) return 'No player is signed in.';

    try {
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return 'The selected image is empty.';

      final originalName = file.name.toLowerCase();
      String extension = 'jpg';
      if (originalName.endsWith('.png')) extension = 'png';
      if (originalName.endsWith('.webp')) extension = 'webp';
      final contentType = extension == 'png'
          ? 'image/png'
          : extension == 'webp'
              ? 'image/webp'
              : 'image/jpeg';

      final path = '${player.id}/avatar.$extension';
      await supabase.storage.from('avatars').upload(
        path,
        bytes,
        fileOptions: FileOptions(
          contentType: contentType,
          upsert: true,
        ),
      );

      final publicUrl = supabase.storage.from('avatars').getPublicUrl(path);
      await supabase
          .from('profiles')
          .update({'avatar_url': publicUrl})
          .eq('id', player.id);

      await refreshPlayers();
      current = findPlayer(player.id);
      await save();
      return null;
    } on StorageException catch (e) {
      return 'Could not upload profile photo: ${e.message}';
    } on PostgrestException catch (e) {
      return 'Could not save profile photo: ${e.message}';
    } catch (e) {
      return 'Could not upload profile photo: $e';
    }
  }

  Future<String?> updateMyProfile({
    required String phoneNumber,
    required String country,
    required String countryCode,
    required String whatsappNumber,
    String? avatarUrl,
  }) async {
    final player = current;
    if (player == null) return 'No player is signed in.';

    try {
      final updated = {
        'phone_number': phoneNumber.trim(),
        'country': country.trim(),
        'country_code': countryCode.trim(),
        'whatsapp_number': whatsappNumber.trim(),
      };

      if (avatarUrl != null) {
        updated['avatar_url'] = avatarUrl;
      }

      await supabase.from('profiles').update(updated).eq('id', player.id);

      await refreshPlayers();
      current = findPlayer(player.id);
      await save();
      return null;
    } on PostgrestException catch (e) {
      return 'Could not save profile: ${e.message}';
    } catch (e) {
      return 'Could not save profile: $e';
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
      return 'No league selected.';
    }

    final league = leagues.where((l) => l.id == leagueId).firstOrNull;
    if (league == null || league.status != 'active') {
      return 'Select an ACTIVE league before generating fixtures.';
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
          'match_start_time': '17:00:00',
          'match_end_time': '23:59:00',
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


  Future<String?> updateLeagueMatchSchedule({
    required String leagueId,
    required String? scheduledDate,
    required String startTime,
    required String endTime,
  }) async {
    if (Store.instance.current?.admin != true) {
      return 'Admin access required.';
    }

    try {
      await supabase.from('matches').update({
        'scheduled_date': scheduledDate,
        'match_start_time': startTime,
        'match_end_time': endTime,
      }).eq('league_id', leagueId);

      if (activeLeagueId == leagueId) {
        await loadMatchesFromSupabase();
      }

      return null;
    } on PostgrestException catch (e) {
      return 'Could not update match schedule: ${e.message}';
    } catch (e) {
      return 'Could not update match schedule: $e';
    }
  }


  Future<String?> finalizeMatchAfterScreenshotCheck(
    MatchItem match,
  ) async {
    final homeProof = match.homeProof;
    final awayProof = match.awayProof;
    final hh = match.homeClaimHome;
    final ha = match.homeClaimAway;
    final ah = match.awayClaimHome;
    final aa = match.awayClaimAway;

    if (homeProof == null || awayProof == null ||
        hh == null || ha == null || ah == null || aa == null) {
      return 'Both players must submit a score and screenshot first.';
    }

    if (hh != ah || ha != aa) {
      await supabase.rpc(
        'finalize_match_after_screenshot_check',
        params: {'p_match_id': match.id, 'p_verified': false},
      );
      await loadMatchesFromSupabase();
      return 'The two submitted scores do not match. Match marked DISPUTED.';
    }

    try {
      final homeBytes = await supabase.storage
          .from('match-proofs')
          .download(homeProof);
      final awayBytes = await supabase.storage
          .from('match-proofs')
          .download(awayProof);

      final homeFile = File('${Directory.systemTemp.path}/chibby_home_${match.id}.jpg');
      final awayFile = File('${Directory.systemTemp.path}/chibby_away_${match.id}.jpg');
      await homeFile.writeAsBytes(homeBytes, flush: true);
      await awayFile.writeAsBytes(awayBytes, flush: true);

      final homeCheck = await analyzeResultScreenshot(homeFile, hh, ha);
      final awayCheck = await analyzeResultScreenshot(awayFile, ah, aa);

      final sharedMatchTokens = homeCheck.tokens.intersection(awayCheck.tokens);
      final sameMatchText = sharedMatchTokens.isNotEmpty;

      final verified = homeCheck.valid && awayCheck.valid &&
          homeCheck.hasFullTime && awayCheck.hasFullTime &&
          sameMatchText &&
          homeCheck.scoreA != null && homeCheck.scoreB != null &&
          awayCheck.scoreA != null && awayCheck.scoreB != null &&
          ((homeCheck.scoreA == awayCheck.scoreA &&
                  homeCheck.scoreB == awayCheck.scoreB) ||
              (homeCheck.scoreA == awayCheck.scoreB &&
                  homeCheck.scoreB == awayCheck.scoreA));

      if (!verified) {
        await supabase.rpc(
          'finalize_match_after_screenshot_check',
          params: {'p_match_id': match.id, 'p_verified': false},
        );
        await loadMatchesFromSupabase();
        return 'Screenshots did not pass Full Time, score, or same-match verification. Match marked DISPUTED.';
      }

      // Both screenshots passed verification, but confirmation is now
      // intentionally left to an admin. This prevents the result from
      // entering the league table until an admin approves it.
      await loadMatchesFromSupabase();
      return 'Both screenshots verified. Match is awaiting ADMIN confirmation.';
    } on StorageException catch (e) {
      return 'Could not read proof screenshots: ${e.message}';
    } on PostgrestException catch (e) {
      return 'Verification save failed: ${e.message}';
    } catch (e) {
      return 'Screenshot verification failed: $e';
    }
  }

  Future<String?> adminConfirmMatch(MatchItem match) async {
    if (current?.admin != true) {
      return 'Admin access required.';
    }

    try {
      await supabase.rpc(
        'admin_confirm_match',
        params: {'p_match_id': match.id},
      );
      await loadMatchesFromSupabase();
      return null;
    } on PostgrestException catch (e) {
      return 'Could not confirm match: ${e.message}';
    } catch (e) {
      return 'Could not confirm match: $e';
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

      MatchItem? updated;
      for (final item in matches) {
        if (item.id == match.id) {
          updated = item;
          break;
        }
      }
      if (updated != null && updated.homeProof != null &&
          updated.awayProof != null) {
        final verificationMessage =
            await finalizeMatchAfterScreenshotCheck(updated);
        return verificationMessage;
      }

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
                Container(
                  width: 112,
                  height: 112,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(colors: [Color(0xFF00D9FF), Color(0xFF6B36FF)]),
                    boxShadow: const [BoxShadow(color: Color(0x6600D9FF), blurRadius: 28, spreadRadius: 4)],
                  ),
                  child: const Center(child: Icon(Icons.sports_soccer, size: 64, color: Colors.white)),
                ),
                const SizedBox(height: 18),
                const Text('CHIBBYBALL', style: TextStyle(fontSize: 38, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
                const Text('eFOOTBALL • LEAGUE • COMPETE', style: TextStyle(color: Color(0xFFFFD21F), fontWeight: FontWeight.w800, letterSpacing: 1.2)),
                const SizedBox(height: 32),
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

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  int selectedIndex = 0;
  Timer? _presenceTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _goOnline();
    _presenceTimer = Timer.periodic(const Duration(seconds: 30), (_) => _goOnline());
  }

  Future<void> _goOnline() => Store.instance.setPresence(true);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _goOnline();
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      Store.instance.setPresence(false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _presenceTimer?.cancel();
    Store.instance.setPresence(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = Store.instance.current;
    final pages = const [DashboardPage(), FixturesPage(), TablePage(), ProfilePage()];

    return Scaffold(
      appBar: AppBar(
        title: const Text('CHIBBYBALL League'),
        actions: [
          IconButton(
            tooltip: 'Messages',
            icon: const Icon(Icons.chat_bubble_outline),
            onPressed: () => Navigator.push(
              context, MaterialPageRoute(builder: (_) => const MessagesPage()),
            ).then((_) { if (mounted) setState(() {}); }),
          ),
          const NotificationBell(),
          if (player?.admin == true)
            IconButton(
              icon: const Icon(Icons.admin_panel_settings),
              onPressed: () => Navigator.push(
                context, MaterialPageRoute(builder: (_) => const AdminPage()),
              ).then((_) => setState(() {})),
            ),
        ],
      ),
      body: pages[selectedIndex],
      bottomNavigationBar: NavigationBar(
        selectedIndex: selectedIndex,
        onDestinationSelected: (index) => setState(() => selectedIndex = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.sports_soccer), label: 'Fixtures'),
          NavigationDestination(icon: Icon(Icons.leaderboard), label: 'Table'),
          NavigationDestination(icon: Icon(Icons.person), label: 'Profile'),
        ],
      ),
    );
  }
}

// ============================================================
// MESSAGES
// ============================================================

class MessagesPage extends StatefulWidget {
  const MessagesPage({super.key});
  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  Timer? _presenceRefresh;

  @override
  void initState() {
    super.initState();
    _refreshPlayers();
    _presenceRefresh = Timer.periodic(const Duration(seconds: 15), (_) => _refreshPlayers());
  }

  Future<void> _refreshPlayers() async {
    try {
      await Store.instance.refreshPlayers();
      if (mounted) setState(() {});
    } catch (_) {}
  }

  @override
  void dispose() {
    _presenceRefresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final me = Store.instance.current?.id;
    final players = Store.instance.players.where((p) => !p.admin && p.id != me).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Messages')),
      body: players.isEmpty
          ? const Center(child: Text('No other players available yet.'))
          : RefreshIndicator(
              onRefresh: _refreshPlayers,
              child: ListView.builder(
                padding: const EdgeInsets.all(14),
                itemCount: players.length,
                itemBuilder: (context, index) {
                  final p = players[index];
                  final online = p.isOnline && (p.lastSeen == null || DateTime.now().toUtc().difference(p.lastSeen!.toUtc()).inMinutes < 3);
                  return _MessagePlayerTile(
                    player: p,
                    online: online,
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatPage(player: p))),
                  );
                },
              ),
            ),
    );
  }
}

class _MessagePlayerTile extends StatelessWidget {
  final Player player;
  final bool online;
  final VoidCallback onTap;
  const _MessagePlayerTile({required this.player, required this.online, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xDD081426),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: online ? const Color(0xFF00D9FF) : const Color(0x443A5575)),
        boxShadow: [BoxShadow(color: online ? const Color(0x2200D9FF) : Colors.transparent, blurRadius: 18)],
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        leading: Stack(
          children: [
            CircleAvatar(
              radius: 25,
              backgroundImage: player.avatarUrl.isNotEmpty ? NetworkImage(player.avatarUrl) : null,
              child: player.avatarUrl.isEmpty ? const Icon(Icons.person) : null,
            ),
            Positioned(right: 0, bottom: 0, child: Container(width: 13, height: 13, decoration: BoxDecoration(shape: BoxShape.circle, color: online ? const Color(0xFF20E070) : const Color(0xFF667085), border: Border.all(color: const Color(0xFF081426), width: 2)))),
          ],
        ),
        title: Text(player.gamerTag, style: const TextStyle(fontWeight: FontWeight.w900)),
        subtitle: Text(online ? 'Online' : (player.lastSeen == null ? 'Offline' : 'Last seen ${_shortLastSeen(player.lastSeen!)}')),
        trailing: const Icon(Icons.chat_bubble_outline, color: Color(0xFF00D9FF)),
        onTap: onTap,
      ),
    );
  }

  static String _shortLastSeen(DateTime d) {
    final diff = DateTime.now().toUtc().difference(d.toUtc());
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}

class ChatPage extends StatefulWidget {
  final Player player;
  const ChatPage({super.key, required this.player});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final controller = TextEditingController();
  final scrollController = ScrollController();
  List<MessageItem> messages = [];
  bool loading = true;
  bool sending = false;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    _load();
    timer = Timer.periodic(const Duration(seconds: 3), (_) => _load(silent: true));
  }

  Future<void> _load({bool silent = false}) async {
    try {
      final result = await Store.instance.fetchConversation(widget.player.id);
      if (!mounted) return;
      setState(() { messages = result; loading = false; });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (scrollController.hasClients) scrollController.jumpTo(scrollController.position.maxScrollExtent);
      });
    } catch (e) {
      if (!silent && mounted) {
        setState(() => loading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load messages: $e')));
      }
    }
  }

  Future<void> _send() async {
    if (sending || controller.text.trim().isEmpty) return;
    final text = controller.text.trim();
    setState(() => sending = true);
    final error = await Store.instance.sendMessage(widget.player.id, text);
    if (!mounted) return;
    setState(() => sending = false);
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    controller.clear();
    await _load();
  }

  @override
  void dispose() {
    timer?.cancel();
    controller.dispose();
    scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final me = Store.instance.current?.id;
    final online = widget.player.isOnline && (widget.player.lastSeen == null || DateTime.now().toUtc().difference(widget.player.lastSeen!.toUtc()).inMinutes < 3);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 4,
        title: Row(children: [
          CircleAvatar(radius: 19, backgroundImage: widget.player.avatarUrl.isNotEmpty ? NetworkImage(widget.player.avatarUrl) : null, child: widget.player.avatarUrl.isEmpty ? const Icon(Icons.person, size: 20) : null),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(widget.player.gamerTag, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)), Text(online ? 'Online' : 'Offline', style: TextStyle(fontSize: 11, color: online ? const Color(0xFF20E070) : Colors.grey))])),
        ]),
      ),
      body: Column(children: [
        Expanded(
          child: loading ? const Center(child: CircularProgressIndicator()) : messages.isEmpty ? const Center(child: Text('Start the conversation.')) : ListView.builder(
            controller: scrollController, padding: const EdgeInsets.fromLTRB(14, 16, 14, 12), itemCount: messages.length,
            itemBuilder: (_, i) {
              final m = messages[i];
              final mine = m.senderId == me;
              return Align(alignment: mine ? Alignment.centerRight : Alignment.centerLeft, child: Container(
                constraints: const BoxConstraints(maxWidth: 300), margin: const EdgeInsets.only(bottom: 9), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(color: mine ? const Color(0xFF00BFEA) : const Color(0xFF111F33), borderRadius: BorderRadius.circular(18), border: Border.all(color: mine ? const Color(0x6600E5FF) : const Color(0x443D5878))),
                child: Text(m.body, style: TextStyle(color: mine ? const Color(0xFF001018) : Colors.white, fontWeight: FontWeight.w600)),
              ));
            },
          ),
        ),
        SafeArea(top: false, child: Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10), color: const Color(0xF2080D17),
          child: Row(children: [
            Expanded(child: TextField(controller: controller, textInputAction: TextInputAction.send, onSubmitted: (_) => _send(), decoration: const InputDecoration(hintText: 'Write a message...', prefixIcon: Icon(Icons.chat_bubble_outline)))),
            const SizedBox(width: 8),
            SizedBox(width: 54, height: 54, child: IconButton.filled(onPressed: sending ? null : _send, icon: sending ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send))),
          ]),
        )),
      ]),
    );
  }
}

// ============================================================
// NOTIFICATIONS
// ============================================================

class NotificationBell extends StatelessWidget {
  const NotificationBell({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<int>(
      future: Store.instance.unreadNotificationCount(),
      builder: (context, snapshot) {
        final count = snapshot.data ?? 0;

        return IconButton(
          tooltip: 'Notifications',
          onPressed: () async {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const NotificationsPage(),
              ),
            );
          },
          icon: Stack(
            clipBehavior: Clip.none,
            children: [
              const Icon(Icons.notifications_outlined),
              if (count > 0)
                Positioned(
                  right: -4,
                  top: -5,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.red,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      count > 99 ? '99+' : '$count',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage> {
  bool loading = true;
  String? error;
  List<NotificationItem> notifications = [];

  @override
  void initState() {
    super.initState();
    loadNotifications();
  }

  Future<void> loadNotifications() async {
    setState(() {
      loading = true;
      error = null;
    });

    try {
      notifications = await Store.instance.fetchNotifications();
    } catch (e) {
      error = e.toString();
    }

    if (mounted) setState(() => loading = false);
  }

  String _timeLabel(DateTime date) {
    final local = date.toLocal();
    final now = DateTime.now();
    final difference = now.difference(local);

    if (difference.inMinutes < 1) return 'Just now';
    if (difference.inMinutes < 60) return '${difference.inMinutes}m ago';
    if (difference.inHours < 24) return '${difference.inHours}h ago';
    if (difference.inDays < 7) return '${difference.inDays}d ago';

    return '${local.day}/${local.month}/${local.year}';
  }

  IconData _iconFor(String type) {
    switch (type) {
      case 'new_fixture':
        return Icons.sports_soccer;
      case 'result_submitted':
        return Icons.photo_camera;
      case 'result_confirmed':
        return Icons.check_circle;
      case 'result_disputed':
        return Icons.warning_amber;
      case 'match_reminder':
        return Icons.alarm;
      case 'admin_message':
        return Icons.support_agent;
      default:
        return Icons.notifications;
    }
  }

  Future<void> markRead(NotificationItem item) async {
    if (item.isRead) return;

    final error = await Store.instance.markNotificationRead(item.id);
    if (error == null) {
      await loadNotifications();
    }
  }

  Future<void> markAllRead() async {
    final error = await Store.instance.markAllNotificationsRead();
    if (error == null) {
      await loadNotifications();
    }
  }

  @override
  Widget build(BuildContext context) {
    final unread = notifications.where((n) => !n.isRead).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          if (unread > 0)
            TextButton(
              onPressed: markAllRead,
              child: const Text('READ ALL'),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: loadNotifications,
        child: loading
            ? ListView(
                children: [
                  const SizedBox(
                    height: 250,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ],
              )
            : error != null
                ? ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      const Icon(Icons.error_outline, size: 50),
                      const SizedBox(height: 12),
                      Text(
                        'Could not load notifications.\n\n$error',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 15),
                      FilledButton(
                        onPressed: loadNotifications,
                        child: const Text('TRY AGAIN'),
                      ),
                    ],
                  )
                : notifications.isEmpty
                    ? ListView(
                        children: const [
                          SizedBox(height: 180),
                          Icon(Icons.notifications_none, size: 65),
                          SizedBox(height: 15),
                          Center(
                            child: Text(
                              'No notifications yet.',
                              style: TextStyle(fontSize: 18),
                            ),
                          ),
                        ],
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: notifications.length,
                        itemBuilder: (context, index) {
                          final item = notifications[index];

                          return Card(
                            margin: const EdgeInsets.only(bottom: 10),
                            color: item.isRead
                                ? null
                                : Theme.of(context)
                                    .colorScheme
                                    .primaryContainer
                                    .withOpacity(.35),
                            child: ListTile(
                              leading: CircleAvatar(
                                child: Icon(_iconFor(item.type)),
                              ),
                              title: Text(
                                item.title,
                                style: TextStyle(
                                  fontWeight: item.isRead
                                      ? FontWeight.normal
                                      : FontWeight.bold,
                                ),
                              ),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 5),
                                child: Text(
                                  '${item.message}\n${_timeLabel(item.createdAt)}',
                                ),
                              ),
                              isThreeLine: true,
                              onTap: () => markRead(item),
                            ),
                          );
                        },
                      ),
      ),
    );
  }
}


// ============================================================
// CHIBBYBALL NEON UI HELPERS
// ============================================================

const _cyan = Color(0xFF00D9FF);
const _yellow = Color(0xFFFFD21F);
const _purple = Color(0xFF9B4DFF);
const _blue = Color(0xFF278BFF);
const _panel = Color(0xE9081426);
const _muted = Color(0xFFAAB8CB);

BoxDecoration _neonBox(Color accent, {double radius = 20}) => BoxDecoration(
  color: _panel,
  borderRadius: BorderRadius.circular(radius),
  border: Border.all(color: accent.withOpacity(.78), width: 1.3),
  boxShadow: [BoxShadow(color: accent.withOpacity(.12), blurRadius: 22)],
);

Widget _neonSectionTitle(String title, {Color accent = _cyan}) => Row(
  children: [
    Container(width: 5, height: 24, decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(4), boxShadow: [BoxShadow(color: accent.withOpacity(.45), blurRadius: 10)])),
    const SizedBox(width: 10),
    Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900, letterSpacing: .7)),
  ],
);

Widget _neonAction(BuildContext context, IconData icon, String title, String subtitle, Color accent, VoidCallback onTap) => Container(
  decoration: _neonBox(accent, radius: 18),
  child: InkWell(
    borderRadius: BorderRadius.circular(18),
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
      child: Row(children: [
        Container(width: 48, height: 48, decoration: BoxDecoration(color: accent.withOpacity(.12), borderRadius: BorderRadius.circular(15), border: Border.all(color: accent.withOpacity(.35))), child: Icon(icon, color: accent, size: 27)),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900)), const SizedBox(height: 3), Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: _muted, fontSize: 11))])),
        Icon(Icons.chevron_right, color: accent, size: 28),
      ]),
    ),
  ),
);

Widget _neonStat(BuildContext context, IconData icon, String value, String label, Color accent, VoidCallback onTap) => Expanded(
  child: Container(
    margin: const EdgeInsets.symmetric(horizontal: 4),
    decoration: _neonBox(accent, radius: 18),
    child: InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 5), child: Column(children: [Icon(icon, color: accent, size: 25), const SizedBox(height: 7), Text(value, style: TextStyle(color: accent, fontSize: 25, fontWeight: FontWeight.w900)), const SizedBox(height: 2), Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: .5))])),
    ),
  ),
);

Widget _playerAvatar(Player? player, {double radius = 24, Color accent = _cyan}) => CircleAvatar(
  radius: radius,
  backgroundColor: const Color(0xFF10233E),
  backgroundImage: (player?.avatarUrl.isNotEmpty ?? false) ? NetworkImage(player!.avatarUrl) : null,
  child: (player?.avatarUrl.isNotEmpty ?? false) ? null : Icon(Icons.person, color: accent, size: radius),
);

// ============================================================
// DASHBOARD
// ============================================================


class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = Store.instance;
    final player = store.current;
    final myMatches = player == null ? <MatchItem>[] : store.matches.where((m) => m.homeId == player.id || m.awayId == player.id).toList();
    final confirmed = myMatches.where((m) => m.status == 'Confirmed').length;
    final pending = myMatches.where((m) => m.status == 'Awaiting Confirmation').length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [Color(0xE90B2039), Color(0xE9061020)]),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: _cyan.withOpacity(.75)),
            boxShadow: const [BoxShadow(color: Color(0x2200D9FF), blurRadius: 24)],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('WELCOME ${player?.gamerTag.toUpperCase() ?? ''}', style: const TextStyle(color: _muted, fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
            const SizedBox(height: 8),
            const Text('CHIBBYBALL', style: TextStyle(fontSize: 31, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
            const SizedBox(height: 3),
            const Text('eFOOTBALL • LEAGUE • COMPETE', style: TextStyle(color: _cyan, fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: .6)),
            const SizedBox(height: 13),
            const Text('PLAY • COMPETE • WIN', style: TextStyle(color: _yellow, fontSize: 13, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
          ]),
        ),
        const SizedBox(height: 14),
        Row(children: [
          _neonStat(context, Icons.sports_soccer, '${myMatches.length}', 'FIXTURES', _cyan, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FixturesPage()))),
          _neonStat(context, Icons.check_circle, '$confirmed', 'CONFIRMED', _yellow, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FixturesPage(statusFilter: 'Confirmed')))),
          _neonStat(context, Icons.hourglass_top, '$pending', 'PENDING', _purple, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FixturesPage(statusFilter: 'Awaiting Confirmation')))),
        ]),
        const SizedBox(height: 18),
        _neonAction(context, Icons.calendar_month, 'YOUR FIXTURES', 'View matches and submit results', _cyan, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FixturesPage()))),
        const SizedBox(height: 10),
        _neonAction(context, Icons.leaderboard, 'LEAGUE TABLE', 'See the live standings', _yellow, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TablePage()))),
        const SizedBox(height: 10),
        _neonAction(context, Icons.person, 'PLAYER PROFILE', 'Edit details and profile photo', _purple, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfilePage()))),
        const SizedBox(height: 10),
        _neonAction(context, Icons.people_alt, 'PLAYERS & MESSAGES', 'See online players and chat', _blue, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MessagesPage()))),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: _neonBox(_blue, radius: 18),
          child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('RESULT RULE', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
            SizedBox(height: 8),
            Text('Both players submit the score and screenshot proof. The match only counts in the table after confirmation. Different claims can be disputed for admin review.', style: TextStyle(color: _muted, height: 1.45, fontSize: 12)),
          ]),
        ),
      ],
    );
  }
}

// ============================================================
// FIXTURES
// ============================================================


class FixturesPage extends StatefulWidget {
  final String? statusFilter;
  const FixturesPage({super.key, this.statusFilter});
  @override State<FixturesPage> createState() => _FixturesPageState();
}

class _FixturesPageState extends State<FixturesPage> {
  bool loading = false;

  Future<void> _selectLeague(String? id) async {
    if (id == null || id == Store.instance.activeLeagueId) return;
    setState(() => loading = true);
    final error = await Store.instance.selectLeague(id);
    if (!mounted) return;
    setState(() => loading = false);
    if (error != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  String _dateLabel(MatchItem m) {
    if (m.scheduledDate == null || m.scheduledDate!.isEmpty) return 'DATE NOT SET';
    final parts = m.scheduledDate!.split('-');
    if (parts.length == 3) return '${parts[2]}/${parts[1]}/${parts[0]}';
    return m.scheduledDate!;
  }

  Color _accent(MatchItem m) {
    switch (m.status) {
      case 'Confirmed': return _yellow;
      case 'Disputed': return const Color(0xFFFF4D7D);
      case 'Awaiting Confirmation': return _purple;
      default: return _cyan;
    }
  }

  Widget _fixtureCard(MatchItem m) {
    final store = Store.instance;
    final home = store.players.where((p) => p.id == m.homeId).firstOrNull;
    final away = store.players.where((p) => p.id == m.awayId).firstOrNull;
    final accent = _accent(m);
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: _neonBox(accent, radius: 20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ResultPage(match: m))).then((_) { if (mounted) setState(() {}); }),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 14, 12),
          child: Column(children: [
            Row(children: [
              Expanded(child: Text('MATCHDAY ${m.round} • ${_dateLabel(m)}', style: TextStyle(color: accent, fontWeight: FontWeight.w900, fontSize: 11))),
              Container(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4), decoration: BoxDecoration(color: accent.withOpacity(.12), borderRadius: BorderRadius.circular(20)), child: Text(m.status.toUpperCase(), style: TextStyle(color: accent, fontSize: 9, fontWeight: FontWeight.w900))),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: Column(children: [_playerAvatar(home, radius: 27, accent: accent), const SizedBox(height: 6), Text(home?.gamerTag ?? store.playerName(m.homeId), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13))])),
              SizedBox(width: 92, child: Column(children: [const Text('VS', style: TextStyle(color: _cyan, fontSize: 18, fontWeight: FontWeight.w900)), const SizedBox(height: 4), Text(m.status == 'Confirmed' ? '${m.homeScore} - ${m.awayScore}' : 'MATCH', style: TextStyle(color: m.status == 'Confirmed' ? _yellow : _muted, fontWeight: FontWeight.w900, fontSize: 15)), const SizedBox(height: 5), Text(m.scheduleLabel, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF7F91A8), fontSize: 9))])),
              Expanded(child: Column(children: [_playerAvatar(away, radius: 27, accent: accent), const SizedBox(height: 6), Text(away?.gamerTag ?? store.playerName(m.awayId), textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13))])),
            ]),
            const SizedBox(height: 10),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.touch_app, size: 13, color: accent), const SizedBox(width: 5), Text(m.status == 'Scheduled' ? 'TAP TO SUBMIT RESULT' : 'TAP TO VIEW RESULT', style: TextStyle(color: accent, fontSize: 9, fontWeight: FontWeight.w900))]),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = Store.instance;
    final selected = store.activeLeagueId == null ? null : store.leagues.where((l) => l.id == store.activeLeagueId).firstOrNull;
    var visible = List<MatchItem>.from(store.matches);
    final player = store.current;
    if (player != null) visible = visible.where((m) => m.homeId == player.id || m.awayId == player.id).toList();
    if (widget.statusFilter != null) visible = visible.where((m) => m.status == widget.statusFilter).toList();
    final rounds = visible.map((m) => m.round).toSet().toList()..sort();

    return ListView(padding: const EdgeInsets.fromLTRB(14, 12, 14, 30), children: [
      Container(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
        decoration: _neonBox(_cyan, radius: 22),
        child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('CHIBBYBALL', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900, letterSpacing: 1)),
          SizedBox(height: 3),
          Text('FIXTURES', style: TextStyle(color: _cyan, fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: 1.3)),
          SizedBox(height: 8),
          Text('PLAY • COMPETE • WIN', style: TextStyle(color: _yellow, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1)),
        ]),
      ),
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: _neonBox(_blue, radius: 18),
        child: DropdownButtonFormField<String>(value: selected?.id, decoration: const InputDecoration(labelText: 'SELECT LEAGUE', border: InputBorder.none), items: store.leagues.map((l) => DropdownMenuItem(value: l.id, child: Text('${l.name} • ${l.status.toUpperCase()}'))).toList(), onChanged: loading ? null : _selectLeague),
      ),
      if (selected != null) Padding(padding: const EdgeInsets.fromLTRB(3, 16, 3, 10), child: Text(selected.name.toUpperCase(), style: const TextStyle(color: _yellow, fontSize: 21, fontWeight: FontWeight.w900, letterSpacing: .7))),
      if (widget.statusFilter != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(widget.statusFilter!.toUpperCase(), style: const TextStyle(color: _purple, fontWeight: FontWeight.w900))),
      if (visible.isEmpty) ...[
        const SizedBox(height: 55),
        const Center(child: Icon(Icons.sports_soccer, size: 60, color: _cyan)),
        const SizedBox(height: 10),
        const Center(child: Text('No fixtures found.', style: TextStyle(color: _muted, fontSize: 16))),
        if (selected?.status == 'active' && player?.admin == true) ...[
          const SizedBox(height: 18),
          FilledButton.icon(onPressed: loading ? null : () async { setState(() => loading = true); final e = await store.generateFixtures(); if (mounted) { setState(() => loading = false); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e ?? 'Fixtures generated successfully.'))); } }, icon: const Icon(Icons.auto_awesome), label: const Text('GENERATE FIXTURES')),
        ],
      ] else ...[
        for (final round in rounds) ...[
          Padding(padding: const EdgeInsets.fromLTRB(2, 14, 2, 9), child: _neonSectionTitle('MATCHDAY $round', accent: _cyan)),
          ...visible.where((m) => m.round == round).map(_fixtureCard),
        ],
      ],
    ]);
  }
}

extension MatchScheduleDisplay on MatchItem {
  String get scheduleLabel {
    String formatTime(String value) {
      final parts = value.split(':');
      final hour = int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 17;
      final minute = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0;
      final suffix = hour >= 12 ? 'PM' : 'AM';
      final displayHour = hour % 12 == 0 ? 12 : hour % 12;
      return '$displayHour:${minute.toString().padLeft(2, '0')} $suffix';
    }
    final date = scheduledDate == null || scheduledDate!.isEmpty ? 'Date set by admin' : scheduledDate!;
    return '$date • ${formatTime(startTime)} – ${formatTime(endTime)}';
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

  Future<Uint8List?> _loadProof(String? path) async {
    if (path == null || path.isEmpty) return null;
    try {
      return await Store.instance.supabase.storage
          .from('match-proofs')
          .download(path);
    } catch (_) {
      return null;
    }
  }

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

    final message = await Store.instance.submitResult(
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
          message ?? 'Result saved.',
        ),
      ),
    );

    Navigator.pop(context);
  }

  @override
  void initState() {
    super.initState();
    final player = Store.instance.current;
    final match = widget.match;
    if (player?.id == match.homeId &&
        match.homeClaimHome != null &&
        match.homeClaimAway != null) {
      homeController.text = '${match.homeClaimHome}';
      awayController.text = '${match.homeClaimAway}';
    } else if (player?.id == match.awayId &&
        match.awayClaimHome != null &&
        match.awayClaimAway != null) {
      homeController.text = '${match.awayClaimHome}';
      awayController.text = '${match.awayClaimAway}';
    }
  }

  @override
  void dispose() {
    homeController.dispose();
    awayController.dispose();
    super.dispose();
  }

  Widget _storedProofCard({
    required String title,
    required String? path,
  }) {
    if (path == null || path.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Text('$title\nNo screenshot submitted.'),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            FutureBuilder<Uint8List?>(
              future: _loadProof(path),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const SizedBox(
                    height: 180,
                    child: Center(child: CircularProgressIndicator()),
                  );
                }

                final bytes = snapshot.data;
                if (bytes == null) {
                  return const SizedBox(
                    height: 120,
                    child: Center(
                      child: Text('Could not load this screenshot.'),
                    ),
                  );
                }

                return ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: InteractiveViewer(
                    minScale: 0.8,
                    maxScale: 4,
                    child: Image.memory(
                      bytes,
                      width: double.infinity,
                      fit: BoxFit.contain,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _verificationExplanation(MatchItem match) {
    String message;
    IconData icon;

    switch (match.status) {
      case 'Disputed':
        message =
            'Automatic verification failed. One or more submitted screenshots did not pass the Full Time, score, or same-match checks.';
        icon = Icons.error_outline;
        break;
      case 'Confirmed':
        message =
            'Both players submitted screenshots that passed the automatic Full Time, score, and same-match checks.';
        icon = Icons.verified_outlined;
        break;
      case 'Awaiting Confirmation':
        message =
            'Waiting for both players to submit their screenshot proof. The match will be checked automatically when both are available.';
        icon = Icons.hourglass_top;
        break;
      default:
        message = 'No result has been submitted yet.';
        icon = Icons.info_outline;
    }

    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: const Text('Automatic verification'),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(message),
        ),
      ),
    );
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
          const SizedBox(height: 12),
          _verificationExplanation(match),
          const SizedBox(height: 16),

          // Both players can see BOTH stored proof screenshots.
          const Text(
            'MATCH EVIDENCE',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          _storedProofCard(
            title:
                '${store.playerName(match.homeId)} • '
                'Claimed ${match.homeClaimHome ?? '-'}-${match.homeClaimAway ?? '-'}',
            path: match.homeProof,
          ),
          _storedProofCard(
            title:
                '${store.playerName(match.awayId)} • '
                'Claimed ${match.awayClaimHome ?? '-'}-${match.awayClaimAway ?? '-'}',
            path: match.awayProof,
          ),

          const Divider(height: 32),
          const Text(
            'SUBMIT / UPDATE YOUR RESULT',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: homeController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: '${store.playerName(match.homeId)} score',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 15),
          TextField(
            controller: awayController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: '${store.playerName(match.awayId)} score',
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

class TablePage extends StatefulWidget {
  const TablePage({super.key});
  @override State<TablePage> createState() => _TablePageState();
}

class _TablePageState extends State<TablePage> {
  bool loading = false;

  Future<void> _selectLeague(String? id) async {
    if (id == null || id == Store.instance.activeLeagueId) return;
    setState(() => loading = true);
    final error = await Store.instance.selectLeague(id);
    if (!mounted) return;
    setState(() => loading = false);
    if (error != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
  }

  Color _rankColor(int rank) => rank == 1 ? _yellow : rank == 2 ? _cyan : rank == 3 ? _purple : _blue;

  @override
  Widget build(BuildContext context) {
    final store = Store.instance;
    final table = store.buildTable();
    final ordered = table.keys.toList()..sort((a, b) {
      final x = table[a]!; final y = table[b]!;
      final p = y['points']!.compareTo(x['points']!); if (p != 0) return p;
      final gd = y['gd']!.compareTo(x['gd']!); if (gd != 0) return gd;
      return y['gf']!.compareTo(x['gf']!);
    });
    final selected = store.activeLeagueId == null ? null : store.leagues.where((l) => l.id == store.activeLeagueId).firstOrNull;

    Widget stat(String label, String value, Color color) => SizedBox(width: 34, child: Column(children: [Text(label, style: const TextStyle(color: Color(0xFF71829A), fontSize: 8, fontWeight: FontWeight.w900)), const SizedBox(height: 3), Text(value, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w900))]));

    return ListView(padding: const EdgeInsets.fromLTRB(14, 12, 14, 28), children: [
      Container(padding: const EdgeInsets.fromLTRB(18, 19, 18, 18), decoration: _neonBox(_blue, radius: 22), child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('CHIBBYBALL COMPETITION', style: TextStyle(color: _muted, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.4)), SizedBox(height: 7), Text('LEAGUE TABLE', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: .8)), SizedBox(height: 5), Text('RANK • COMPETE • WIN', style: TextStyle(color: _cyan, fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: .8)), Text('PLAY • COMPETE • WIN', style: TextStyle(color: _yellow, fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: .8))])),
      const SizedBox(height: 12),
      Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5), decoration: _neonBox(_cyan, radius: 18), child: DropdownButtonFormField<String>(value: selected?.id, decoration: const InputDecoration(labelText: 'SELECT LEAGUE', border: InputBorder.none), items: store.leagues.map((l) => DropdownMenuItem(value: l.id, child: Text('${l.name} • ${l.status.toUpperCase()}'))).toList(), onChanged: loading ? null : _selectLeague)),
      if (selected != null) Padding(padding: const EdgeInsets.fromLTRB(3, 15, 3, 9), child: Text(selected.name.toUpperCase(), style: const TextStyle(color: _yellow, fontSize: 20, fontWeight: FontWeight.w900))),
      if (ordered.isEmpty)
        Container(padding: const EdgeInsets.all(20), decoration: _neonBox(_cyan, radius: 18), child: const Text('No players in this league yet.', style: TextStyle(color: _muted)))
      else ...[
        Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9), decoration: _neonBox(_blue, radius: 14), child: Row(children: [const SizedBox(width: 39), const Expanded(child: Text('PLAYER', style: TextStyle(color: _muted, fontSize: 9, fontWeight: FontWeight.w900))), stat('P','',_muted), stat('W','',_muted), stat('D','',_muted), stat('L','',_muted), stat('GD','',_muted), stat('PTS','',_yellow)])),
        const SizedBox(height: 7),
        for (int i = 0; i < ordered.length; i++) ...[
          Builder(builder: (_) {
            final id = ordered[i]; final row = table[id]!; final player = store.findPlayer(id); final rank = i + 1; final accent = _rankColor(rank);
            return Container(
              margin: const EdgeInsets.only(bottom: 7),
              decoration: _neonBox(accent, radius: 16),
              child: InkWell(borderRadius: BorderRadius.circular(16), onTap: () {
                if (player != null) Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerStatsPageFor(player: player)));
              }, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9), child: Row(children: [
                Container(width: 36, height: 36, decoration: BoxDecoration(shape: BoxShape.circle, color: accent.withOpacity(.12), border: Border.all(color: accent, width: 1.3)), child: Center(child: Text('$rank', style: TextStyle(color: accent, fontWeight: FontWeight.w900)))),
                const SizedBox(width: 8),
                _playerAvatar(player, radius: 18, accent: accent),
                const SizedBox(width: 8),
                Expanded(child: Text(store.playerName(id), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900))),
                stat('P','${row['played']}',accent), stat('W','${row['won']}',accent), stat('D','${row['drawn']}',accent), stat('L','${row['lost']}',accent), stat('GD','${row['gd']}',accent), stat('PTS','${row['points']}',accent),
              ]))),
            );
          }),
        ],
      ],
      const SizedBox(height: 12),
      const Text('Only CONFIRMED matches count toward the selected league table.', style: TextStyle(color: _muted, fontSize: 11)),
    ]);
  }
}

class PlayerStatsPageFor extends StatelessWidget {
  final Player player;
  const PlayerStatsPageFor({super.key, required this.player});
  @override
  Widget build(BuildContext context) {
    final store = Store.instance;
    final stats = store.statsForPlayer(player.id);
    final history = store.confirmedMatchesForPlayer(player.id);
    return Scaffold(appBar: AppBar(title: Text(player.gamerTag)), body: ListView(padding: const EdgeInsets.all(16), children: [
      Center(child: _playerAvatar(player, radius: 42, accent: _cyan)), const SizedBox(height: 8), Center(child: Text(player.gamerTag, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900))), const SizedBox(height: 18),
      Wrap(spacing: 8, runSpacing: 8, children: ['played','won','drawn','lost','gf','ga','gd','points'].map((k) => Container(width: 95, padding: const EdgeInsets.all(12), decoration: _neonBox(k == 'points' ? _yellow : _cyan, radius: 14), child: Column(children: [Text('${stats[k]}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)), const SizedBox(height: 3), Text(k.toUpperCase(), style: const TextStyle(fontSize: 9, color: _muted, fontWeight: FontWeight.w900))]))).toList()),
      const SizedBox(height: 20),
      _neonSectionTitle('CONFIRMED MATCH HISTORY', accent: _yellow), const SizedBox(height: 10),
      if (history.isEmpty) Container(padding: const EdgeInsets.all(18), decoration: _neonBox(_blue, radius: 16), child: const Text('No confirmed matches yet.', style: TextStyle(color: _muted))) else ...history.map((m) => Container(margin: const EdgeInsets.only(bottom: 8), decoration: _neonBox(_blue, radius: 14), child: ListTile(title: Text('${store.playerName(m.homeId)} vs ${store.playerName(m.awayId)}'), subtitle: Text('Matchday ${m.round}'), trailing: Text('${m.homeScore} - ${m.awayScore}', style: const TextStyle(color: _yellow, fontWeight: FontWeight.w900))))),
    ]));
  }
}

// ============================================================
// PROFILE
// ============================================================

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});
  @override State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late final TextEditingController phoneController;
  late final TextEditingController countryController;
  late final TextEditingController countryCodeController;
  late final TextEditingController whatsappController;
  bool saving = false;
  bool uploadingAvatar = false;
  bool editing = false;

  @override
  void initState() {
    super.initState();
    final p = Store.instance.current;
    phoneController = TextEditingController(text: p?.phoneNumber ?? '');
    countryController = TextEditingController(text: p?.country ?? '');
    countryCodeController = TextEditingController(text: p?.countryCode ?? '');
    whatsappController = TextEditingController(text: p?.whatsappNumber ?? '');
    editing = !_hasSavedDetails(p);
  }

  bool _hasSavedDetails(Player? p) => p != null && (p.phoneNumber.trim().isNotEmpty || p.country.trim().isNotEmpty || p.countryCode.trim().isNotEmpty || p.whatsappNumber.trim().isNotEmpty);

  @override
  void dispose() { phoneController.dispose(); countryController.dispose(); countryCodeController.dispose(); whatsappController.dispose(); super.dispose(); }

  Future<void> changeAvatar() async {
    if (uploadingAvatar) return;
    final image = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 82);
    if (image == null || !mounted) return;
    setState(() => uploadingAvatar = true);
    final error = await Store.instance.uploadMyAvatar(image);
    if (!mounted) return;
    setState(() => uploadingAvatar = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error ?? 'Profile photo updated.')));
    if (error == null) setState(() {});
  }

  Future<void> saveProfile() async {
    setState(() => saving = true);
    final error = await Store.instance.updateMyProfile(phoneNumber: phoneController.text, country: countryController.text, countryCode: countryCodeController.text, whatsappNumber: whatsappController.text);
    if (!mounted) return;
    setState(() { saving = false; if (error == null) editing = false; });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error ?? 'Profile details saved successfully.')));
  }

  void startEditing() {
    final p = Store.instance.current;
    phoneController.text = p?.phoneNumber ?? ''; countryController.text = p?.country ?? ''; countryCodeController.text = p?.countryCode ?? ''; whatsappController.text = p?.whatsappNumber ?? '';
    setState(() => editing = true);
  }

  Future<void> logout() async {
    await Store.instance.setPresence(false);
    await Store.instance.logout();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const LoginPage()), (_) => false);
  }

  Widget _info(IconData icon, String title, String value, Color accent) => Container(margin: const EdgeInsets.only(bottom: 10), decoration: _neonBox(accent, radius: 16), child: ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 3), leading: Icon(icon, color: accent, size: 25), title: Text(title, style: const TextStyle(color: _muted, fontSize: 13, fontWeight: FontWeight.w700)), subtitle: Text(value.trim().isEmpty ? 'Not provided' : value.trim(), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700))));

  @override
  Widget build(BuildContext context) {
    final p = Store.instance.current;
    final online = p?.isOnline == true && (p?.lastSeen == null || DateTime.now().toUtc().difference(p!.lastSeen!.toUtc()).inMinutes < 3);
    return ListView(padding: const EdgeInsets.fromLTRB(16, 14, 16, 30), children: [
      Container(padding: const EdgeInsets.fromLTRB(18, 20, 18, 18), decoration: _neonBox(_blue, radius: 24), child: Column(children: [
        Stack(clipBehavior: Clip.none, children: [Container(width: 122, height: 122, padding: const EdgeInsets.all(4), decoration: BoxDecoration(shape: BoxShape.circle, gradient: const LinearGradient(colors: [_cyan, _purple, _yellow]), boxShadow: const [BoxShadow(color: Color(0x4400D9FF), blurRadius: 25)]), child: CircleAvatar(backgroundColor: const Color(0xFF071225), backgroundImage: (p?.avatarUrl.isNotEmpty ?? false) ? NetworkImage(p!.avatarUrl) : null, child: (p?.avatarUrl.isNotEmpty ?? false) ? null : const Icon(Icons.person, size: 60, color: _muted))), Positioned(right: -4, bottom: 0, child: IconButton.filled(onPressed: uploadingAvatar ? null : changeAvatar, icon: uploadingAvatar ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.edit)))) ,
        const SizedBox(height: 12), Text(p?.gamerTag ?? 'PLAYER', style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w900)), Text(p?.name ?? '', style: const TextStyle(color: _muted)), const SizedBox(height: 8),
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: BoxDecoration(color: (online ? const Color(0xFF20E070) : const Color(0xFF667085)).withOpacity(.12), borderRadius: BorderRadius.circular(30), border: Border.all(color: online ? const Color(0xFF20E070) : const Color(0xFF667085))), child: Row(mainAxisSize: MainAxisSize.min, children: [Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: online ? const Color(0xFF20E070) : const Color(0xFF667085))), const SizedBox(width: 7), Text(online ? 'ONLINE' : 'OFFLINE', style: TextStyle(color: online ? const Color(0xFF20E070) : _muted, fontSize: 11, fontWeight: FontWeight.w900))])),
      ])),
      const SizedBox(height: 16),
      _neonSectionTitle('ACCOUNT', accent: _yellow), const SizedBox(height: 10),
      _info(Icons.badge_outlined, 'Gamer Tag', p?.gamerTag ?? '', _cyan),
      _info(Icons.person_outline, 'Full Name', p?.name ?? '', _cyan),
      _info(Icons.shield_outlined, 'Account Role', p?.admin == true ? 'Administrator' : 'Player', _purple),
      const SizedBox(height: 6),
      Row(children: [Expanded(child: _neonSectionTitle('PLAYER DETAILS', accent: _cyan)), IconButton(onPressed: startEditing, icon: const Icon(Icons.edit, color: _cyan))]),
      const SizedBox(height: 8),
      if (!editing) ...[
        _info(Icons.phone, 'Phone Number', p?.phoneNumber ?? '', _cyan),
        _info(Icons.public, 'Country', p?.country ?? '', _cyan),
        _info(Icons.language, 'Country Code', p?.countryCode ?? '', _cyan),
        _info(Icons.chat, 'WhatsApp Number', p?.whatsappNumber ?? '', const Color(0xFF20E070)),
      ],
      if (editing) ...[
        TextField(controller: phoneController, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone Number', prefixIcon: Icon(Icons.phone))), const SizedBox(height: 10),
        TextField(controller: countryController, decoration: const InputDecoration(labelText: 'Country', prefixIcon: Icon(Icons.public))), const SizedBox(height: 10),
        TextField(controller: countryCodeController, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Country Code (e.g. +234)', prefixIcon: Icon(Icons.language))), const SizedBox(height: 10),
        TextField(controller: whatsappController, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'WhatsApp Number', prefixIcon: Icon(Icons.chat))), const SizedBox(height: 12),
        Row(children: [Expanded(child: FilledButton.icon(onPressed: saving ? null : saveProfile, icon: saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save), label: Text(saving ? 'SAVING...' : 'SAVE PROFILE'))), const SizedBox(width: 8), if (_hasSavedDetails(p)) IconButton(onPressed: saving ? null : () => setState(() => editing = false), icon: const Icon(Icons.close, color: _muted))]),
      ],
      const SizedBox(height: 8),
      Container(decoration: _neonBox(_purple, radius: 18), child: ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 4), leading: Stack(children: [const Icon(Icons.chat_bubble_outline, color: _purple, size: 29), Positioned(right: -2, bottom: -2, child: Container(width: 9, height: 9, decoration: BoxDecoration(shape: BoxShape.circle, color: online ? const Color(0xFF20E070) : const Color(0xFF667085), border: Border.all(color: _panel, width: 2))))]), title: const Text('PLAYERS & MESSAGES', style: TextStyle(fontWeight: FontWeight.w900)), subtitle: Text(online ? 'You are online • chat with other players' : 'Chat with other players and see their status'), trailing: const Icon(Icons.chevron_right, color: _purple), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MessagesPage())))),
      const SizedBox(height: 10),
      _neonAction(context, Icons.bar_chart, 'MY STATS & HISTORY', 'Confirmed results and league statistics', _yellow, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PlayerStatsPage()))),
      const SizedBox(height: 10),
      OutlinedButton.icon(onPressed: logout, icon: const Icon(Icons.logout), label: const Text('LOG OUT')),
    ]);
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
  final feeController = TextEditingController();
  bool isPaidLeague = false;
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
    feeController.dispose();
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
    final fee = double.tryParse(feeController.text.trim()) ?? 0;
    final error = await store.createLeague(name, isPaid: isPaidLeague, entryFee: fee, currency: 'NGN');
    if (!mounted) return;
    if (error == null) {
      nameController.clear();
      feeController.clear();
      isPaidLeague = false;
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
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('LEAGUE TYPE', style: TextStyle(fontWeight: FontWeight.bold)),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(isPaidLeague ? 'Paid League' : 'Free League'),
                    subtitle: Text(isPaidLeague ? 'Players will see the entry fee before joining.' : 'No entry fee.'),
                    value: isPaidLeague,
                    onChanged: loading ? null : (value) => setState(() => isPaidLeague = value),
                  ),
                  if (isPaidLeague)
                    TextField(
                      controller: feeController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Entry fee (NGN)', hintText: 'e.g. 2000', prefixText: '₦ ', border: OutlineInputBorder()),
                    ),
                ]),
              ),
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
                    subtitle: Text('Status: ${league.status.toUpperCase()} • ${league.feeLabel}'),
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
                      const SizedBox(height: 4),
                      Text(selected.feeLabel, style: const TextStyle(fontWeight: FontWeight.w600)),
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
// ADMIN MATCH SCHEDULE
// ============================================================

class AdminMatchSchedulePage extends StatefulWidget {
  const AdminMatchSchedulePage({super.key});

  @override
  State<AdminMatchSchedulePage> createState() => _AdminMatchSchedulePageState();
}

class _AdminMatchSchedulePageState extends State<AdminMatchSchedulePage> {
  final store = Store.instance;
  String? selectedLeagueId;
  DateTime? selectedDate;
  TimeOfDay startTime = const TimeOfDay(hour: 17, minute: 0);
  TimeOfDay endTime = const TimeOfDay(hour: 23, minute: 59);
  bool loading = false;

  @override
  void initState() {
    super.initState();
    selectedLeagueId = store.activeLeagueId ??
        (store.leagues.isNotEmpty ? store.leagues.first.id : null);
  }

  String _two(int value) => value.toString().padLeft(2, '0');

  String _dateForDb(DateTime date) =>
      '${date.year}-${_two(date.month)}-${_two(date.day)}';

  String _timeForDb(TimeOfDay time) =>
      '${_two(time.hour)}:${_two(time.minute)}:00';

  String _displayTime(TimeOfDay time) {
    final suffix = time.hour >= 12 ? 'PM' : 'AM';
    final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
    return '$hour:${_two(time.minute)} $suffix';
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: selectedDate ?? DateTime.now(),
      firstDate: DateTime(2026),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => selectedDate = picked);
  }

  Future<void> _pickStartTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: startTime,
    );
    if (picked != null) setState(() => startTime = picked);
  }

  Future<void> _pickEndTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: endTime,
    );
    if (picked != null) setState(() => endTime = picked);
  }

  Future<void> _applySchedule() async {
    final leagueId = selectedLeagueId;
    if (leagueId == null) return;

    if (startTime.hour * 60 + startTime.minute >=
        endTime.hour * 60 + endTime.minute) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('End time must be later than start time.')),
      );
      return;
    }

    setState(() => loading = true);
    final error = await store.updateLeagueMatchSchedule(
      leagueId: leagueId,
      scheduledDate: selectedDate == null ? null : _dateForDb(selectedDate!),
      startTime: _timeForDb(startTime),
      endTime: _timeForDb(endTime),
    );

    if (!mounted) return;
    setState(() => loading = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          error ?? 'Match schedule updated successfully for this league.',
        ),
      ),
    );
  }

  Future<void> _resetDefaults() async {
    setState(() {
      selectedDate = null;
      startTime = const TimeOfDay(hour: 17, minute: 0);
      endTime = const TimeOfDay(hour: 23, minute: 59);
    });

    final leagueId = selectedLeagueId;
    if (leagueId == null) return;

    setState(() => loading = true);
    final error = await store.updateLeagueMatchSchedule(
      leagueId: leagueId,
      scheduledDate: null,
      startTime: '17:00:00',
      endTime: '23:59:00',
    );
    if (!mounted) return;
    setState(() => loading = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          error ?? 'Schedule reset to the default 5:00 PM – 11:59 PM.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final leagues = store.leagues;
    final selected = leagues.where((l) => l.id == selectedLeagueId).firstOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('Match Schedule')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Default match window: 5:00 PM – 11:59 PM.\n\n'
                'The admin can change the date and time at any time. '
                'The selected schedule is applied to every fixture in the selected league.',
              ),
            ),
          ),
          const SizedBox(height: 14),
          if (leagues.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('No leagues available.'),
              ),
            )
          else ...[
            DropdownButtonFormField<String>(
              value: selectedLeagueId,
              decoration: const InputDecoration(
                labelText: 'SELECT LEAGUE',
                border: OutlineInputBorder(),
              ),
              items: leagues
                  .map(
                    (league) => DropdownMenuItem<String>(
                      value: league.id,
                      child: Text(
                        '${league.name} • ${league.status.toUpperCase()}',
                      ),
                    ),
                  )
                  .toList(),
              onChanged: loading
                  ? null
                  : (value) => setState(() => selectedLeagueId = value),
            ),
            const SizedBox(height: 14),
            Card(
              child: ListTile(
                leading: const Icon(Icons.calendar_month),
                title: const Text('Match Date'),
                subtitle: Text(
                  selectedDate == null
                      ? 'Not set — admin can choose a date'
                      : _dateForDb(selectedDate!),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: loading ? null : _pickDate,
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.login),
                title: const Text('Start Time'),
                subtitle: Text(_displayTime(startTime)),
                trailing: const Icon(Icons.chevron_right),
                onTap: loading ? null : _pickStartTime,
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.logout),
                title: const Text('Deadline / End Time'),
                subtitle: Text(_displayTime(endTime)),
                trailing: const Icon(Icons.chevron_right),
                onTap: loading ? null : _pickEndTime,
              ),
            ),
            const SizedBox(height: 8),
            if (selected != null)
              Text(
                '${selected.name}: ${store.matches.where((m) => m.status != 'Confirmed').length} loaded matches',
                style: const TextStyle(color: Colors.grey),
              ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: loading ? null : _applySchedule,
              icon: loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save),
              label: const Text('APPLY SCHEDULE TO LEAGUE'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: loading ? null : _resetDefaults,
              icon: const Icon(Icons.restore),
              label: const Text('RESET TO DEFAULT 5:00 PM – 11:59 PM'),
            ),
          ],
        ],
      ),
    );
  }
}

// ============================================================
// ADMIN RESULT REVIEW
// ============================================================

class ResultReviewPage extends StatefulWidget {
  const ResultReviewPage({super.key});
  @override
  State<ResultReviewPage> createState() => _ResultReviewPageState();
}

class _ResultReviewPageState extends State<ResultReviewPage> {
  bool loading = false;
  String filter = 'All';
  Store get store => Store.instance;

  Future<void> _refresh() async {
    setState(() => loading = true);
    try { await store.refreshLeagues(); await store.loadMatchesFromSupabase(); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Refresh error: $e'))); }
    if (mounted) setState(() => loading = false);
  }

  String _playerName(String id) {
    final list = store.players.where((p) => p.id == id).toList();
    if (list.isEmpty) return 'Unknown player';
    return list.first.gamerTag.isEmpty ? list.first.name : list.first.gamerTag;
  }

  Future<Uint8List?> _proofBytes(String? path) async {
    if (path == null || path.isEmpty) return null;
    try { return await store.supabase.storage.from('match-proofs').download(path); }
    catch (_) { return null; }
  }

  String _verificationLabel(MatchItem m) {
    switch (m.status) {
      case 'Confirmed': return 'AUTOMATIC VERIFICATION: PASSED';
      case 'Disputed': return 'AUTOMATIC VERIFICATION: FAILED';
      case 'Awaiting Confirmation': return 'AUTOMATIC VERIFICATION: WAITING FOR BOTH PLAYERS';
      default: return 'AUTOMATIC VERIFICATION: NOT SUBMITTED';
    }
  }

  Color _statusColor(BuildContext context, String status) {
    if (status == 'Confirmed') return Colors.green;
    if (status == 'Disputed') return Theme.of(context).colorScheme.error;
    return Theme.of(context).colorScheme.primary;
  }

  @override
  Widget build(BuildContext context) {
    final all = [...store.matches]..sort((a, b) => b.round.compareTo(a.round));
    final visible = filter == 'All' ? all : all.where((m) => m.status == filter).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Result Review'), actions: [IconButton(onPressed: loading ? null : _refresh, icon: const Icon(Icons.refresh))]),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(padding: const EdgeInsets.all(12), children: [
          const Card(child: Padding(padding: EdgeInsets.all(14), child: Text('Admin result review. Both players must submit their scores and screenshots. Automatic screenshot checking verifies the evidence, then an admin must confirm the result before it counts in the league table.'))),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: ['All', 'Awaiting Confirmation', 'Confirmed', 'Disputed']
                  .map(
                    (value) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(value),
                        selected: filter == value,
                        onSelected: (_) => setState(() => filter = value),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          const SizedBox(height: 8),
          if (visible.isEmpty) const Card(child: Padding(padding: EdgeInsets.all(18), child: Text('No results to review.')))
          else ...visible.map((m) => _reviewCard(context, m)),
        ]),
      ),
    );
  }

  Future<void> _adminConfirm(MatchItem match) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm match?'),
        content: const Text(
          'Confirm this result as an admin? It will count toward the league table.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('CONFIRM'),
          ),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    setState(() => loading = true);
    final error = await store.adminConfirmMatch(match);
    if (!mounted) return;
    await _refresh();
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error ?? 'Match confirmed by admin.'),
      ),
    );
  }

  Widget _reviewCard(BuildContext context, MatchItem m) {
    final homeName = _playerName(m.homeId), awayName = _playerName(m.awayId);
    final homeScore = m.homeClaimHome != null && m.homeClaimAway != null ? '${m.homeClaimHome}-${m.homeClaimAway}' : 'Not submitted';
    final awayScore = m.awayClaimHome != null && m.awayClaimAway != null ? '${m.awayClaimHome}-${m.awayClaimAway}' : 'Not submitted';
    return Card(margin: const EdgeInsets.only(bottom: 12), child: ExpansionTile(
      title: Text('$homeName vs $awayName'), subtitle: Text('Round ${m.round} • ${m.status}'), childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
      children: [
        Align(alignment: Alignment.centerLeft, child: Text(_verificationLabel(m), style: TextStyle(fontWeight: FontWeight.bold, color: _statusColor(context, m.status)))),
        const SizedBox(height: 8),
        Row(children: [Expanded(child: _claimBox(homeName, homeScore, m.homeProof)), const SizedBox(width: 8), Expanded(child: _claimBox(awayName, awayScore, m.awayProof))]),
        if (m.status != 'Confirmed') ...[
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: loading ? null : () => _adminConfirm(m),
              icon: const Icon(Icons.admin_panel_settings),
              label: const Text('ADMIN CONFIRM MATCH'),
            ),
          ),
        ],
      ],
    ));
  }

  Widget _claimBox(String player, String score, String? proof) {
    return Card(margin: EdgeInsets.zero, child: Padding(padding: const EdgeInsets.all(8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(player, style: const TextStyle(fontWeight: FontWeight.bold)), const SizedBox(height: 4), Text('Claimed score: $score'), const SizedBox(height: 8),
      if (proof == null) const SizedBox(height: 100, child: Center(child: Text('No screenshot submitted.')))
      else FutureBuilder<Uint8List?>(future: _proofBytes(proof), builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) return const SizedBox(height: 100, child: Center(child: CircularProgressIndicator()));
        final bytes = snapshot.data;
        if (bytes == null) return const SizedBox(height: 100, child: Center(child: Text('Screenshot unavailable.')));
        return ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(bytes, height: 180, width: double.infinity, fit: BoxFit.contain));
      }),
    ])));
  }
}


// ============================================================
// ADMIN PLAYER MANAGEMENT
// ============================================================

class PlayerManagementPage extends StatefulWidget {
  const PlayerManagementPage({super.key});
  @override State<PlayerManagementPage> createState() => _PlayerManagementPageState();
}

class _PlayerManagementPageState extends State<PlayerManagementPage> {
  final searchController = TextEditingController();
  String? selectedLeagueId;
  Set<String> memberIds = {};
  bool loading = false;
  Store get store => Store.instance;

  @override void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => loading = true);
    try { await store.refreshPlayers(); await store.refreshLeagues(); if (store.leagues.isNotEmpty) { selectedLeagueId ??= store.leagues.first.id; memberIds = (await store.leagueMemberIds(selectedLeagueId!)).toSet(); } }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load player management: $e'))); }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _selectLeague(String? id) async {
    if (id == null) return; setState(() { selectedLeagueId = id; loading = true; });
    try { memberIds = (await store.leagueMemberIds(id)).toSet(); } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load league members: $e'))); }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _toggleMember(Player player, bool shouldAdd) async {
    final leagueId = selectedLeagueId; if (leagueId == null) return;
    setState(() => loading = true);
    final error = shouldAdd ? await store.addLeagueMember(leagueId, player.id) : await store.removeLeagueMember(leagueId, player.id);
    if (error == null) shouldAdd ? memberIds.add(player.id) : memberIds.remove(player.id);
    if (mounted) { setState(() => loading = false); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error ?? (shouldAdd ? '${player.gamerTag} added to league.' : '${player.gamerTag} removed from league.')))); }
  }

  Future<void> _disregister(Player player) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(title: const Text('Disregister player?'), content: Text('${player.gamerTag} will be removed from every league. The account itself will not be deleted.'), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('CANCEL')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('DISREGISTER'))]));
    if (ok != true) return;
    setState(() => loading = true);
    final error = await store.disregisterPlayerFromAllLeagues(player.id);
    if (error == null) { memberIds.remove(player.id); await store.refreshLeagues(); await store.loadMatchesFromSupabase(); }
    if (mounted) { setState(() => loading = false); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error ?? '${player.gamerTag} disregistered from all leagues.'))); }
  }

  @override void dispose() { searchController.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final query = searchController.text.trim().toLowerCase();
    final players = store.players.where((p) => !p.admin && (query.isEmpty || p.gamerTag.toLowerCase().contains(query) || p.name.toLowerCase().contains(query))).toList();
    final league = store.leagues.where((l) => l.id == selectedLeagueId).firstOrNull;
    return Scaffold(
      appBar: AppBar(title: const Text('Manage Players')),
      body: RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 28), children: [
        Container(padding: const EdgeInsets.all(16), decoration: _neonBox(_blue, radius: 20), child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('REGISTERED PLAYERS', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900)), SizedBox(height: 4), Text('Assign, remove or disregister players while keeping their account safe.', style: TextStyle(color: _muted, fontSize: 12))])),
        const SizedBox(height: 12),
        TextField(controller: searchController, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Search player or gamer tag', prefixIcon: Icon(Icons.search))),
        const SizedBox(height: 10),
        if (store.leagues.isNotEmpty) Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), decoration: _neonBox(_cyan, radius: 16), child: DropdownButtonFormField<String>(value: selectedLeagueId, decoration: const InputDecoration(labelText: 'LEAGUE', border: InputBorder.none), items: store.leagues.map((l) => DropdownMenuItem(value: l.id, child: Text(l.name))).toList(), onChanged: loading ? null : _selectLeague)),
        if (league != null) Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Text('${memberIds.length} players in ${league.name}', style: const TextStyle(color: _muted, fontWeight: FontWeight.w700))),
        if (players.isEmpty) Container(padding: const EdgeInsets.all(18), decoration: _neonBox(_cyan, radius: 16), child: const Text('No matching players found.')),
        ...players.map((player) {
          final isMember = memberIds.contains(player.id);
          final online = player.isOnline && (player.lastSeen == null || DateTime.now().toUtc().difference(player.lastSeen!.toUtc()).inMinutes < 3);
          return Container(margin: const EdgeInsets.only(bottom: 9), decoration: _neonBox(isMember ? _cyan : _blue, radius: 17), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), child: Row(children: [
            Stack(children: [_playerAvatar(player, radius: 23, accent: isMember ? _cyan : _blue), Positioned(right: 0, bottom: 0, child: Container(width: 11, height: 11, decoration: BoxDecoration(shape: BoxShape.circle, color: online ? const Color(0xFF20E070) : const Color(0xFF667085), border: Border.all(color: _panel, width: 2))))]),
            const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(player.gamerTag, style: const TextStyle(fontWeight: FontWeight.w900)), Text(online ? 'Online' : 'Offline', style: TextStyle(color: online ? const Color(0xFF20E070) : _muted, fontSize: 11)), const SizedBox(height: 2), Text(isMember ? 'Registered in selected league' : 'Not in selected league', style: const TextStyle(color: _muted, fontSize: 10))])),
            IconButton(tooltip: 'Message', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatPage(player: player))), icon: const Icon(Icons.chat_bubble_outline, color: _purple)),
            if (selectedLeagueId != null) IconButton(tooltip: isMember ? 'Remove from league' : 'Add to league', onPressed: loading ? null : () => _toggleMember(player, !isMember), icon: Icon(isMember ? Icons.remove_circle_outline : Icons.add_circle_outline, color: isMember ? const Color(0xFFFF4D7D) : _cyan)),
            PopupMenuButton<String>(onSelected: (value) { if (value == 'disregister') _disregister(player); }, itemBuilder: (_) => const [PopupMenuItem(value: 'disregister', child: Text('Disregister from all leagues'))]),
          ])));
        }),
      ])),
    );
  }
}

// ============================================================
// ADMIN
// ============================================================

class AdminPage extends StatefulWidget {
  const AdminPage({super.key});
  @override State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  bool loading = false;
  Future<void> refresh() async { setState(() => loading = true); try { await Store.instance.refreshPlayers(); await Store.instance.refreshLeagues(); await Store.instance.loadMatchesFromSupabase(); } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Refresh error: $e'))); } if (mounted) setState(() => loading = false); }
  Future<void> generateFixtures() async { setState(() => loading = true); final error = await Store.instance.generateFixtures(); if (!mounted) return; setState(() => loading = false); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error ?? 'Fixtures saved to Supabase successfully.'))); }

  void open(Widget page) => Navigator.push(context, MaterialPageRoute(builder: (_) => page)).then((_) { if (mounted) setState(() {}); });

  @override
  Widget build(BuildContext context) {
    final store = Store.instance;
    final players = store.players.where((p) => !p.admin).toList();
    final confirmed = store.confirmedMatches().length;
    return Scaffold(
      appBar: AppBar(title: const Text('Admin Dashboard'), actions: [IconButton(onPressed: refresh, icon: const Icon(Icons.refresh))]),
      body: RefreshIndicator(onRefresh: refresh, child: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 30), children: [
        Container(padding: const EdgeInsets.fromLTRB(18, 20, 18, 18), decoration: _neonBox(_blue, radius: 24), child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('THIS IS MORE THAN A GAME', style: TextStyle(color: _muted, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.2)), SizedBox(height: 7), Text('CHIBBYBALL', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w900)), SizedBox(height: 4), Text('ADMIN CONTROL CENTER', style: TextStyle(color: _cyan, fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: .8)), SizedBox(height: 14), Text('PLAY • COMPETE • WIN', style: TextStyle(color: _yellow, fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 1))])),
        const SizedBox(height: 13),
        Row(children: [
          _neonStat(context, Icons.people, '${players.length}', 'PLAYERS', _cyan, () => open(const PlayerManagementPage())),
          _neonStat(context, Icons.sports_soccer, '${store.matches.length}', 'FIXTURES', _purple, () => open(const AdminMatchSchedulePage())),
          _neonStat(context, Icons.check_circle, '$confirmed', 'CONFIRMED', _yellow, () => open(const ResultReviewPage())),
        ]),
        const SizedBox(height: 16),
        _neonAction(context, Icons.emoji_events, 'MANAGE LEAGUES', 'Create and activate multiple leagues', _yellow, () => open(const LeagueManagementPage())),
        const SizedBox(height: 9),
        _neonAction(context, Icons.calendar_month, 'MATCH SCHEDULE', 'Set date and time windows', _cyan, () => open(const AdminMatchSchedulePage())),
        const SizedBox(height: 9),
        _neonAction(context, Icons.fact_check, 'RESULT REVIEW', 'Confirm or dispute submitted results', _purple, () => open(const ResultReviewPage())),
        const SizedBox(height: 9),
        _neonAction(context, Icons.manage_accounts, 'MANAGE PLAYERS', 'Assign, remove or disregister players', _cyan, () => open(const PlayerManagementPage())),
        const SizedBox(height: 9),
        _neonAction(context, Icons.refresh, 'REFRESH PLAYERS', 'Reload players and league data', _blue, refresh),
        const SizedBox(height: 9),
        _neonAction(context, Icons.auto_awesome, 'GENERATE FIXTURES', 'Create round-robin fixtures', _yellow, loading ? () {} : generateFixtures),
        const SizedBox(height: 18),
        Row(children: [Expanded(child: _neonSectionTitle('REGISTERED PLAYERS', accent: _cyan)), Text('${players.length}', style: const TextStyle(color: _yellow, fontSize: 18, fontWeight: FontWeight.w900))]),
        const SizedBox(height: 10),
        ...players.take(20).map((player) {
          final online = player.isOnline && (player.lastSeen == null || DateTime.now().toUtc().difference(player.lastSeen!.toUtc()).inMinutes < 3);
          return Container(margin: const EdgeInsets.only(bottom: 8), decoration: _neonBox(online ? _cyan : _blue, radius: 16), child: ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2), leading: Stack(children: [_playerAvatar(player, radius: 22, accent: online ? _cyan : _blue), Positioned(right: 0, bottom: 0, child: Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, color: online ? const Color(0xFF20E070) : const Color(0xFF667085), border: Border.all(color: _panel, width: 2))))]), title: Text(player.gamerTag, style: const TextStyle(fontWeight: FontWeight.w900)), subtitle: Text(online ? 'Online' : 'Offline', style: TextStyle(color: online ? const Color(0xFF20E070) : _muted, fontSize: 11)), trailing: IconButton(tooltip: 'Message', onPressed: () => open(ChatPage(player: player)), icon: const Icon(Icons.chat_bubble_outline, color: _purple))));
        }),
      ])),
    );
  }
}

