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
import 'package:url_launcher/url_launcher.dart';
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
    final bg = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color(0xFF07111F),
          Color(0xFF0A1626),
          Color(0xFF050B14),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, bg);

    // Clean football-pitch inspired background. No large neon streaks.
    final line = Paint()
      ..color = const Color(0x1426D9FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    final center = Offset(size.width / 2, size.height * .52);
    final radius = size.width * .23;
    canvas.drawCircle(center, radius, line);
    canvas.drawLine(
      Offset(0, center.dy),
      Offset(size.width, center.dy),
      line,
    );

    final boxW = size.width * .32;
    final boxH = size.height * .11;
    canvas.drawRect(
      Rect.fromCenter(center: Offset(0, center.dy), width: boxW, height: boxH),
      line,
    );
    canvas.drawRect(
      Rect.fromCenter(
        center: Offset(size.width, center.dy),
        width: boxW,
        height: boxH,
      ),
      line,
    );

    final glow = Paint()
      ..color = const Color(0x0B00D9FF)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 55);
    canvas.drawCircle(Offset(size.width * .12, size.height * .18), 90, glow);
    canvas.drawCircle(Offset(size.width * .86, size.height * .82), 100, glow);
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
          if (child != null)
            DefaultTextStyle.merge(
              style: const TextStyle(decoration: TextDecoration.none),
              child: child!,
            ),
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
  final DateTime? startDate;
  final DateTime? endDate;
  final String fixtureMode;
  final bool matchDayDateControlsEnabled;
  final bool sequentialMatchDayLockEnabled;
  final bool gracePeriodEnabled;

  const LeagueInfo({
    required this.id,
    required this.name,
    required this.status,
    this.isPaid = false,
    this.entryFee = 0,
    this.currency = 'NGN',
    this.createdAt,
    this.startDate,
    this.endDate,
    this.fixtureMode = 'single_round',
    this.matchDayDateControlsEnabled = true,
    this.sequentialMatchDayLockEnabled = true,
    this.gracePeriodEnabled = true,
  });

  String get feeLabel =>
      isPaid ? '$currency ${entryFee.toStringAsFixed(0)} entry fee' : 'FREE ENTRY';

  bool get isHomeAway => fixtureMode == 'home_away';

  String get fixtureModeLabel =>
      isHomeAway ? 'HOME & AWAY' : 'SINGLE ROUND';
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

class GlobalPlayerStat {
  final Player player;
  int leagues;
  int played;
  int won;
  int drawn;
  int lost;
  int goals;
  int conceded;
  int cleanSheets;
  int points;

  GlobalPlayerStat({
    required this.player,
    this.leagues = 0,
    this.played = 0,
    this.won = 0,
    this.drawn = 0,
    this.lost = 0,
    this.goals = 0,
    this.conceded = 0,
    this.cleanSheets = 0,
    this.points = 0,
  });

  int get gd => goals - conceded;
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
  final Map<String, int> pointAdjustments = {};
  final Map<String, double> fineTotals = {};
  final Map<String, bool> suspendedPlayers = {};
  bool matchDayDateControlsEnabled = true;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    matchDayDateControlsEnabled = prefs.getBool('match_day_date_controls_enabled') ?? true;

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
      if (activeLeagueId != null) await loadDisciplineForLeague(activeLeagueId!);
    } catch (_) {}
  }

  Future<void> refreshLeagues() async {
    final data = await supabase
        .from('leagues')
        .select('id, name, status, is_paid, entry_fee, currency, created_at, start_date, end_date, fixture_mode, match_day_date_controls_enabled, sequential_match_day_lock_enabled, grace_period_enabled')
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
          startDate: row['start_date'] == null
              ? null
              : DateTime.tryParse(row['start_date'].toString()),
          endDate: row['end_date'] == null
              ? null
              : DateTime.tryParse(row['end_date'].toString()),
          fixtureMode: row['fixture_mode']?.toString() ?? 'single_round',
          matchDayDateControlsEnabled: row['match_day_date_controls_enabled'] != false,
          sequentialMatchDayLockEnabled: row['sequential_match_day_lock_enabled'] != false,
          gracePeriodEnabled: row['grace_period_enabled'] != false,
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
      await loadDisciplineForLeague(league.id);
      return null;
    } catch (e) {
      return 'Could not load league: $e';
    }
  }

  Future<String?> createLeague(String name, {required bool isPaid, required double entryFee, String currency = 'NGN', String fixtureMode = 'single_round'}) async {
    final clean = name.trim();
    if (clean.isEmpty) return 'League name is required.';
    if (Store.instance.current?.admin != true) return 'Admin access required.';
    if (isPaid && entryFee <= 0) return 'Enter a valid entry fee for a paid league.';
    if (!isPaid) entryFee = 0;
    try {
      await supabase.from('leagues').insert({'name': clean, 'status': 'open', 'is_paid': isPaid, 'entry_fee': entryFee, 'currency': currency, 'fixture_mode': fixtureMode});
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
          startTime: row['match_start_time']?.toString() ?? '00:00:00',
          endTime: row['match_end_time']?.toString() ?? '23:59:59',
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
    await loadDisciplineForLeague(leagueId);

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

  Future<String?> setMatchDayDateControlsEnabled(bool enabled) async {
    if (current?.admin != true) return 'Admin access required.';
    matchDayDateControlsEnabled = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('match_day_date_controls_enabled', enabled);
      return null;
    } catch (e) {
      return 'Could not save Match Day date-control setting: $e';
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
        File(file.path),
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
    if (leagueId == null) return 'No league selected.';

    final league = leagues.where((l) => l.id == leagueId).firstOrNull;
    if (league == null || league.status != 'active') {
      return 'Select an ACTIVE league before generating fixtures.';
    }

    final memberIds = await leagueMemberIds(leagueId);
    final activePlayers =
        players.where((p) => !p.admin && memberIds.contains(p.id)).toList();

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
    final firstLegRounds = total - 1;
    final rotation = List<String>.from(ids);
    final rows = <Map<String, dynamic>>[];

    for (int roundIndex = 0; roundIndex < firstLegRounds; roundIndex++) {
      for (int i = 0; i < total ~/ 2; i++) {
        final first = rotation[i];
        final second = rotation[total - 1 - i];
        if (first == 'BYE' || second == 'BYE') continue;

        final homeId = roundIndex.isEven ? first : second;
        final awayId = roundIndex.isEven ? second : first;

        rows.add({
          'league_id': leagueId,
          'round': roundIndex + 1,
          'home_player_id': homeId,
          'away_player_id': awayId,
          'status': 'scheduled',
          'match_start_time': '00:00:00',
          'match_end_time': '23:59:59',
        });
      }
      rotation.insert(1, rotation.removeLast());
    }

    if (league.isHomeAway) {
      final firstLegRows = List<Map<String, dynamic>>.from(rows);
      for (final row in firstLegRows) {
        rows.add({
          'league_id': leagueId,
          'round': firstLegRounds + (row['round'] as int),
          'home_player_id': row['away_player_id'],
          'away_player_id': row['home_player_id'],
          'status': 'scheduled',
          'match_start_time': '00:00:00',
          'match_end_time': '23:59:59',
        });
      }
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



  Future<void> loadDisciplineForLeague(String leagueId) async {
    pointAdjustments.clear();
    fineTotals.clear();
    suspendedPlayers.clear();
    try {
      final data = await supabase
          .from('league_player_status')
          .select('player_id, points_adjustment, fine_total, is_suspended')
          .eq('league_id', leagueId);
      for (final item in (data as List)) {
        final row = Map<String, dynamic>.from(item);
        final id = row['player_id']?.toString();
        if (id == null) continue;
        pointAdjustments[id] = (row['points_adjustment'] as num?)?.toInt() ?? 0;
        fineTotals[id] = (row['fine_total'] as num?)?.toDouble() ?? 0;
        suspendedPlayers[id] = row['is_suspended'] == true;
      }
    } catch (e) {
      debugPrint('Discipline load failed: $e');
    }
  }

  bool isSuspended(String playerId) => suspendedPlayers[playerId] == true;

  Future<String?> _writeDisciplinaryAction({
    required String leagueId,
    required String playerId,
    required String actionType,
    String reason = '',
    int pointsDelta = 0,
    double fineAmount = 0,
    bool? suspended,
  }) async {
    if (current?.admin != true) return 'Admin access required.';
    try {
      final existing = await supabase
          .from('league_player_status')
          .select('points_adjustment, fine_total, is_suspended')
          .eq('league_id', leagueId)
          .eq('player_id', playerId)
          .maybeSingle();

      final oldPoints = (existing?['points_adjustment'] as num?)?.toInt() ?? 0;
      final oldFine = (existing?['fine_total'] as num?)?.toDouble() ?? 0;
      final oldSuspended = existing?['is_suspended'] == true;

      final newSuspended = suspended ?? oldSuspended;
      final newPoints = oldPoints + pointsDelta;
      final newFine = oldFine + fineAmount;

      await supabase.from('league_player_status').upsert({
        'league_id': leagueId,
        'player_id': playerId,
        'points_adjustment': newPoints,
        'fine_total': newFine,
        'is_suspended': newSuspended,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'league_id,player_id');

      await supabase.from('disciplinary_actions').insert({
        'league_id': leagueId,
        'player_id': playerId,
        'admin_id': current!.id,
        'action_type': actionType,
        'reason': reason.trim(),
        'points_delta': pointsDelta,
        'fine_amount': fineAmount,
        'suspended': newSuspended,
      });

      await loadDisciplineForLeague(leagueId);
      return null;
    } on PostgrestException catch (e) {
      return 'Could not apply disciplinary action: ${e.message}';
    } catch (e) {
      return 'Could not apply disciplinary action: $e';
    }
  }

  Future<String?> suspendPlayer({
    required String leagueId,
    required String playerId,
    required String reason,
  }) => _writeDisciplinaryAction(
        leagueId: leagueId,
        playerId: playerId,
        actionType: 'suspend',
        reason: reason,
        suspended: true,
      );

  Future<String?> unsuspendPlayer({
    required String leagueId,
    required String playerId,
    required String reason,
  }) => _writeDisciplinaryAction(
        leagueId: leagueId,
        playerId: playerId,
        actionType: 'unsuspend',
        reason: reason,
        suspended: false,
      );

  Future<String?> deductPlayerPoints({
    required String leagueId,
    required String playerId,
    required int points,
    required String reason,
  }) => _writeDisciplinaryAction(
        leagueId: leagueId,
        playerId: playerId,
        actionType: 'points_deduction',
        reason: reason,
        pointsDelta: -points.abs(),
      );

  Future<String?> finePlayer({
    required String leagueId,
    required String playerId,
    required double amount,
    required String reason,
  }) => _writeDisciplinaryAction(
        leagueId: leagueId,
        playerId: playerId,
        actionType: 'fine',
        reason: reason,
        fineAmount: amount,
      );

  // ============================================================
  // MATCH DAY ACCESS CONTROL
  // ============================================================

  DateTime? _matchDayDate(MatchItem match) {
    final raw = match.scheduledDate?.trim();
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  bool isMatchDayCompleted(int round, String playerId) {
    final dayMatches = matches.where((m) =>
        m.round == round && (m.homeId == playerId || m.awayId == playerId));
    if (dayMatches.isEmpty) return true;
    return dayMatches.every((m) => m.status == 'Confirmed');
  }

  bool previousMatchDaysCompleted(int round, String playerId) {
    if (round <= 1) return true;
    for (int day = 1; day < round; day++) {
      if (!isMatchDayCompleted(day, playerId)) return false;
    }
    return true;
  }

  String matchDayState(MatchItem match, {String? playerId}) {
    final player = playerId ?? current?.id;
    if (player == null) return 'locked';
    if (match.status == 'Confirmed') return 'completed';

    final league = leagues.where((l) => l.id == activeLeagueId).firstOrNull;
    final sequentialEnabled = league?.sequentialMatchDayLockEnabled ?? true;
    final dateControlsEnabled = league?.matchDayDateControlsEnabled ?? matchDayDateControlsEnabled;
    // A player cannot jump ahead while an earlier Match Day is incomplete.
    if (sequentialEnabled && !previousMatchDaysCompleted(match.round, player)) return 'locked';
    if (!dateControlsEnabled) return 'open';

    final date = _matchDayDate(match);
    if (date == null) return 'locked';

    final now = DateTime.now();
    final openAt = DateTime(date.year, date.month, date.day);
    final closeAt = openAt.add(const Duration(days: 1));
    final graceEnabled = league?.gracePeriodEnabled ?? true;
    final graceEnd = closeAt.add(const Duration(hours: 5));

    if (now.isBefore(openAt)) return 'locked';
    if (now.isBefore(closeAt)) return 'open';
    if (graceEnabled && now.isBefore(graceEnd)) return 'grace';
    return 'expired';
  }

  bool canSubmitMatch(MatchItem match, {String? playerId}) {
    final player = playerId ?? current?.id;
    if (player == null) return false;
    if (player != match.homeId && player != match.awayId) return false;
    if (match.status == 'Confirmed') return false;
    final state = matchDayState(match, playerId: player);
    return state == 'open' || state == 'grace';
  }

  String matchDayAccessMessage(MatchItem match, {String? playerId}) {
    final player = playerId ?? current?.id;
    if (player == null) return 'Please log in again.';
    if (match.status == 'Confirmed') return 'This match has already been confirmed.';
    final league = leagues.where((l) => l.id == activeLeagueId).firstOrNull;
    final sequentialEnabled = league?.sequentialMatchDayLockEnabled ?? true;
    final dateControlsEnabled = league?.matchDayDateControlsEnabled ?? matchDayDateControlsEnabled;
    if (sequentialEnabled && !previousMatchDaysCompleted(match.round, player)) {
      final previous = <int>[];
      for (int day = 1; day < match.round; day++) {
        if (!isMatchDayCompleted(day, player)) previous.add(day);
      }
      return 'Match Day ${previous.isNotEmpty ? previous.first : match.round - 1} is not completed. Complete it before Match Day ${match.round} can be opened.';
    }
    if (!dateControlsEnabled) return 'Date controls are OFF for this league. This fixture is open for submission.';
    final date = _matchDayDate(match);
    if (date == null) return 'This Match Day has not been scheduled yet.';
    final now = DateTime.now();
    final openAt = DateTime(date.year, date.month, date.day);
    final closeAt = openAt.add(const Duration(days: 1));
    final graceEnd = closeAt.add(const Duration(hours: 5));
    if (now.isBefore(openAt)) return 'Match Day ${match.round} opens on ${match.scheduledDate}.';
    if (now.isBefore(closeAt)) return 'Match Day ${match.round} is open. You have until 11:59 PM to complete it.';
    if (now.isBefore(graceEnd)) return 'WARNING: Match Day ${match.round} has expired. You are in the 5-hour grace period. Complete it before the grace period ends or a penalty may apply.';
    return 'Match Day ${match.round} has expired. Complete it and contact admin about the penalty before continuing.';
  }

  // ============================================================
  // LEAGUE CREATOR REQUESTS
  // ============================================================

  Future<Map<String, dynamic>?> myLeagueCreatorPermission() async {
    final me = current;
    if (me == null) return null;
    try {
      final result = await supabase.rpc('get_my_league_creator_permission');
      if (result == null) return null;
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      debugPrint('Creator permission lookup failed: $e');
      return null;
    }
  }

  Future<String?> submitLeagueRequest({
    required String leagueName,
    required String batchName,
    String description = '',
    bool isPaid = false,
    double entryFee = 0,
    String currency = 'NGN',
    String fixtureMode = 'single_round',
  }) async {
    final cleanName = leagueName.trim();
    final cleanBatch = batchName.trim();
    if (current == null) return 'Please log in again.';
    if (cleanName.isEmpty) return 'League name is required.';
    if (cleanBatch.isEmpty) return 'Batch is required.';
    if (isPaid && entryFee <= 0) return 'Enter a valid entry fee.';
    try {
      await supabase.rpc('submit_league_request', params: {
        'p_league_name': cleanName,
        'p_batch_name': cleanBatch,
        'p_description': description.trim(),
        'p_is_paid': isPaid,
        'p_entry_fee': isPaid ? entryFee : 0,
        'p_currency': currency,
        'p_fixture_mode': fixtureMode,
      });
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return 'Could not submit league request: $e';
    }
  }

  Future<List<Map<String, dynamic>>> fetchLeagueRequests() async {
    if (current?.admin != true) return [];
    final data = await supabase
        .from('league_requests')
        .select('id, requested_by, league_name, batch_name, description, is_paid, entry_fee, currency, fixture_mode, status, admin_note, created_at, reviewed_at')
        .order('created_at', ascending: false);
    return (data as List).map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<String?> reviewLeagueRequest({
    required String requestId,
    required String decision,
    String note = '',
  }) async {
    if (current?.admin != true) return 'Admin access required.';
    try {
      await supabase.rpc('admin_review_league_request', params: {
        'p_request_id': requestId,
        'p_decision': decision,
        'p_note': note.trim(),
      });
      await refreshLeagues();
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return 'Could not review league request: $e';
    }
  }

  Future<String?> setPlayerCreatorBatch({
    required String playerId,
    required String batchName,
    required bool canCreate,
  }) async {
    if (current?.admin != true) return 'Admin access required.';
    try {
      await supabase.rpc('admin_set_player_creator_batch', params: {
        'p_player_id': playerId,
        'p_batch_name': batchName.trim(),
        'p_can_create': canCreate,
      });
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return 'Could not update creator batch access: $e';
    }
  }

  Future<String?> reportMatch({
    required MatchItem match,
    required String reason,
  }) async {
    final reporter = current;
    if (reporter == null) return 'Please log in again.';
    if (reporter.id != match.homeId && reporter.id != match.awayId) {
      return 'Only players in this fixture can report it.';
    }
    final opponentId = reporter.id == match.homeId ? match.awayId : match.homeId;
    try {
      await supabase.from('match_reports').insert({
        'match_id': match.id,
        'league_id': activeLeagueId,
        'reporter_id': reporter.id,
        'reported_player_id': opponentId,
        'reason': reason.trim(),
      });
      return null;
    } on PostgrestException catch (e) {
      return 'Could not submit report: ${e.message}';
    } catch (e) {
      return 'Could not submit report: $e';
    }
  }

  Future<String?> updateLeagueDates({
    required String leagueId,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    if (current?.admin != true) return 'Admin access required.';
    if (startDate != null && endDate != null && endDate.isBefore(startDate)) {
      return 'End date cannot be before start date.';
    }
    try {
      await supabase.from('leagues').update({
        'start_date': startDate?.toIso8601String().split('T').first,
        'end_date': endDate?.toIso8601String().split('T').first,
      }).eq('id', leagueId);
      await refreshLeagues();
      return null;
    } on PostgrestException catch (e) {
      return 'Could not save league dates: ${e.message}';
    } catch (e) {
      return 'Could not save league dates: $e';
    }
  }

  Future<String?> updateMatchDayControls({
    required String leagueId,
    bool? sequentialLockEnabled,
    bool? graceEnabled,
    bool? dateControlsEnabled,
  }) async {
    if (current?.admin != true) return 'Admin access required.';
    final payload = <String, dynamic>{};
    if (sequentialLockEnabled != null) payload['sequential_match_day_lock_enabled'] = sequentialLockEnabled;
    if (graceEnabled != null) payload['grace_period_enabled'] = graceEnabled;
    if (dateControlsEnabled != null) payload['match_day_date_controls_enabled'] = dateControlsEnabled;
    if (payload.isEmpty) return null;
    try {
      await supabase.from('leagues').update(payload).eq('id', leagueId);
      await refreshLeagues();
      return null;
    } on PostgrestException catch (e) {
      return 'Could not update Match Day controls: ${e.message}';
    } catch (e) {
      return 'Could not update Match Day controls: $e';
    }
  }

  Future<String?> updateRoundSchedule({
    required String leagueId,
    required int round,
    required String? scheduledDate,
    required String startTime,
    required String endTime,
  }) async {
    if (current?.admin != true) return 'Admin access required.';

    try {
      await supabase.rpc(
        'admin_set_match_day_schedule',
        params: {
          'p_league_id': leagueId,
          'p_round': round,
          'p_scheduled_date': scheduledDate,
          'p_start_time': startTime,
          'p_end_time': endTime,
        },
      );

      if (activeLeagueId == leagueId) {
        await loadMatchesFromSupabase();
      }

      return null;
    } on PostgrestException catch (e) {
      return 'Could not save Match Day $round date: ${e.message}';
    } catch (e) {
      return 'Could not save Match Day $round date: $e';
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
    if (!canSubmitMatch(match, playerId: player.id)) {
      return matchDayAccessMessage(match, playerId: player.id);
    }
    if (activeLeagueId != null) {
      await loadDisciplineForLeague(activeLeagueId!);
      if (isSuspended(player.id)) {
        return 'You are suspended from this league and cannot submit this result.';
      }
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

    for (final entry in table.entries) {
      entry.value['gd'] = entry.value['gf']! - entry.value['ga']!;
      entry.value['points'] =
          entry.value['points']! + (pointAdjustments[entry.key] ?? 0);
    }

    return table;
  }

  /// Aggregates confirmed results across EVERY league. This is intentionally
  /// separate from [matches], because [matches] contains only the selected
  /// league for the normal fixtures/table screens.
  Future<List<GlobalPlayerStat>> globalLeaderboard() async {
    final result = <String, GlobalPlayerStat>{};

    for (final player in players.where((p) => !p.admin)) {
      result[player.id] = GlobalPlayerStat(player: player);
    }

    try {
      final membershipRows = await supabase
          .from('league_members')
          .select('league_id, player_id');
      final leagueSets = <String, Set<String>>{};
      for (final item in (membershipRows as List)) {
        final row = Map<String, dynamic>.from(item);
        final playerId = row['player_id']?.toString();
        final leagueId = row['league_id']?.toString();
        if (playerId == null || leagueId == null) continue;
        if (result.containsKey(playerId)) {
          leagueSets.putIfAbsent(playerId, () => <String>{}).add(leagueId);
        }
      }
      for (final entry in leagueSets.entries) {
        result[entry.key]?.leagues = entry.value.length;
      }

      final rows = await supabase
          .from('matches')
          .select('league_id, home_player_id, away_player_id, home_score, away_score, status')
          .eq('status', 'confirmed');

      for (final item in (rows as List)) {
        final row = Map<String, dynamic>.from(item);
        final homeId = row['home_player_id']?.toString();
        final awayId = row['away_player_id']?.toString();
        final home = homeId == null ? null : result[homeId];
        final away = awayId == null ? null : result[awayId];
        if (home == null || away == null) continue;

        final hs = (row['home_score'] as num?)?.toInt() ?? 0;
        final as = (row['away_score'] as num?)?.toInt() ?? 0;
        home.played++;
        away.played++;
        home.goals += hs;
        home.conceded += as;
        away.goals += as;
        away.conceded += hs;
        if (as == 0) home.cleanSheets++;
        if (hs == 0) away.cleanSheets++;

        if (hs > as) {
          home.won++;
          away.lost++;
          home.points += 3;
        } else if (hs < as) {
          away.won++;
          home.lost++;
          away.points += 3;
        } else {
          home.drawn++;
          away.drawn++;
          home.points++;
          away.points++;
        }
      }
    } on PostgrestException catch (e) {
      debugPrint('Global leaderboard load failed: ${e.message}');
    } catch (e) {
      debugPrint('Global leaderboard load failed: $e');
    }

    final list = result.values.toList();
    list.sort((a, b) {
      final points = b.points.compareTo(a.points);
      if (points != 0) return points;
      final gd = b.gd.compareTo(a.gd);
      if (gd != 0) return gd;
      final goals = b.goals.compareTo(a.goals);
      if (goals != 0) return goals;
      return a.player.gamerTag.toLowerCase().compareTo(b.player.gamerTag.toLowerCase());
    });
    return list;
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
        const SizedBox(height: 10),
        _neonAction(context, Icons.public, 'GLOBAL LEADERBOARD', 'Combine points across every league', _cyan, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GlobalLeaderboardPage()))),
        const SizedBox(height: 10),
        _neonAction(context, Icons.add_business, 'REQUEST A LEAGUE', 'Eligible batch players can request a league for admin approval', _purple, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LeagueRequestPage()))),
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
        onTap: () async {
          final playerId = store.current?.id;
          final canOpen = playerId != null && store.canSubmitMatch(m, playerId: playerId);
          if (canOpen || m.status == 'Confirmed' || m.status == 'Awaiting Confirmation' || m.status == 'Disputed') {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => ResultPage(match: m)));
            if (mounted) setState(() {});
          } else if (playerId != null) {
            showDialog<void>(
              context: context,
              builder: (_) => AlertDialog(
                title: Text('MATCH DAY ${m.round}'),
                content: Text(store.matchDayAccessMessage(m, playerId: playerId)),
                actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
              ),
            );
          }
        },
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
            if (store.current != null && (store.current!.id == m.homeId || store.current!.id == m.awayId)) ...[
              Builder(builder: (_) {
                final state = store.matchDayState(m, playerId: store.current!.id);
                final stateText = state == 'open' ? 'OPEN • SUBMIT RESULT' :
                    state == 'grace' ? '⚠ GRACE PERIOD • COMPLETE NOW' :
                    state == 'locked' ? '🔒 LOCKED • COMPLETE PREVIOUS DAY' :
                    state == 'expired' ? '⚠ EXPIRED • CONTACT ADMIN' : 'COMPLETED';
                final stateColor = state == 'open' ? _cyan : state == 'grace' ? _yellow : state == 'completed' ? _yellow : const Color(0xFFFF4D7D);
                return Container(width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10), decoration: BoxDecoration(color: stateColor.withOpacity(.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: stateColor.withOpacity(.35))), child: Text(stateText, textAlign: TextAlign.center, style: TextStyle(color: stateColor, fontSize: 10, fontWeight: FontWeight.w900)));
              }),
              const SizedBox(height: 8),
            ],
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.touch_app, size: 13, color: accent),
              const SizedBox(width: 5),
              Text(m.status == 'Scheduled' ? 'TAP TO SUBMIT / VIEW ACCESS' : 'TAP TO VIEW RESULT', style: TextStyle(color: accent, fontSize: 9, fontWeight: FontWeight.w900)),
            ]),
            if (store.current != null &&
                (store.current!.id == m.homeId || store.current!.id == m.awayId)) ...[
              const SizedBox(height: 9),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (home == null || away == null)
                          ? null
                          : () {
                              final opponent =
                                  store.current!.id == m.homeId ? away : home;
                              if (opponent != null) {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => ChatPage(player: opponent),
                                  ),
                                );
                              }
                            },
                      icon: const Icon(Icons.chat_bubble_outline, size: 16),
                      label: const Text('CHAT'),
                    ),
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (home == null || away == null ||
                              (store.current!.id == m.homeId
                                  ? away.whatsappNumber
                                  : home.whatsappNumber).trim().isEmpty)
                          ? null
                          : () async {
                              final opponent =
                                  store.current!.id == m.homeId ? away : home;
                              if (opponent == null) return;
                              final raw = opponent.whatsappNumber.trim();
                              final digits = raw.replaceAll(RegExp(r'[^0-9+]'), '');
                              var normalized = digits.startsWith('+')
                                  ? digits.substring(1)
                                  : digits;
                              if (!normalized.startsWith('234') &&
                                  normalized.startsWith('0') &&
                                  opponent.countryCode.trim().isEmpty) {
                                normalized = '234${normalized.substring(1)}';
                              } else if (!normalized.startsWith('234') &&
                                  normalized.startsWith('0') &&
                                  opponent.countryCode.trim().isNotEmpty) {
                                final cc = opponent.countryCode.replaceAll(RegExp(r'[^0-9]'), '');
                                normalized = '$cc${normalized.substring(1)}';
                              }
                              final uri = Uri.parse('https://wa.me/$normalized');
                              await launchUrl(uri, mode: LaunchMode.externalApplication);
                            },
                      icon: const Icon(Icons.phone, size: 16),
                      label: const Text('WHATSAPP'),
                    ),
                  ),
                  const SizedBox(width: 7),
                  IconButton(
                    tooltip: 'Remind opponent',
                    onPressed: (home == null || away == null)
                        ? null
                        : () async {
                            final opponent =
                                store.current!.id == m.homeId ? away : home;
                            if (opponent == null) return;
                            final message =
                                'Reminder: we have a CHIBBYBALL match on Match Day ${m.round} on ${m.scheduledDate ?? 'the scheduled date'}.';
                            final error = await store.sendMessage(opponent.id, message);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    error ?? 'Match reminder sent to ${opponent.gamerTag}.',
                                  ),
                                ),
                              );
                            }
                          },
                    icon: const Icon(Icons.notifications_active_outlined, color: _yellow),
                  ),
                  const SizedBox(width: 2),
                  IconButton(
                    tooltip: 'Report match issue',
                    onPressed: () => _reportMatch(m),
                    icon: const Icon(Icons.flag_outlined, color: Color(0xFFFF4D7D)),
                  ),
                ],
              ),
            ],
          ]),
        ),
      ),
    );
  }

  Future<void> _reportMatch(MatchItem match) async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('REPORT MATCH'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: const InputDecoration(
            labelText: 'Reason',
            hintText: 'Example: opponent did not show up.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('REPORT'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (reason == null || reason.trim().isEmpty) return;
    final error = await Store.instance.reportMatch(match: match, reason: reason);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error ?? 'Report submitted to the admin.')),
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
    if (startTime == '00:00:00' && (endTime == '23:59:59' || endTime == '23:59:00')) return '$date • ALL DAY + 5H GRACE';
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
    if (!Store.instance.canSubmitMatch(widget.match, playerId: player.id)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Store.instance.matchDayAccessMessage(widget.match, playerId: player.id))));
      return;
    }

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
            enabled: Store.instance.current != null && Store.instance.canSubmitMatch(widget.match, playerId: Store.instance.current!.id),
            controller: homeController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: '${store.playerName(match.homeId)} score',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 15),
          TextField(
            enabled: Store.instance.current != null && Store.instance.canSubmitMatch(widget.match, playerId: Store.instance.current!.id),
            controller: awayController,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: '${store.playerName(match.awayId)} score',
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: (loading || Store.instance.current == null || !Store.instance.canSubmitMatch(widget.match, playerId: Store.instance.current!.id)) ? null : chooseProof,
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
            onPressed: (loading || Store.instance.current == null || !Store.instance.canSubmitMatch(widget.match, playerId: Store.instance.current!.id)) ? null : submit,
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

  @override
  State<TablePage> createState() => _TablePageState();
}

class _TablePageState extends State<TablePage> {
  bool loading = false;

  Future<void> _selectLeague(String? id) async {
    if (id == null || id == Store.instance.activeLeagueId) return;
    setState(() => loading = true);
    final error = await Store.instance.selectLeague(id);
    if (!mounted) return;
    setState(() => loading = false);
    if (error != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Color _rankColor(int rank) =>
      rank == 1 ? _yellow : rank == 2 ? _cyan : rank == 3 ? _purple : _blue;

  Widget _statHeader(String text, {Color color = _muted}) {
    return SizedBox(
      width: 31,
      child: Center(
        child: Text(
          text,
          maxLines: 1,
          softWrap: false,
          style: TextStyle(
            color: color,
            fontSize: 9,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }

  Widget _statValue(String text, Color color) {
    return SizedBox(
      width: 31,
      child: Center(
        child: Text(
          text,
          maxLines: 1,
          softWrap: false,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }

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
        final gf = y['gf']!.compareTo(x['gf']!);
        if (gf != 0) return gf;
        return store
            .playerName(a)
            .toLowerCase()
            .compareTo(store.playerName(b).toLowerCase());
      });

    final selected = store.activeLeagueId == null
        ? null
        : store.leagues
            .where((l) => l.id == store.activeLeagueId)
            .firstOrNull;

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 30),
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 17),
          decoration: BoxDecoration(
            color: const Color(0xEE071525),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: _cyan.withOpacity(.55)),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'CHIBBYBALL COMPETITION',
                style: TextStyle(
                  color: _muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.2,
                ),
              ),
              SizedBox(height: 5),
              Text(
                'LEAGUE TABLE',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 27,
                  fontWeight: FontWeight.w900,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'RANK • COMPETE • WIN',
                style: TextStyle(
                  color: _cyan,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xE9081426),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _cyan.withOpacity(.55)),
          ),
          child: DropdownButtonFormField<String>(
            value: selected?.id,
            dropdownColor: const Color(0xFF081426),
            decoration: const InputDecoration(
              labelText: 'SELECT LEAGUE',
              border: InputBorder.none,
            ),
            items: store.leagues
                .map(
                  (l) => DropdownMenuItem(
                    value: l.id,
                    child: Text('${l.name} • ${l.status.toUpperCase()}'),
                  ),
                )
                .toList(),
            onChanged: loading ? null : _selectLeague,
          ),
        ),
        if (selected != null) ...[
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: Text(
                  selected.name.toUpperCase(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _yellow,
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              if (selected.status == 'active')
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: _cyan.withOpacity(.10),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: _cyan.withOpacity(.55)),
                  ),
                  child: const Text(
                    'ACTIVE',
                    style: TextStyle(
                      color: _cyan,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: 10),
        if (ordered.isEmpty)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _panel,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _cyan.withOpacity(.45)),
            ),
            child: const Text(
              'No players in this league yet.',
              style: TextStyle(color: _muted),
            ),
          )
        else
          Container(
            padding: const EdgeInsets.fromLTRB(7, 8, 7, 7),
            decoration: BoxDecoration(
              color: const Color(0xE9071425),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: _blue.withOpacity(.45)),
            ),
            child: Column(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 9),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0D2139),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 28,
                        child: Center(
                          child: Text(
                            '#',
                            style: TextStyle(
                              color: _yellow,
                              fontSize: 9,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 5),
                      const SizedBox(width: 36),
                      const Expanded(
                        child: Text(
                          'PLAYER',
                          maxLines: 1,
                          softWrap: false,
                          style: TextStyle(
                            color: _muted,
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      _statHeader('P'),
                      _statHeader('W'),
                      _statHeader('D'),
                      _statHeader('L'),
                      _statHeader('GD'),
                      _statHeader('PTS', color: _yellow),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                for (int i = 0; i < ordered.length; i++)
                  Builder(
                    builder: (_) {
                      final id = ordered[i];
                      final row = table[id]!;
                      final player = store.findPlayer(id);
                      final rank = i + 1;
                      final accent = _rankColor(rank);

                      return Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xE90A1729),
                          borderRadius: BorderRadius.circular(13),
                          border: Border.all(
                            color: accent.withOpacity(
                              rank <= 3 ? .70 : .28,
                            ),
                          ),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(13),
                          onTap: player == null
                              ? null
                              : () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) =>
                                          PlayerStatsPageFor(player: player),
                                    ),
                                  ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 28,
                                  child: Center(
                                    child: Text(
                                      '$rank',
                                      style: TextStyle(
                                        color: accent,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 5),
                                _playerAvatar(
                                  player,
                                  radius: 18,
                                  accent: accent,
                                ),
                                const SizedBox(width: 7),
                                Expanded(
                                  child: Text(
                                    store.playerName(id),
                                    maxLines: 1,
                                    softWrap: false,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                                _statValue('${row['played']}', accent),
                                _statValue('${row['won']}', accent),
                                _statValue('${row['drawn']}', accent),
                                _statValue('${row['lost']}', accent),
                                _statValue('${row['gd']}', accent),
                                _statValue('${row['points']}', _yellow),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
          ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: _panel,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _blue.withOpacity(.40)),
          ),
          child: const Row(
            children: [
              Icon(Icons.touch_app, color: _cyan, size: 17),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Tap a player to view confirmed match history and detailed stats.',
                  style: TextStyle(color: _muted, fontSize: 11, height: 1.3),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Only CONFIRMED matches count toward the selected league table.',
          style: TextStyle(color: _muted, fontSize: 10),
        ),
      ],
    );
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
    final online = player.isOnline && (player.lastSeen == null || DateTime.now().toUtc().difference(player.lastSeen!.toUtc()).inMinutes < 3);
    return Scaffold(
      appBar: AppBar(title: Text('${player.gamerTag} • STATS')),
      body: ListView(padding: const EdgeInsets.fromLTRB(13, 13, 13, 30), children: [
        Container(padding: const EdgeInsets.fromLTRB(16, 18, 16, 16), decoration: _neonBox(_cyan, radius: 22), child: Row(children: [
          _playerAvatar(player, radius: 42, accent: _cyan), const SizedBox(width: 13),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(player.gamerTag, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)), const SizedBox(height: 5), Text(player.name.isEmpty ? 'CHIBBYBALL PLAYER' : player.name, style: const TextStyle(color: _muted, fontSize: 11)), const SizedBox(height: 8), Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), border: Border.all(color: online ? const Color(0xFF20E070) : _muted)), child: Text(online ? 'ONLINE' : 'OFFLINE', style: TextStyle(color: online ? const Color(0xFF20E070) : _muted, fontSize: 8, fontWeight: FontWeight.w900))) ])),
        ])),
        const SizedBox(height: 14),
        _neonSectionTitle('PLAYER STATISTICS', accent: _yellow), const SizedBox(height: 9),
        GridView.count(crossAxisCount: 4, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), mainAxisSpacing: 7, crossAxisSpacing: 7, childAspectRatio: .95, children: [
          _miniStat('P', stats['played']!, _cyan), _miniStat('W', stats['won']!, _yellow), _miniStat('D', stats['drawn']!, _purple), _miniStat('L', stats['lost']!, const Color(0xFFFF4D7D)),
          _miniStat('GF', stats['gf']!, _cyan), _miniStat('GA', stats['ga']!, _blue), _miniStat('GD', stats['gd']!, _purple), _miniStat('PTS', stats['points']!, _yellow),
        ]),
        const SizedBox(height: 17),
        _neonSectionTitle('CONFIRMED MATCH HISTORY', accent: _cyan), const SizedBox(height: 9),
        if (history.isEmpty) Container(padding: const EdgeInsets.all(18), decoration: _neonBox(_blue, radius: 16), child: const Text('No confirmed matches yet.', style: TextStyle(color: _muted)))
        else ...history.map((m) => Container(margin: const EdgeInsets.only(bottom: 8), decoration: _neonBox(_blue, radius: 15), child: ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 11, vertical: 1), leading: const Icon(Icons.sports_soccer, color: _cyan), title: Text('${store.playerName(m.homeId)}  VS  ${store.playerName(m.awayId)}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w900)), subtitle: Text('MATCHDAY ${m.round} • ${m.status.toUpperCase()}', style: const TextStyle(color: _muted, fontSize: 9)), trailing: Text('${m.homeScore} - ${m.awayScore}', style: const TextStyle(color: _yellow, fontWeight: FontWeight.w900, fontSize: 14))))),
      ]),
    );
  }

  static Widget _miniStat(String label, int value, Color accent) => Container(padding: const EdgeInsets.all(8), decoration: _neonBox(accent, radius: 13), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Text('$value', style: TextStyle(color: accent, fontSize: 18, fontWeight: FontWeight.w900)), const SizedBox(height: 3), Text(label, style: const TextStyle(color: _muted, fontSize: 8, fontWeight: FontWeight.w900))]));
}

// ============================================================
// GLOBAL LEADERBOARD + TOP PERFORMERS
// ============================================================

class GlobalLeaderboardPage extends StatefulWidget {
  const GlobalLeaderboardPage({super.key});
  @override State<GlobalLeaderboardPage> createState() => _GlobalLeaderboardPageState();
}

class _GlobalLeaderboardPageState extends State<GlobalLeaderboardPage> {
  late Future<List<GlobalPlayerStat>> future;

  @override
  void initState() {
    super.initState();
    future = Store.instance.globalLeaderboard();
  }

  void refresh() => setState(() => future = Store.instance.globalLeaderboard());

  Color rankColor(int rank) => rank == 1 ? _yellow : rank == 2 ? _cyan : rank == 3 ? _purple : _blue;

  Widget performerCard(String title, String value, GlobalPlayerStat? stat, IconData icon, Color accent) {
    return Expanded(child: Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.fromLTRB(10, 12, 10, 11),
      decoration: _neonBox(accent, radius: 17),
      child: Column(children: [
        Icon(icon, color: accent, size: 24),
        const SizedBox(height: 7),
        Text(value, style: TextStyle(color: accent, fontSize: 22, fontWeight: FontWeight.w900)),
        const SizedBox(height: 2),
        Text(title, textAlign: TextAlign.center, style: const TextStyle(color: _muted, fontSize: 8.5, fontWeight: FontWeight.w900)),
        const SizedBox(height: 4),
        Text(stat?.player.gamerTag ?? '—', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w900)),
      ]),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Global Leaderboard'), actions: [IconButton(onPressed: refresh, icon: const Icon(Icons.refresh))]),
      body: FutureBuilder<List<GlobalPlayerStat>>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator(color: _cyan));
          final stats = snapshot.data ?? <GlobalPlayerStat>[];
          if (stats.isEmpty) return const Center(child: Text('No players or confirmed results yet.'));

          final goals = [...stats]..sort((a,b) => b.goals.compareTo(a.goals));
          final clean = [...stats]..sort((a,b) => b.cleanSheets.compareTo(a.cleanSheets));
          final wins = [...stats]..sort((a,b) => b.won.compareTo(a.won));

          return RefreshIndicator(
            onRefresh: () async { refresh(); await future; },
            child: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 30), children: [
              Container(padding: const EdgeInsets.fromLTRB(16, 18, 16, 17), decoration: _neonBox(_blue, radius: 22), child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('ALL LEAGUES • ALL PLAYERS', style: TextStyle(color: _muted, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.3)),
                SizedBox(height: 6),
                Text('GLOBAL LEADERBOARD', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900)),
                SizedBox(height: 5),
                Text('POINTS FROM EVERY LEAGUE ARE COMBINED', style: TextStyle(color: _cyan, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: .7)),
              ])),
              const SizedBox(height: 13),
              _neonSectionTitle('TOP PERFORMERS', accent: _yellow),
              const SizedBox(height: 9),
              Row(children: [
                performerCard('MOST GOALS', '${goals.first.goals}', goals.first, Icons.sports_soccer, _yellow),
                performerCard('CLEAN SHEETS', '${clean.first.cleanSheets}', clean.first, Icons.shield, _cyan),
                performerCard('MOST WINS', '${wins.first.won}', wins.first, Icons.emoji_events, _purple),
              ]),
              const SizedBox(height: 16),
              _neonSectionTitle('WORLD RANKING', accent: _cyan),
              const SizedBox(height: 8),
              Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 8), decoration: _neonBox(_blue, radius: 17), child: Column(children: [
                Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8), decoration: BoxDecoration(color: const Color(0xFF0D2139), borderRadius: BorderRadius.circular(11)), child: const Row(children: [
                  SizedBox(width: 30, child: Center(child: Text('#', style: TextStyle(color: _yellow, fontSize: 8, fontWeight: FontWeight.w900)))),
                  SizedBox(width: 39, child: Center(child: Text('PLAYER', style: TextStyle(color: _muted, fontSize: 8, fontWeight: FontWeight.w900)))),
                  Expanded(child: Text('LEAGUES', style: TextStyle(color: _muted, fontSize: 8, fontWeight: FontWeight.w900))),
                  SizedBox(width: 45, child: Center(child: Text('PTS', style: TextStyle(color: _yellow, fontSize: 8, fontWeight: FontWeight.w900)))),
                ])),
                const SizedBox(height: 6),
                for (int i=0;i<stats.length;i++) Builder(builder: (_) {
                  final s = stats[i]; final accent = rankColor(i+1);
                  return Container(margin: const EdgeInsets.only(bottom: 6), decoration: BoxDecoration(color: const Color(0xDD081426), borderRadius: BorderRadius.circular(14), border: Border.all(color: accent.withOpacity(i<3 ? .8 : .35))), child: InkWell(borderRadius: BorderRadius.circular(14), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerStatsPageFor(player: s.player))), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8), child: Row(children: [
                    Container(width: 30, height: 30, decoration: BoxDecoration(shape: BoxShape.circle, color: accent.withOpacity(.13), border: Border.all(color: accent)), child: Center(child: Text('${i+1}', style: TextStyle(color: accent, fontSize: 10, fontWeight: FontWeight.w900)))),
                    const SizedBox(width: 8), _playerAvatar(s.player, radius: 19, accent: accent), const SizedBox(width: 8),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(s.player.gamerTag, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w900)), Text('${s.played} matches • ${s.gd >= 0 ? '+' : ''}${s.gd} GD', style: const TextStyle(color: _muted, fontSize: 9))])),
                    SizedBox(width: 48, child: Column(children: [Text('${s.leagues}', style: const TextStyle(color: _cyan, fontSize: 12, fontWeight: FontWeight.w900)), const Text('LEAGUES', style: TextStyle(color: _muted, fontSize: 7))])),
                    SizedBox(width: 45, child: Text('${s.points}', textAlign: TextAlign.center, style: const TextStyle(color: _yellow, fontSize: 15, fontWeight: FontWeight.w900))),
                  ]))));
                }),
              ])),
              const SizedBox(height: 9),
              const Text('Global points are calculated from CONFIRMED matches across every league.', style: TextStyle(color: _muted, fontSize: 10)),
            ]),
          );
        },
      ),
    );
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
        Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 122,
              height: 122,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(colors: [_cyan, _purple, _yellow]),
                boxShadow: const [BoxShadow(color: Color(0x4400D9FF), blurRadius: 25)],
              ),
              child: CircleAvatar(
                backgroundColor: const Color(0xFF071225),
                backgroundImage: (p?.avatarUrl.isNotEmpty ?? false) ? NetworkImage(p!.avatarUrl) : null,
                child: (p?.avatarUrl.isNotEmpty ?? false)
                    ? null
                    : const Icon(Icons.person, size: 60, color: _muted),
              ),
            ),
            Positioned(
              right: -4,
              bottom: 0,
              child: IconButton.filled(
                onPressed: uploadingAvatar ? null : changeAvatar,
                icon: uploadingAvatar
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.edit),
              ),
            ),
          ],
        ),
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
      const SizedBox(height: 14),
      _neonSectionTitle('ADMIN SUPPORT', accent: _purple),
      const SizedBox(height: 9),
      _neonAction(context, Icons.support_agent, 'CONTACT ADMIN IN APP', 'Private chat directly with an administrator', _purple, () async {
        final admin = Store.instance.players.where((p) => p.admin).firstOrNull;
        if (admin == null) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No administrator is available right now.'))); return; }
        Navigator.push(context, MaterialPageRoute(builder: (_) => ChatPage(player: admin)));
      }),
      const SizedBox(height: 9),
      _neonAction(context, Icons.chat, 'WHATSAPP SUPPORT', 'Chat with CHIBBYBALL support on WhatsApp', const Color(0xFF20E070), () async {
        final uri = Uri.parse('https://wa.me/2348038453858');
        final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (!ok && context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open WhatsApp.')));
      }),
      const SizedBox(height: 12),
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
  String fixtureMode = 'single_round';
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
    final error = await store.createLeague(name, isPaid: isPaidLeague, entryFee: fee, currency: 'NGN', fixtureMode: fixtureMode);
    if (!mounted) return;
    if (error == null) {
      nameController.clear();
      feeController.clear();
      isPaidLeague = false;
      fixtureMode = 'single_round';
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
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('FIXTURE FORMAT', style: TextStyle(fontWeight: FontWeight.bold)),
                    RadioListTile<String>(
                      contentPadding: EdgeInsets.zero,
                      value: 'single_round',
                      groupValue: fixtureMode,
                      title: const Text('Single Round'),
                      subtitle: const Text('Each pair plays once.'),
                      onChanged: loading ? null : (v) => setState(() => fixtureMode = v!),
                    ),
                    RadioListTile<String>(
                      contentPadding: EdgeInsets.zero,
                      value: 'home_away',
                      groupValue: fixtureMode,
                      title: const Text('Home & Away'),
                      subtitle: const Text('Each pair plays twice with a return fixture.'),
                      onChanged: loading ? null : (v) => setState(() => fixtureMode = v!),
                    ),
                  ],
                ),
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
// PLAYER LEAGUE REQUEST
// ============================================================

class LeagueRequestPage extends StatefulWidget {
  const LeagueRequestPage({super.key});
  @override State<LeagueRequestPage> createState() => _LeagueRequestPageState();
}

class _LeagueRequestPageState extends State<LeagueRequestPage> {
  final nameController = TextEditingController();
  final descriptionController = TextEditingController();
  final feeController = TextEditingController();
  bool loading = true;
  bool submitting = false;
  bool isPaid = false;
  String fixtureMode = 'single_round';
  String? batch;
  bool eligible = false;
  String? pendingStatus;

  @override
  void initState() { super.initState(); _load(); }
  @override
  void dispose() { nameController.dispose(); descriptionController.dispose(); feeController.dispose(); super.dispose(); }

  Future<void> _load() async {
    try {
      final permission = await Store.instance.myLeagueCreatorPermission();
      if (permission != null) {
        batch = permission['batch_name']?.toString();
        eligible = permission['can_create'] == true;
        pendingStatus = permission['pending_status']?.toString();
      }
    } catch (_) {}
    if (mounted) setState(() => loading = false);
  }

  Future<void> _submit() async {
    if (!eligible || batch == null) return;
    setState(() => submitting = true);
    final error = await Store.instance.submitLeagueRequest(
      leagueName: nameController.text,
      batchName: batch!,
      description: descriptionController.text,
      isPaid: isPaid,
      entryFee: double.tryParse(feeController.text.trim()) ?? 0,
      fixtureMode: fixtureMode,
    );
    if (!mounted) return;
    setState(() => submitting = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error ?? 'League request sent to admin for approval.')));
    if (error == null) { nameController.clear(); descriptionController.clear(); feeController.clear(); await _load(); }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Request a League')),
      body: loading ? const Center(child: CircularProgressIndicator()) : ListView(padding: const EdgeInsets.all(16), children: [
        Container(padding: const EdgeInsets.all(16), decoration: _neonBox(_purple, radius: 20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('LEAGUE CREATOR ACCESS', style: TextStyle(color: _purple, fontWeight: FontWeight.w900, fontSize: 17)),
          const SizedBox(height: 7),
          Text(batch == null ? 'No creator batch is assigned to your account.' : 'Your batch: ${batch!}', style: const TextStyle(color: _muted)),
          const SizedBox(height: 5),
          Text(eligible ? 'You are eligible to request a league.' : 'Your batch is not currently allowed to create leagues.', style: TextStyle(color: eligible ? _cyan : const Color(0xFFFF4D7D), fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 14),
        if (pendingStatus != null) Card(child: ListTile(leading: const Icon(Icons.hourglass_top, color: _yellow), title: const Text('REQUEST STATUS'), subtitle: Text(pendingStatus!.toUpperCase()))),
        if (!eligible) const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('Ask an administrator to assign your account to an approved creator batch.')))
        else ...[
          TextField(controller: nameController, enabled: !submitting, decoration: const InputDecoration(labelText: 'League name', hintText: 'e.g. CHIBBYBALL Batch 2 League')),
          const SizedBox(height: 12),
          TextField(controller: descriptionController, enabled: !submitting, maxLines: 3, decoration: const InputDecoration(labelText: 'Description (optional)')),
          const SizedBox(height: 12),
          Card(child: Padding(padding: const EdgeInsets.all(10), child: Column(children: [
            SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(isPaid ? 'Paid League' : 'Free League'), value: isPaid, onChanged: submitting ? null : (v) => setState(() => isPaid = v)),
            if (isPaid) TextField(controller: feeController, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Entry fee (NGN)')),
          ]))),
          Card(child: Column(children: [
            const ListTile(title: Text('FIXTURE FORMAT')),
            RadioListTile<String>(value: 'single_round', groupValue: fixtureMode, title: const Text('Single Round'), onChanged: submitting ? null : (v) => setState(() => fixtureMode = v!)),
            RadioListTile<String>(value: 'home_away', groupValue: fixtureMode, title: const Text('Home & Away'), onChanged: submitting ? null : (v) => setState(() => fixtureMode = v!)),
          ])),
          const SizedBox(height: 14),
          FilledButton.icon(onPressed: submitting ? null : _submit, icon: submitting ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.send), label: const Text('SUBMIT FOR ADMIN APPROVAL')),
        ],
      ]),
    );
  }
}

// ============================================================
// ADMIN LEAGUE REQUESTS
// ============================================================

class LeagueRequestsAdminPage extends StatefulWidget {
  const LeagueRequestsAdminPage({super.key});
  @override State<LeagueRequestsAdminPage> createState() => _LeagueRequestsAdminPageState();
}

class _LeagueRequestsAdminPageState extends State<LeagueRequestsAdminPage> {
  bool loading = true;
  List<Map<String, dynamic>> requests = [];
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async { try { requests = await Store.instance.fetchLeagueRequests(); } catch (_) {} if (mounted) setState(() => loading = false); }
  Future<void> _review(Map<String,dynamic> request, String decision) async {
    final noteController = TextEditingController();
    final note = await showDialog<String>(context: context, builder: (_) => AlertDialog(title: Text(decision == 'approved' ? 'Approve League' : 'Reject League'), content: TextField(controller: noteController, maxLines: 3, decoration: const InputDecoration(labelText: 'Admin note (optional)')), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')), FilledButton(onPressed: () => Navigator.pop(context, noteController.text), child: Text(decision == 'approved' ? 'APPROVE' : 'REJECT'))]));
    if (note == null) return;
    setState(() => loading = true);
    final error = await Store.instance.reviewLeagueRequest(requestId: request['id'].toString(), decision: decision, note: note);
    if (mounted) { setState(() => loading = false); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error ?? 'Request $decision.'))); await _load(); }
  }
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('League Requests')), body: loading ? const Center(child: CircularProgressIndicator()) : RefreshIndicator(onRefresh: _load, child: requests.isEmpty ? const Center(child: Text('No league requests.')) : ListView.builder(padding: const EdgeInsets.all(14), itemCount: requests.length, itemBuilder: (_,i) { final r=requests[i]; final status=r['status']?.toString() ?? 'pending'; final requester=Store.instance.playerName(r['requested_by']?.toString() ?? ''); return Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(r['league_name']?.toString() ?? '', style: const TextStyle(fontSize:18,fontWeight:FontWeight.w900)), const SizedBox(height:6), Text('Requested by: $requester'), Text('Batch: ${r['batch_name']}'), if ((r['description']?.toString() ?? '').isNotEmpty) Padding(padding: const EdgeInsets.only(top:5), child: Text(r['description'].toString(), style: const TextStyle(color:_muted))), const SizedBox(height:8), Text('Status: ${status.toUpperCase()}', style: const TextStyle(fontWeight:FontWeight.w800)), if (status == 'pending') Row(children:[Expanded(child:OutlinedButton.icon(onPressed:()=>_review(r,'rejected'), icon:const Icon(Icons.close), label:const Text('REJECT'))), const SizedBox(width:8), Expanded(child:FilledButton.icon(onPressed:()=>_review(r,'approved'), icon:const Icon(Icons.check), label:const Text('APPROVE')))])]))); }));
}

// ============================================================
// ADMIN CREATOR BATCH ACCESS
// ============================================================

class CreatorBatchAdminPage extends StatefulWidget {
  const CreatorBatchAdminPage({super.key});
  @override State<CreatorBatchAdminPage> createState() => _CreatorBatchAdminPageState();
}

class _CreatorBatchAdminPageState extends State<CreatorBatchAdminPage> {
  String? selectedPlayerId;
  final batchController = TextEditingController();
  bool canCreate = true;
  bool loading = false;
  @override void dispose(){ batchController.dispose(); super.dispose(); }
  Future<void> _save() async { if(selectedPlayerId==null || batchController.text.trim().isEmpty)return; setState(()=>loading=true); final e=await Store.instance.setPlayerCreatorBatch(playerId:selectedPlayerId!,batchName:batchController.text,canCreate:canCreate); if(mounted){setState(()=>loading=false); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(e??'Creator batch access saved.')));} }
  @override Widget build(BuildContext context){ final players=Store.instance.players.where((p)=>!p.admin).toList(); return Scaffold(appBar:AppBar(title:const Text('Creator Batch Access')),body:ListView(padding:const EdgeInsets.all(16),children:[DropdownButtonFormField<String>(value:selectedPlayerId,decoration:const InputDecoration(labelText:'PLAYER'),items:players.map((p)=>DropdownMenuItem(value:p.id,child:Text(p.gamerTag))).toList(),onChanged:loading?(v){}:(v)=>setState(()=>selectedPlayerId=v)),const SizedBox(height:12),TextField(controller:batchController,decoration:const InputDecoration(labelText:'Batch name',hintText:'e.g. Batch 1')),SwitchListTile(title:const Text('Allow this batch/player to request leagues'),value:canCreate,onChanged:loading?null:(v)=>setState(()=>canCreate=v)),const SizedBox(height:12),FilledButton.icon(onPressed:loading?null:_save,icon:const Icon(Icons.save),label:const Text('SAVE ACCESS')),const SizedBox(height:20),const Text('Use this screen to assign a player to an approved batch. The player still needs admin approval for every league request.',style:TextStyle(color:_muted))])); }
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
  DateTime? startDate;
  DateTime? endDate;
  bool loading = false;
  final Map<int, DateTime?> roundDates = {};

  @override
  void initState() {
    super.initState();
    selectedLeagueId = store.activeLeagueId ??
        (store.leagues.isNotEmpty ? store.leagues.first.id : null);
    _loadSelectedLeague();
  }

  LeagueInfo? get selected =>
      store.leagues.where((l) => l.id == selectedLeagueId).firstOrNull;

  String _dateForDb(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  String _dateLabel(DateTime? date) =>
      date == null ? 'Not set' : '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

  Future<void> _loadSelectedLeague() async {
    final league = selected;
    if (league == null) return;
    startDate = league.startDate;
    endDate = league.endDate;
    try {
      await store.selectLeague(league.id);
    } catch (_) {}
    roundDates
      ..clear()
      ..addEntries(
        store.matches.map((m) => MapEntry(
              m.round,
              m.scheduledDate == null || m.scheduledDate!.isEmpty
                  ? null
                  : DateTime.tryParse(m.scheduledDate!),
            )),
      );
    if (mounted) setState(() {});
  }

  Future<DateTime?> _pickDate(DateTime? initial) async {
    return showDatePicker(
      context: context,
      initialDate: initial ?? startDate ?? DateTime.now(),
      firstDate: DateTime(2026),
      lastDate: DateTime(2100),
    );
  }

  Future<void> _saveLeagueDates() async {
    final leagueId = selectedLeagueId;
    if (leagueId == null) return;
    setState(() => loading = true);
    final error = await store.updateLeagueDates(
      leagueId: leagueId,
      startDate: startDate,
      endDate: endDate,
    );
    if (!mounted) return;
    setState(() => loading = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error ?? 'League start and end dates saved.')),
    );
  }

  Future<void> _saveRound(int round) async {
    final leagueId = selectedLeagueId;
    if (leagueId == null) return;
    final matchesForRound =
        store.matches.where((m) => m.round == round).toList();
    if (matchesForRound.isEmpty) return;

    setState(() => loading = true);
    final error = await store.updateRoundSchedule(
      leagueId: leagueId,
      round: round,
      scheduledDate: roundDates[round] == null
          ? null
          : _dateForDb(roundDates[round]!),
      startTime: '00:00:00',
      endTime: '23:59:59',
    );
    if (!mounted) return;
    setState(() => loading = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error ?? 'Match Day $round date saved for all its fixtures.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final league = selected;
    final rounds = store.matches.map((m) => m.round).toSet().toList()..sort();

    return Scaffold(
      appBar: AppBar(title: const Text('Match Schedule')),
      body: RefreshIndicator(
        onRefresh: _loadSelectedLeague,
        child: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            const Text(
              'LEAGUE DATES',
              style: TextStyle(
                color: _cyan,
                fontSize: 18,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: selectedLeagueId,
              decoration: const InputDecoration(labelText: 'SELECT LEAGUE'),
              items: store.leagues
                  .map((l) => DropdownMenuItem(
                        value: l.id,
                        child: Text('${l.name} • ${l.status.toUpperCase()}'),
                      ))
                  .toList(),
              onChanged: loading
                  ? null
                  : (value) async {
                      if (value == null) return;
                      setState(() => selectedLeagueId = value);
                      await _loadSelectedLeague();
                    },
            ),
            const SizedBox(height: 10),
            if (league != null)
              Container(
                padding: const EdgeInsets.all(14),
                decoration: _neonBox(_blue, radius: 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      league.fixtureModeLabel,
                      style: const TextStyle(
                        color: _yellow,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Home & Away creates separate first-leg and return fixtures.',
                      style: TextStyle(
                        color: league.isHomeAway ? _cyan : _muted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            Card(
              child: ListTile(
                leading: const Icon(Icons.event),
                title: const Text('START DATE'),
                subtitle: Text(_dateLabel(startDate)),
                onTap: loading
                    ? null
                    : () async {
                        final d = await _pickDate(startDate);
                        if (d != null) setState(() => startDate = d);
                      },
              ),
            ),
            Card(
              child: ListTile(
                leading: const Icon(Icons.event_available),
                title: const Text('END DATE'),
                subtitle: Text(_dateLabel(endDate)),
                onTap: loading
                    ? null
                    : () async {
                        final d = await _pickDate(endDate ?? startDate);
                        if (d != null) setState(() => endDate = d);
                      },
              ),
            ),
            FilledButton.icon(
              onPressed: loading ? null : _saveLeagueDates,
              icon: const Icon(Icons.save),
              label: const Text('SAVE LEAGUE DATES'),
            ),
            const SizedBox(height: 24),
            const Text(
              'MATCH DAY DATES',
              style: TextStyle(
                color: _cyan,
                fontSize: 18,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Every fixture in the same Match Day uses the same date. Each Match Day can have a different date.',
              style: TextStyle(color: _muted, fontSize: 11),
            ),
            const SizedBox(height: 10),
            Container(
              decoration: _neonBox(_yellow, radius: 18),
              child: Column(children: [
                SwitchListTile(
                  value: Store.instance.matchDayDateControlsEnabled,
                  activeThumbColor: _yellow,
                  title: const Text('ENABLE DATE CONTROLS', style: TextStyle(fontWeight: FontWeight.w900)),
                  subtitle: const Text('OFF = fixtures stay open regardless of Match Day dates.'),
                  onChanged: loading ? null : (value) async {
                    setState(() => loading = true);
                    final error = await Store.instance.setMatchDayDateControlsEnabled(value);
                    if (!mounted) return;
                    setState(() => loading = false);
                    if (error != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
                  },
                ),
                SwitchListTile(
                  value: (Store.instance.leagues.where((l) => l.id == Store.instance.activeLeagueId).firstOrNull?.sequentialMatchDayLockEnabled) ?? true,
                  activeThumbColor: _cyan,
                  title: const Text('ENFORCE MATCH DAY ORDER', style: TextStyle(fontWeight: FontWeight.w900)),
                  subtitle: const Text('OFF = players can submit later Match Days without completing earlier ones.'),
                  onChanged: loading ? null : (value) async {
                    final leagueId = Store.instance.activeLeagueId;
                    if (leagueId == null) return;
                    setState(() => loading = true);
                    final error = await Store.instance.updateMatchDayControls(leagueId: leagueId, sequentialLockEnabled: value);
                    if (!mounted) return;
                    await Store.instance.refreshLeagues();
                    setState(() => loading = false);
                    if (error != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
                  },
                ),
                SwitchListTile(
                  value: (Store.instance.leagues.where((l) => l.id == Store.instance.activeLeagueId).firstOrNull?.gracePeriodEnabled) ?? true,
                  activeThumbColor: _purple,
                  title: const Text('ENABLE 5-HOUR GRACE PERIOD', style: TextStyle(fontWeight: FontWeight.w900)),
                  subtitle: const Text('OFF = the grace period is removed; expiry happens at 11:59 PM.'),
                  onChanged: loading ? null : (value) async {
                    final leagueId = Store.instance.activeLeagueId;
                    if (leagueId == null) return;
                    setState(() => loading = true);
                    final error = await Store.instance.updateMatchDayControls(leagueId: leagueId, graceEnabled: value);
                    if (!mounted) return;
                    await Store.instance.refreshLeagues();
                    setState(() => loading = false);
                    if (error != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
                  },
                ),
              ]),
            ),
            const SizedBox(height: 10),
            if (rounds.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Generate fixtures first.'),
                ),
              )
            else
              ...rounds.map(
                (round) => Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: _cyan.withOpacity(.12),
                      child: Text(
                        '$round',
                        style: const TextStyle(color: _cyan),
                      ),
                    ),
                    title: Text('MATCH DAY $round'),
                    subtitle: Text(_dateLabel(roundDates[round])),
                    trailing: const Icon(Icons.calendar_month),
                    onTap: loading
                        ? null
                        : () async {
                            final d = await _pickDate(roundDates[round]);
                            if (d == null) return;
                            setState(() => roundDates[round] = d);
                            await _saveRound(round);
                            // Re-read the server value after saving so the UI
                            // cannot silently keep a local-only date.
                            if (mounted) {
                              await _loadSelectedLeague();
                            }
                          },
                  ),
                ),
              ),
          ],
        ),
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
    try { await store.refreshPlayers(); await store.refreshLeagues(); if (store.leagues.isNotEmpty) { selectedLeagueId ??= store.leagues.first.id; memberIds = (await store.leagueMemberIds(selectedLeagueId!)).toSet(); await store.loadDisciplineForLeague(selectedLeagueId!); } }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load player management: $e'))); }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _selectLeague(String? id) async {
    if (id == null) return; setState(() { selectedLeagueId = id; loading = true; });
    try { memberIds = (await store.leagueMemberIds(id)).toSet(); await store.loadDisciplineForLeague(id); } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load league members: $e'))); }
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

  Future<void> _disciplineDialog(
    Player player, {
    required String action,
  }) async {
    final leagueId = selectedLeagueId;
    if (leagueId == null) return;
    final reasonController = TextEditingController();
    final valueController = TextEditingController();

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(action.toUpperCase()),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (action == 'deduct' || action == 'fine')
              TextField(
                controller: valueController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: action == 'deduct' ? 'Points to deduct' : 'Fine amount (NGN)',
                ),
              ),
            TextField(
              controller: reasonController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Reason',
                hintText: 'Example: Failed to show up for the scheduled match.',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, {
              'value': valueController.text.trim(),
              'reason': reasonController.text.trim(),
            }),
            child: const Text('APPLY'),
          ),
        ],
      ),
    );

    reasonController.dispose();
    valueController.dispose();
    if (result == null) return;

    setState(() => loading = true);
    String? error;
    switch (action) {
      case 'suspend':
        error = await store.suspendPlayer(
          leagueId: leagueId,
          playerId: player.id,
          reason: result['reason'] ?? '',
        );
        break;
      case 'unsuspend':
        error = await store.unsuspendPlayer(
          leagueId: leagueId,
          playerId: player.id,
          reason: result['reason'] ?? '',
        );
        break;
      case 'deduct':
        error = await store.deductPlayerPoints(
          leagueId: leagueId,
          playerId: player.id,
          points: int.tryParse(result['value'] ?? '') ?? 0,
          reason: result['reason'] ?? '',
        );
        break;
      case 'fine':
        error = await store.finePlayer(
          leagueId: leagueId,
          playerId: player.id,
          amount: double.tryParse(result['value'] ?? '') ?? 0,
          reason: result['reason'] ?? '',
        );
        break;
    }
    if (!mounted) return;
    setState(() => loading = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error ?? '${player.gamerTag}: $action applied.')),
    );
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
            const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(player.gamerTag, style: const TextStyle(fontWeight: FontWeight.w900)), Text(online ? 'Online' : 'Offline', style: TextStyle(color: online ? const Color(0xFF20E070) : _muted, fontSize: 11)), const SizedBox(height: 2), Text(isMember ? 'Registered in selected league' : 'Not in selected league', style: const TextStyle(color: _muted, fontSize: 10)),
             if (isMember && store.isSuspended(player.id))
               const Padding(
                 padding: EdgeInsets.only(top: 3),
                 child: Text('SUSPENDED', style: TextStyle(color: Color(0xFFFF4D7D), fontSize: 10, fontWeight: FontWeight.w900)),
               ),
           ])),
            IconButton(tooltip: 'Message', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatPage(player: player))), icon: const Icon(Icons.chat_bubble_outline, color: _purple)),
            if (selectedLeagueId != null) IconButton(tooltip: isMember ? 'Remove from league' : 'Add to league', onPressed: loading ? null : () => _toggleMember(player, !isMember), icon: Icon(isMember ? Icons.remove_circle_outline : Icons.add_circle_outline, color: isMember ? const Color(0xFFFF4D7D) : _cyan)),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'disregister') _disregister(player);
                if (value == 'suspend') _disciplineDialog(player, action: 'suspend');
                if (value == 'unsuspend') _disciplineDialog(player, action: 'unsuspend');
                if (value == 'deduct') _disciplineDialog(player, action: 'deduct');
                if (value == 'fine') _disciplineDialog(player, action: 'fine');
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'suspend', child: Text('Suspend player')),
                PopupMenuItem(value: 'unsuspend', child: Text('Unsuspend player')),
                PopupMenuItem(value: 'deduct', child: Text('Deduct points')),
                PopupMenuItem(value: 'fine', child: Text('Fine player')),
                PopupMenuDivider(),
                PopupMenuItem(value: 'disregister', child: Text('Disregister from all leagues')),
              ],
            ),
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
        _neonAction(context, Icons.fact_check_outlined, 'LEAGUE REQUESTS', 'Approve or reject player league requests', _purple, () => open(const LeagueRequestsAdminPage())),
        const SizedBox(height: 9),
        _neonAction(context, Icons.groups_2_outlined, 'CREATOR BATCH ACCESS', 'Choose which players/batches can request leagues', _cyan, () => open(const CreatorBatchAdminPage())),
        const SizedBox(height: 9),
        _neonAction(context, Icons.calendar_month, 'MATCH SCHEDULE', 'Set date and time windows', _cyan, () => open(const AdminMatchSchedulePage())),
        const SizedBox(height: 9),
        _neonAction(context, Icons.fact_check, 'RESULT REVIEW', 'Confirm or dispute submitted results', _purple, () => open(const ResultReviewPage())),
        const SizedBox(height: 9),
        _neonAction(context, Icons.manage_accounts, 'MANAGE PLAYERS', 'Assign, remove or disregister players', _cyan, () => open(const PlayerManagementPage())),
        const SizedBox(height: 9),
        _neonAction(context, Icons.refresh, 'REFRESH PLAYERS', 'Reload players and league data', _blue, refresh),
        const SizedBox(height: 9),
        _neonAction(context, Icons.auto_awesome, 'GENERATE FIXTURES', 'Create single-round or Home & Away fixtures', _yellow, loading ? () {} : generateFixtures),
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

