import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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


// Embedded Mythic Arena artwork from the approved CHIBBYBALL visual reference.
const String _mythicLoginArtworkBase64 =
    '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' +
    'D8bYcTEig5iyczOqkmO6pxNnFkhK0E7WFt9vI4zuMfVScPm0tm6ctTpa9qbzraGWH4EXJbNSl6Du0in9VhFcVbaUfWIVrSe/TcfH' +
    'r8MDyGipClDt288OviPl5FEq78ZvxaDdKrdR1H5YBKTR2V1VLD39A8CEG3QkbfI2wyecQ+190nSleyBm21sudArXZAoy0QoEjBzl' +
    'ec7GU24y4ptxPRSTYjEX7E9EfeYW0UPEFpaFo3HwPQ4k6FCcW6WAn6zWE/E7YAmkNrbNbiDZVS0uRYCkQsvoVT4c6G0mZmGDreka' +
    'AVcywsonsST88KTPlDk05Umny2rPsL2VbqPT0PXDqcpQfrsiKnZMKmNR0q/Com//AC4xqEKHnWmCNNUhiuw/qite2o9gr0PY4+Xf' +
    'T+OIlZhbKjYmvt4UH9iNXOSnTtBW2l+3bFVF01xqWG/CVG1ik3G+CjJj1MqaXaSh1LEyWA82orOgrQpTaW13NgVjxA9ibdDid4iU' +
    'QZTpEp2bpZmrV7PHQo2JUeqh6JTc38yMKLJtJq1ZrymaHH5xKSh1a9mmm+6lq6JA63xsMRmUziApKqZL12VhVLS5lTQ/5Q68q5QE' +
    'ythqc0pEaOdcm4sQkH7PvJ8I9+ClM1FdzS/UE6fYoV40UJ+yVba1D0FggeiTgfreYXaZRI2WYU8zKgWwJVQtZRFraz3vbwoB3t4j' +
    'joy7HafpyoCFLZZLRaBaVZSQRa4Pn64xGKzS5oZ1WToPU9ug4VjU4bKpZqrb8tBJlDPzc7iDJo8JSFQIsY61gX5r4UNQSfJKb+83' +
    'w4JrRKItUijmOxfEQnfmNH7afXbceoxTak8NMx03iVCo9KedS29d5qoJukIZ6KWbdFJva3c288XKyPRWMvUOFSojr7rMVvQlx9ZW' +
    'tfckn3k4OTKYW04wiTUc6hfvsrga7OEZ1bsyH1qeApW3qOXHjCQ4tZKajVhUyC2VwZ45zKkC4ueqR8Tt78Lea8rJygmNMaRKYSmT' +
    'OS4AtLepQQ2lKe60klZI6Wt2xbKtx2IzLkGUtTFPk3EeSm14jqrjYnp1Nj7x5YpRxjyXmLK9UmKrLbshh90FuehN23Ujpcj7JtbY' +
    '4Y5S459s4QBu9L7No7NxgrOEoDqfy37+PPfEXW40pVRk+2Oc6QVlS3L35hO+q/r1+OOuh0xaas2wwRIUtYQ3ywfGT0tfEllthOZs' +
    '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' +
    'JJVe8f/Z';
const String _mythicDashboardBannerBase64 =
    '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' +
    'CozX/9k=';

class _ChibbyballBackgroundPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final bg = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Color(0xFF100B05),
          Color(0xFF171006),
          Color(0xFF080603),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, bg);

    // Mythic gold-and-blue football arena background. Keep the existing layout and behavior.
    final line = Paint()
      ..color = const Color(0x14FFC928)
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
      ..color = const Color(0x0BFFC928)
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
    const cyan = Color(0xFFFFC928);
    const purple = Color(0xFFB779FF);
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
          surface: const Color(0xFF100B05),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xCC080603),
          foregroundColor: Colors.white,
          elevation: 0,
          titleTextStyle: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: .6),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xE6120D05),
          elevation: 10,
          shadowColor: Color(0x66FFC928),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: Color(0x66FFC928))),
          margin: EdgeInsets.symmetric(vertical: 7),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xE6120D05),
          labelStyle: const TextStyle(color: Color(0xFFFFE9B0)),
          prefixIconColor: cyan,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0x66FFC928))),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0x66FFC928))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: cyan, width: 2)),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: cyan,
            foregroundColor: const Color(0xFF211500),
            minimumSize: const Size.fromHeight(54),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            textStyle: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: .7),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(foregroundColor: cyan, side: const BorderSide(color: cyan, width: 1.4), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Color(0xF20E0903),
          indicatorColor: Color(0x44FFD34A),
          labelTextStyle: WidgetStatePropertyAll(TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
        ),
        dividerTheme: const DividerThemeData(color: Color(0x33FFC928)),
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
      home: const AuthSessionGate(),
    );
  }
}

// ============================================================
// MODELS
// ============================================================

class LeagueJoinRequest {
  final String id;
  final String leagueId;
  final String leagueName;
  final String playerId;
  final String gamerTag;
  final String status;
  final DateTime? createdAt;

  const LeagueJoinRequest({
    required this.id,
    required this.leagueId,
    required this.leagueName,
    required this.playerId,
    required this.gamerTag,
    required this.status,
    this.createdAt,
  });

  factory LeagueJoinRequest.fromJson(Map<String, dynamic> row) {
    return LeagueJoinRequest(
      id: row['id']?.toString() ?? '',
      leagueId: row['league_id']?.toString() ?? '',
      leagueName: row['league_name']?.toString() ?? '',
      playerId: row['player_id']?.toString() ?? '',
      gamerTag: row['gamer_tag']?.toString() ?? '',
      status: row['status']?.toString() ?? 'pending',
      createdAt: row['created_at'] == null
          ? null
          : DateTime.tryParse(row['created_at'].toString()),
    );
  }
}

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

  bool get profileComplete =>
      phoneNumber.trim().isNotEmpty &&
      country.trim().isNotEmpty &&
      countryCode.trim().isNotEmpty &&
      whatsappNumber.trim().isNotEmpty;
}

class CreatorBadge {
  final String id;
  final String playerId;
  final String badgeType;
  final String source;
  final String? leagueId;
  final DateTime? awardedAt;
  final String? awardedBy;

  const CreatorBadge({
    required this.id,
    required this.playerId,
    required this.badgeType,
    required this.source,
    this.leagueId,
    this.awardedAt,
    this.awardedBy,
  });

  factory CreatorBadge.fromJson(Map<String, dynamic> row) => CreatorBadge(
        id: row['id']?.toString() ?? '',
        playerId: row['player_id']?.toString() ?? '',
        badgeType: row['badge_type']?.toString() ?? 'creator',
        source: row['source']?.toString() ?? 'earned',
        leagueId: row['league_id']?.toString(),
        awardedAt: row['awarded_at'] == null ? null : DateTime.tryParse(row['awarded_at'].toString()),
        awardedBy: row['awarded_by']?.toString(),
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
  final int screenshotResponseHours;
  final int noShowResponseHours;
  final bool noShowReportsEnabled;

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
    this.screenshotResponseHours = 24,
    this.noShowResponseHours = 24,
    this.noShowReportsEnabled = true,
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
  DateTime? screenshotResponseDeadline;
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
    this.screenshotResponseDeadline,
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
        'screenshotResponseDeadline': screenshotResponseDeadline?.toIso8601String(),
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
        screenshotResponseDeadline: DateTime.tryParse(json['screenshotResponseDeadline']?.toString() ?? ''),
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
  // League-only replacement map: historical results keep their real player IDs,
  // while standings attribute the outgoing player's league record to the replacement.
  final Map<String, Map<String, String>> leagueReplacementMap = {};
  final List<CreatorBadge> creatorBadges = [];
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
      await refreshBadges();
      await refreshLeagues();
      await loadMatchesFromSupabase();
      if (activeLeagueId != null) await loadDisciplineForLeague(activeLeagueId!);
    } catch (_) {}
  }

  Future<void> refreshLeagues() async {
    final data = await supabase
        .from('leagues')
        .select('id, name, status, is_paid, entry_fee, currency, created_at, start_date, end_date, fixture_mode, match_day_date_controls_enabled, sequential_match_day_lock_enabled, grace_period_enabled, screenshot_response_hours, no_show_response_hours, no_show_reports_enabled')
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
          screenshotResponseHours: (row['screenshot_response_hours'] as num?)?.toInt() ?? 24,
          noShowResponseHours: (row['no_show_response_hours'] as num?)?.toInt() ?? 24,
          noShowReportsEnabled: row['no_show_reports_enabled'] != false,
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
    final target = players.where((p) => p.id == playerId).firstOrNull;
    if (target != null && !target.profileComplete) {
      return 'Player must complete phone, country, country code and WhatsApp before joining a league.';
    }
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

  Future<String?> replaceLeaguePlayer({
    required String leagueId,
    required String outgoingPlayerId,
    required String replacementPlayerId,
  }) async {
    if (current?.admin != true) return 'Admin access required.';
    if (outgoingPlayerId == replacementPlayerId) return 'Choose a different replacement player.';
    final outgoing = findPlayer(outgoingPlayerId);
    final replacement = findPlayer(replacementPlayerId);
    if (outgoing == null || replacement == null) return 'Could not find both players.';
    if (replacement.admin) return 'An admin account cannot replace a league player.';
    if (!replacement.profileComplete) {
      return 'The replacement player must complete their phone, country, country code and WhatsApp profile first.';
    }
    try {
      await supabase.rpc('admin_replace_league_player', params: {
        'p_league_id': leagueId,
        'p_outgoing_player_id': outgoingPlayerId,
        'p_replacement_player_id': replacementPlayerId,
      });
      await refreshLeagues();
      if (activeLeagueId != leagueId) {
        activeLeagueId = leagueId;
        activeLeagueName = leagues.where((l) => l.id == leagueId).firstOrNull?.name;
      }
      await loadMatchesFromSupabase();
      activeLeagueMemberIds = (await leagueMemberIds(leagueId)).toSet();
      return null;
    } on PostgrestException catch (e) {
      return 'Could not replace player: ${e.message}';
    } catch (e) {
      return 'Could not replace player: $e';
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

  Future<String?> adminDeletePlayer(String playerId) async {
    if (Store.instance.current?.admin != true) return 'Admin access required.';
    if (playerId == supabase.auth.currentUser?.id) {
      return 'You cannot delete the currently signed-in admin account.';
    }
    try {
      await supabase.rpc('admin_delete_player', params: {'p_player_id': playerId});
      players.removeWhere((p) => p.id == playerId);
      return null;
    } on PostgrestException catch (e) {
      return 'Could not delete player: ${e.message}';
    } catch (e) {
      return 'Could not delete player: $e';
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
          'id, round, home_player_id, away_player_id, status, home_score, away_score, scheduled_date, match_start_time, match_end_time, screenshot_response_deadline',
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
          screenshotResponseDeadline: DateTime.tryParse(row['screenshot_response_deadline']?.toString() ?? ''),
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
    // Load league-only replacement links separately from real match history.
    // If this migration has not been applied yet, normal app loading continues.
    try {
      final replacementRows = await supabase
          .from('league_player_replacements')
          .select('outgoing_player_id, replacement_player_id')
          .eq('league_id', leagueId);
      final mapping = <String, String>{};
      for (final item in (replacementRows as List)) {
        final row = Map<String, dynamic>.from(item as Map);
        final outgoing = row['outgoing_player_id']?.toString();
        final replacement = row['replacement_player_id']?.toString();
        if (outgoing != null && replacement != null) mapping[outgoing] = replacement;
      }
      leagueReplacementMap[leagueId] = mapping;
    } catch (e) {
      debugPrint('League replacement map not available: $e');
    }
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

      // Prefer the latest player record in memory. A presence update must not
      // overwrite a newer avatar/profile with an older snapshot.
      final latest = findPlayer(player.id) ?? current ?? player;
      final updated = Player(
        id: latest.id,
        name: latest.name,
        gamerTag: latest.gamerTag,
        admin: latest.admin,
        phoneNumber: latest.phoneNumber,
        country: latest.country,
        countryCode: latest.countryCode,
        whatsappNumber: latest.whatsappNumber,
        lastSeen: now,
        isOnline: online,
        avatarUrl: latest.avatarUrl,
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

  Future<void> refreshBadges() async {
    try {
      final data = await supabase
          .from('player_badges')
          .select('id, player_id, badge_type, source, league_id, awarded_at, awarded_by')
          .order('awarded_at', ascending: false);
      creatorBadges
        ..clear()
        ..addAll((data as List).map((e) => CreatorBadge.fromJson(Map<String, dynamic>.from(e))));
    } catch (e) {
      debugPrint('Badge refresh failed: $e');
    }
  }

  List<CreatorBadge> badgesForPlayer(String playerId) =>
      creatorBadges.where((b) => b.playerId == playerId).toList();

  bool hasCreatorBadge(String playerId) => badgesForPlayer(playerId).isNotEmpty;

  bool isProfileComplete(String? playerId) {
    final id = playerId ?? current?.id;
    if (id == null) return false;
    final player = players.where((p) => p.id == id).firstOrNull ??
        (current?.id == id ? current : null);
    return player?.profileComplete == true;
  }

  Future<String?> awardCreatorBadge({
    required String playerId,
    String badgeType = 'creator',
  }) async {
    if (current?.admin != true) return 'Admin access required.';
    try {
      await supabase.rpc('admin_award_creator_badge', params: {
        'p_player_id': playerId,
        'p_badge_type': badgeType,
      });
      await refreshBadges();
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return 'Could not award badge: $e';
    }
  }

  Future<Map<String, dynamic>?> creatorStatus() async {
    final me = current;
    if (me == null) return null;
    try {
      final result = await supabase.rpc('get_my_creator_status');
      return result == null ? null : Map<String, dynamic>.from(result as Map);
    } catch (e) {
      debugPrint('Creator status lookup failed: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> fetchCreators() async {
    try {
      final data = await supabase.rpc('list_creator_pages');
      return (data as List).map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (e) {
      debugPrint('Creator pages lookup failed: $e');
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> fetchCreatorLeagues(String playerId) async {
    try {
      final data = await supabase.rpc('list_creator_leagues', params: {'p_creator_id': playerId});
      return (data as List).map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (e) {
      debugPrint('Creator leagues lookup failed: $e');
      return [];
    }
  }

  Future<String?> requestToJoinLeague(String leagueId) async {
    final me = current;
    if (me == null) return 'Please log in again.';
    if (me.admin) return 'Admins do not need to request league membership.';
    if (!me.profileComplete) return 'Complete your profile and WhatsApp details before joining a league.';
    try {
      await supabase.rpc('request_to_join_league', params: {'p_league_id': leagueId});
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return 'Could not request league membership: $e';
    }
  }

  Future<List<Map<String, dynamic>>> fetchMyJoinRequestStatuses() async {
    if (current == null) return [];
    try {
      final data = await supabase.rpc('list_my_league_join_requests');
      return (data as List).map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> fetchMyLeagueJoinRequests() async {
    if (current == null) return [];
    try {
      final data = await supabase.rpc('list_my_league_join_requests');
      return (data as List).map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<LeagueJoinRequest>> fetchLeagueJoinRequests({bool pendingOnly = false}) async {
    if (current?.admin != true) return [];
    try {
      final data = await supabase.rpc('list_my_league_join_requests');
      final rows = (data as List)
          .map((e) => LeagueJoinRequest.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      if (!pendingOnly) return rows;
      return rows.where((r) => r.status.toLowerCase() == 'pending').toList();
    } catch (_) {
      return [];
    }
  }

  Future<String?> adminReviewLeagueJoinRequest({required String requestId, required String decision}) async {
    if (current?.admin != true) return 'Admin access required.';
    try {
      await supabase.rpc('admin_review_league_join_request', params: {
        'p_request_id': requestId,
        'p_decision': decision,
      });
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return 'Could not review join request: $e';
    }
  }

  Future<String?> reviewLeagueJoinRequest({required String requestId, required String decision}) async {
    if (current == null) return 'Please log in again.';
    try {
      await supabase.rpc('review_creator_league_join_request', params: {
        'p_request_id': requestId,
        'p_decision': decision,
      });
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return 'Could not review join request: $e';
    }
  }

  Future<Map<String, dynamic>?> championsStatus() async {
    try {
      final result = await supabase.rpc('get_current_champions_status');
      return result == null ? null : Map<String, dynamic>.from(result as Map);
    } catch (_) {
      return null;
    }
  }

  Future<String?> createChampionsSeason({String name = 'CHIBBYBALL Champions League'}) async {
    if (current?.admin != true) return 'Admin access required.';
    try {
      await supabase.rpc('create_champions_season', params: {'p_name': name});
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return 'Could not create Champions League season: $e';
    }
  }

  Future<String?> generateChampionsGroups(String seasonId) async {
    if (current?.admin != true) return 'Admin access required.';
    try {
      await supabase.rpc('generate_champions_groups', params: {'p_season_id': seasonId});
      return null;
    } on PostgrestException catch (e) {
      return e.message;
    } catch (e) {
      return 'Could not generate Champions League groups: $e';
    }
  }

  Future<void> refreshPlayers() async {
    final signedInId = current?.id;
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

    // Keep the signed-in player in sync with the row fetched from Supabase.
    // Otherwise the main Profile tab can keep using an old, empty avatar URL.
    if (signedInId != null) {
      final refreshedCurrent = findPlayer(signedInId);
      if (refreshedCurrent != null) current = refreshedCurrent;
    }
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

  /// Restore the existing Supabase session without asking the player for
  /// their password again. Supabase persists its auth session securely.
  Future<bool> restoreAuthenticatedSession() async {
    final user = supabase.auth.currentUser;
    if (user == null) return false;

    try {
      final profile = await supabase
          .from('profiles')
          .select('id, full_name, gamer_tag, role, phone_number, country, country_code, whatsapp_number, last_seen, is_online')
          .eq('id', user.id)
          .maybeSingle();

      if (profile == null) {
        current = null;
        return false;
      }

      current = Player(
        id: user.id,
        name: profile['full_name']?.toString() ?? '',
        gamerTag: profile['gamer_tag']?.toString() ?? '',
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

      // Refresh supporting data, but don't discard a valid restored session
      // if a secondary data request temporarily fails.
      try {
        await refreshPlayers();
        await refreshLeagues();
        await loadMatchesFromSupabase();
        await refreshBadges();
      } catch (e) {
        debugPrint('Restored-session data refresh failed: $e');
      }
      return true;
    } catch (e) {
      debugPrint('Could not restore authenticated session: $e');
      return false;
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


  /// Converts an existing single-round league to Home & Away without
  /// changing any existing fixture, result, proof, or submission.
  /// Missing reverse fixtures are appended in rounds after the current rounds.
  Future<String?> convertLeagueToHomeAway(String leagueId) async {
    if (current?.admin != true) return 'Admin access required.';

    try {
      final leagueRow = await supabase
          .from('leagues')
          .select('id, fixture_mode')
          .eq('id', leagueId)
          .maybeSingle();
      if (leagueRow == null) return 'League not found.';
      if (leagueRow['fixture_mode']?.toString() == 'home_away') {
        return 'This league is already set to Home & Away.';
      }

      final data = await supabase
          .from('matches')
          .select('id, round, home_player_id, away_player_id, scheduled_date, match_start_time, match_end_time')
          .eq('league_id', leagueId)
          .order('round')
          .order('created_at');
      final rows = (data as List)
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

      // If no fixtures exist yet, simply change the mode; normal generation
      // will then create both legs.
      if (rows.isEmpty) {
        await supabase.from('leagues').update({'fixture_mode': 'home_away'}).eq('id', leagueId);
        await refreshLeagues();
        return null;
      }

      final maxRound = rows.fold<int>(0, (max, row) {
        final round = (row['round'] as num?)?.toInt() ?? 1;
        return round > max ? round : max;
      });
      final minRound = rows.fold<int>(maxRound, (min, row) {
        final round = (row['round'] as num?)?.toInt() ?? 1;
        return round < min ? round : min;
      });

      String pairKey(String a, String b) => a.compareTo(b) < 0 ? '$a|$b' : '$b|$a';
      String directionKey(String home, String away) => '$home>$away';
      final directionsByPair = <String, Set<String>>{};
      for (final row in rows) {
        final home = row['home_player_id'].toString();
        final away = row['away_player_id'].toString();
        directionsByPair.putIfAbsent(pairKey(home, away), () => <String>{}).add(directionKey(home, away));
      }

      final additions = <Map<String, dynamic>>[];
      final handledPairs = <String>{};
      for (final row in rows) {
        final home = row['home_player_id'].toString();
        final away = row['away_player_id'].toString();
        final pair = pairKey(home, away);
        if (!handledPairs.add(pair)) continue;

        final directions = directionsByPair[pair] ?? <String>{};
        // A pair that already has both orientations already has its return leg.
        if (directions.contains(directionKey(home, away)) &&
            directions.contains(directionKey(away, home))) {
          continue;
        }

        final originalRound = (row['round'] as num?)?.toInt() ?? 1;
        additions.add({
          'league_id': leagueId,
          'round': maxRound + (originalRound - minRound + 1),
          'home_player_id': away,
          'away_player_id': home,
          'status': 'scheduled',
          // Return legs need their own schedule; admin can assign Match Day dates.
          'scheduled_date': null,
          'match_start_time': row['match_start_time']?.toString() ?? '17:00:00',
          'match_end_time': row['match_end_time']?.toString() ?? '23:59:00',
        });
      }

      // Insert the return legs first. If insertion fails, leave the league mode
      // unchanged so the admin can safely retry.
      if (additions.isNotEmpty) {
        await supabase.from('matches').insert(additions);
      }
      await supabase.from('leagues').update({'fixture_mode': 'home_away'}).eq('id', leagueId);
      await refreshLeagues();
      if (activeLeagueId == leagueId) await loadMatchesFromSupabase();
      return additions.isEmpty
          ? 'League changed to Home & Away. Both legs already existed.'
          : 'Home & Away enabled. Added ${additions.length} return fixture(s); existing matches and results were kept.';
    } on PostgrestException catch (e) {
      return 'Could not convert league to Home & Away: ${e.message}';
    } catch (e) {
      return 'Could not convert league to Home & Away: $e';
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

  Future<String?> adminForfeitMatch({
    required String matchId,
    required String action,
    required String note,
  }) async {
    if (current?.admin != true) return 'Admin access required.';
    try {
      await supabase.rpc('admin_forfeit_match', params: {
        'p_match_id': matchId,
        'p_action': action,
        'p_admin_note': note.trim().isEmpty ? null : note.trim(),
      });
      await loadMatchesFromSupabase();
      return null;
    } on PostgrestException catch (e) {
      return 'Could not apply admin match decision: ${e.message}';
    } catch (e) {
      return 'Could not apply admin match decision: $e';
    }
  }

  Future<String?> reportMatchNoShow({
    required String matchId,
    required String reason,
  }) async {
    if (current == null) return 'Please sign in first.';
    if (reason.trim().isEmpty) return 'Enter a reason for the report.';
    try {
      await supabase.rpc('report_match_no_show', params: {
        'p_match_id': matchId,
        'p_reason': reason.trim(),
      });
      return null;
    } on PostgrestException catch (e) {
      return 'Could not submit no-show report: ${e.message}';
    } catch (e) {
      return 'Could not submit no-show report: $e';
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

    final replacementMap = leagueReplacementMap[activeLeagueId] ?? const <String, String>{};
    String standingsPlayerId(String id) {
      var resolved = id;
      final visited = <String>{};
      while (replacementMap.containsKey(resolved) && visited.add(resolved)) {
        resolved = replacementMap[resolved]!;
      }
      return resolved;
    }
    final replacedOutIds = replacementMap.keys.toSet();
    for (final match in matches) {
      participantIds.add(standingsPlayerId(match.homeId));
      participantIds.add(standingsPlayerId(match.awayId));
    }
    for (final player in players.where(
      (p) => !p.admin && participantIds.contains(p.id) && !replacedOutIds.contains(p.id),
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
      final standingsHomeId = standingsPlayerId(match.homeId);
      final standingsAwayId = standingsPlayerId(match.awayId);
      if (standingsHomeId == standingsAwayId) continue;
      final home = table[standingsHomeId];
      final away = table[standingsAwayId];

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
      var adjustment = 0;
      for (final item in pointAdjustments.entries) {
        if (standingsPlayerId(item.key) == entry.key) adjustment += item.value;
      }
      entry.value['points'] = entry.value['points']! + adjustment;
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

    // Membership is supplemental. A membership-table/RLS error must never
    // prevent confirmed match results from being counted.
    try {
      final membershipRows = await supabase
          .from('league_members')
          .select('league_id, player_id')
          .timeout(const Duration(seconds: 12));
      final leagueSets = <String, Set<String>>{};
      for (final item in (membershipRows as List)) {
        final row = Map<String, dynamic>.from(item as Map);
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
    } catch (e) {
      debugPrint('Global leaderboard membership lookup skipped: $e');
    }

    // Load results independently of membership. Status is normalized in Dart
    // so casing differences (Confirmed/confirmed/CONFIRMED) cannot zero stats.
    try {
      final rows = await supabase
          .from('matches')
          .select('league_id, home_player_id, away_player_id, home_score, away_score, status')
          .timeout(const Duration(seconds: 20));
      for (final item in (rows as List)) {
        final row = Map<String, dynamic>.from(item as Map);
        if ((row['status']?.toString().trim().toLowerCase() ?? '') != 'confirmed') continue;
        final homeId = row['home_player_id']?.toString();
        final awayId = row['away_player_id']?.toString();
        final home = homeId == null ? null : result[homeId];
        final away = awayId == null ? null : result[awayId];
        final hs = (row['home_score'] as num?)?.toInt();
        final ascore = (row['away_score'] as num?)?.toInt();
        if (home == null || away == null || hs == null || ascore == null) continue;
        home.played++;
        away.played++;
        home.goals += hs;
        home.conceded += ascore;
        away.goals += ascore;
        away.conceded += hs;
        if (ascore == 0) home.cleanSheets++;
        if (hs == 0) away.cleanSheets++;
        if (hs > ascore) {
          home.won++;
          away.lost++;
          home.points += 3;
        } else if (hs < ascore) {
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
      debugPrint('Global leaderboard match query failed: ${e.message}');
      rethrow;
    } catch (e) {
      debugPrint('Global leaderboard match query failed: $e');
      rethrow;
    }

    // Confirmed friendly matches also contribute to global stats, but are
    // stored separately and never enter the official league table.
    try {
      final friendlyRows = await supabase
          .from('friendly_matches')
          .select('id, player_one_id, player_two_id, player_one_score, player_two_score, status')
          .ilike('status', 'confirmed')
          .timeout(const Duration(seconds: 15));
      for (final item in (friendlyRows as List)) {
        final row = Map<String, dynamic>.from(item as Map);
        final oneId = row['player_one_id']?.toString();
        final twoId = row['player_two_id']?.toString();
        final one = oneId == null ? null : result[oneId];
        final two = twoId == null ? null : result[twoId];
        final oneScore = (row['player_one_score'] as num?)?.toInt();
        final twoScore = (row['player_two_score'] as num?)?.toInt();
        if (one == null || two == null || oneScore == null || twoScore == null) continue;
        one.played++; two.played++;
        one.goals += oneScore; one.conceded += twoScore;
        two.goals += twoScore; two.conceded += oneScore;
        if (twoScore == 0) one.cleanSheets++;
        if (oneScore == 0) two.cleanSheets++;
        if (oneScore > twoScore) { one.won++; two.lost++; one.points += 3; }
        else if (oneScore < twoScore) { two.won++; one.lost++; two.points += 3; }
        else { one.drawn++; two.drawn++; one.points++; two.points++; }
      }
    } catch (e) {
      // Keep the existing league leaderboard available if the migration has
      // not been applied yet; friendly-match rows cannot be counted until it is.
      debugPrint('Global leaderboard friendly-match lookup skipped: $e');
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
// AUTH SESSION GATE
// ============================================================

/// Shows the login screen only when there is no valid saved Supabase session.
class AuthSessionGate extends StatefulWidget {
  const AuthSessionGate({super.key});

  @override
  State<AuthSessionGate> createState() => _AuthSessionGateState();
}

class _AuthSessionGateState extends State<AuthSessionGate> {
  bool _checkingSession = true;
  bool _hasSession = false;

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    final restored = await Store.instance.restoreAuthenticatedSession();
    if (!mounted) return;
    setState(() {
      _hasSession = restored;
      _checkingSession = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_checkingSession) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFFFFC928)),
        ),
      );
    }
    return _hasSession ? const HomePage() : const LoginPage();
  }
}

// Premium mythic arena artwork drawn directly in Dart (no extra asset files required).
class _MythicArenaPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..shader = const LinearGradient(
      begin: Alignment.topCenter, end: Alignment.bottomCenter,
      colors: [Color(0xFF071426), Color(0xFF080806), Color(0xFF030407)],
    ).createShader(rect));
    final gold = Paint()..color = const Color(0xFFFFC928)..style = PaintingStyle.stroke..strokeWidth = 1.4;
    final blue = Paint()..color = const Color(0xFF168DFF)..style = PaintingStyle.stroke..strokeWidth = 1.2;
    final cx = size.width * .48;
    // Stadium roof beams and light rays.
    for (int i = 0; i < 13; i++) {
      final x = size.width * i / 12;
      canvas.drawLine(Offset(cx, size.height * .04), Offset(x, size.height * .56), i.isEven ? gold : blue);
    }
    for (int i = 0; i < 7; i++) {
      final y = size.height * (.16 + i * .055);
      canvas.drawArc(Rect.fromCenter(center: Offset(cx, y), width: size.width * (.58 + i * .08), height: size.height * (.12 + i * .025)), 3.14, 3.14, false, gold);
    }
    // Stadium floor rings.
    for (int i = 0; i < 5; i++) {
      canvas.drawOval(Rect.fromCenter(center: Offset(cx, size.height * .91), width: size.width * (.34 + i * .17), height: size.height * (.05 + i * .012)), i.isEven ? gold : blue);
    }
    // Crowned football.
    final ballCenter = Offset(size.width * .42, size.height * .28);
    final ballR = size.width * .145;
    canvas.drawCircle(ballCenter, ballR + 5, Paint()..color = const Color(0x66FFC928)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18));
    canvas.drawCircle(ballCenter, ballR, Paint()..shader = const RadialGradient(colors: [Color(0xFFFFF2B0), Color(0xFFFFC928), Color(0xFF76500B)]).createShader(Rect.fromCircle(center: ballCenter, radius: ballR)));
    final pentagon = Path();
    for (int i = 0; i < 5; i++) {
      final a = -1.5708 + i * 1.2566;
      final pt = Offset(ballCenter.dx + ballR * .42 * _cos(a), ballCenter.dy + ballR * .42 * _sin(a));
      if (i == 0) pentagon.moveTo(pt.dx, pt.dy); else pentagon.lineTo(pt.dx, pt.dy);
    }
    pentagon.close();
    canvas.drawPath(pentagon, Paint()..color = const Color(0xFF10131A));
    for (int i = 0; i < 5; i++) {
      final a = -1.5708 + i * 1.2566;
      final p1 = Offset(ballCenter.dx + ballR * .42 * _cos(a), ballCenter.dy + ballR * .42 * _sin(a));
      final p2 = Offset(ballCenter.dx + ballR * .9 * _cos(a + .35), ballCenter.dy + ballR * .9 * _sin(a + .35));
      canvas.drawLine(p1, p2, Paint()..color = const Color(0xFF17191E)..strokeWidth = 3);
    }
    final crown = Path()
      ..moveTo(ballCenter.dx - ballR * .68, ballCenter.dy - ballR * .72)
      ..lineTo(ballCenter.dx - ballR * .55, ballCenter.dy - ballR * 1.27)
      ..lineTo(ballCenter.dx - ballR * .18, ballCenter.dy - ballR * .91)
      ..lineTo(ballCenter.dx, ballCenter.dy - ballR * 1.42)
      ..lineTo(ballCenter.dx + ballR * .22, ballCenter.dy - ballR * .91)
      ..lineTo(ballCenter.dx + ballR * .58, ballCenter.dy - ballR * 1.25)
      ..lineTo(ballCenter.dx + ballR * .68, ballCenter.dy - ballR * .72)
      ..close();
    canvas.drawPath(crown, Paint()..color = const Color(0xFFFFD34A));
    canvas.drawPath(crown, Paint()..color = const Color(0xFF8D5A08)..style = PaintingStyle.stroke..strokeWidth = 2);
    // Trophy silhouettes at the sides.
    for (final side in [-1.0, 1.0]) {
      final tx = size.width * (side < 0 ? .11 : .86);
      final ty = size.height * .72;
      final cup = Path()..moveTo(tx - size.width*.035, ty)..lineTo(tx + size.width*.035, ty)..lineTo(tx + size.width*.025, ty + size.height*.055)..lineTo(tx - size.width*.025, ty + size.height*.055)..close();
      canvas.drawPath(cup, Paint()..color = const Color(0xFFFFC928));
      canvas.drawArc(Rect.fromLTWH(tx-size.width*.055,ty-size.height*.005,size.width*.035,size.height*.05), -1.57, 3.14, false, gold);
      canvas.drawArc(Rect.fromLTWH(tx+size.width*.02,ty-size.height*.005,size.width*.035,size.height*.05), -1.57, 3.14, false, gold);
      canvas.drawRect(Rect.fromLTWH(tx-size.width*.012,ty+size.height*.055,size.width*.024,size.height*.035), Paint()..color=const Color(0xFFFFC928));
      canvas.drawRect(Rect.fromLTWH(tx-size.width*.045,ty+size.height*.088,size.width*.09,size.height*.012), Paint()..color=const Color(0xFFFFC928));
    }
    // Back-view footballer wearing number 10, kept on the right so content remains readable.
    final px = size.width * .79;
    final py = size.height * .59;
    final playerPaint = Paint()..color = const Color(0xFF05080D);
    canvas.drawCircle(Offset(px, py - size.height*.11), size.width*.045, playerPaint);
    final body = Path()..moveTo(px-size.width*.065,py-size.height*.07)..quadraticBezierTo(px-size.width*.09,py+size.height*.04,px-size.width*.075,py+size.height*.17)..lineTo(px+size.width*.075,py+size.height*.17)..quadraticBezierTo(px+size.width*.09,py+size.height*.04,px+size.width*.065,py-size.height*.07)..close();
    canvas.drawPath(body, playerPaint);
    canvas.drawPath(body, Paint()..color=const Color(0xFFFFC928)..style=PaintingStyle.stroke..strokeWidth=1.2);
    final tp = TextPainter(text: const TextSpan(text:'10',style:TextStyle(color:Color(0xFFFFC928),fontSize:22,fontWeight:FontWeight.w900)),textDirection:TextDirection.ltr)..layout();
    tp.paint(canvas, Offset(px-tp.width/2, py+size.height*.015));
    final crownMark = Path()..moveTo(px-size.width*.027,py-size.height*.025)..lineTo(px-size.width*.02,py-size.height*.05)..lineTo(px,py-size.height*.033)..lineTo(px+size.width*.02,py-size.height*.05)..lineTo(px+size.width*.027,py-size.height*.025)..close();
    canvas.drawPath(crownMark, Paint()..color=const Color(0xFFFFC928));
  }
  double _cos(double a) => a == 0 ? 1 : _trig(a, true);
  double _sin(double a) => _trig(a, false);
  double _trig(double a, bool cosine) { // compact helpers avoid extra dependencies
    // Dart's dart:math is imported below through the local approximation.
    return cosine ? _cosApprox(a) : _sinApprox(a);
  }
  double _cosApprox(double x) { while (x > 3.14159265) { x -= 6.2831853; } while (x < -3.14159265) { x += 6.2831853; } final x2=x*x; return 1-x2/2+x2*x2/24-x2*x2*x2/720; }
  double _sinApprox(double x) { while (x > 3.14159265) { x -= 6.2831853; } while (x < -3.14159265) { x += 6.2831853; } final x2=x*x; return x*(1-x2/6+x2*x2/120-x2*x2*x2/5040); }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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
                  height: 300,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: const Color(0xAAFFC928), width: 1.3),
                    boxShadow: const [BoxShadow(color: Color(0x44FFC928), blurRadius: 26, spreadRadius: 1)],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.memory(
                    base64Decode(_mythicLoginArtworkBase64),
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    errorBuilder: (_, __, ___) => CustomPaint(painter: _MythicArenaPainter()),
                  ),
                ),
                const SizedBox(height: 22),
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
        color: const Color(0xDD171006),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: online ? const Color(0xFFFFC928) : const Color(0x443A5575)),
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
            Positioned(right: 0, bottom: 0, child: Container(width: 13, height: 13, decoration: BoxDecoration(shape: BoxShape.circle, color: online ? const Color(0xFF20E070) : const Color(0xFFB7A77C), border: Border.all(color: const Color(0xFF171006), width: 2)))),
          ],
        ),
        title: Text(player.gamerTag, style: const TextStyle(fontWeight: FontWeight.w900)),
        subtitle: Text(online ? 'Online' : (player.lastSeen == null ? 'Offline' : 'Last seen ${_shortLastSeen(player.lastSeen!)}')),
        trailing: const Icon(Icons.chat_bubble_outline, color: Color(0xFFFFC928)),
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
                child: Text(m.body, style: TextStyle(color: mine ? const Color(0xFF211500) : Colors.white, fontWeight: FontWeight.w600)),
              ));
            },
          ),
        ),
        SafeArea(top: false, child: Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10), color: const Color(0xF20E0903),
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

const _cyan = Color(0xFFFFC928);
const _yellow = Color(0xFFFFD21F);
const _purple = Color(0xFF9B4DFF);
const _blue = Color(0xFF278BFF);
const _panel = Color(0xE9171006);
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
    final myMatches = player == null
        ? <MatchItem>[]
        : store.matches.where((m) => m.homeId == player.id || m.awayId == player.id).toList();
    final confirmedMatches = myMatches.where((m) => m.status == 'Confirmed' && m.homeScore != null && m.awayScore != null).toList();
    final pending = myMatches.where((m) => m.status == 'Awaiting Confirmation').length;
    final scheduled = myMatches.where((m) => m.status == 'Scheduled').length;
    var wins = 0;
    var draws = 0;
    var losses = 0;
    var goalsFor = 0;
    var goalsAgainst = 0;
    for (final match in confirmedMatches) {
      final isHome = match.homeId == player?.id;
      final mine = isHome ? match.homeScore! : match.awayScore!;
      final theirs = isHome ? match.awayScore! : match.homeScore!;
      goalsFor += mine;
      goalsAgainst += theirs;
      if (mine > theirs) {
        wins++;
      } else if (mine == theirs) {
        draws++;
      } else {
        losses++;
      }
    }

    final recent = [...confirmedMatches]..sort((a, b) {
      final ad = DateTime.tryParse(a.scheduledDate ?? '') ?? DateTime(2000);
      final bd = DateTime.tryParse(b.scheduledDate ?? '') ?? DateTime(2000);
      return bd.compareTo(ad);
    });

    Widget quickAction(IconData icon, String title, String subtitle, Color accent, VoidCallback onTap) {
      return Container(
        decoration: _neonBox(accent, radius: 18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(width: 43, height: 43,
                decoration: BoxDecoration(color: accent.withOpacity(.13), borderRadius: BorderRadius.circular(14)),
                child: Icon(icon, color: accent, size: 24)),
              const SizedBox(height: 12),
              Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
              const SizedBox(height: 4),
              Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _muted, fontSize: 10, height: 1.3)),
            ]),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        // Mythic Arena hero artwork from the approved CHIBBYBALL reference.
        Container(
          height: 126,
          margin: const EdgeInsets.only(bottom: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFFFC928), width: 1.4),
            boxShadow: const [
              BoxShadow(color: Color(0x66FFC928), blurRadius: 18, spreadRadius: 1),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Image.memory(
            base64Decode(_mythicDashboardBannerBase64),
            width: double.infinity,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => CustomPaint(painter: _MythicArenaPainter()),
          ),
        ),
        // Featured welcome card (existing content and actions retained)
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight,
              colors: [Color(0xFF12365A), Color(0xFF081321), Color(0xFF15112D)],
            ),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: _cyan.withOpacity(.75)),
            boxShadow: [BoxShadow(color: _cyan.withOpacity(.12), blurRadius: 25, offset: const Offset(0, 8))],
          ),
          child: Stack(children: [
            Positioned.fill(child: ClipRRect(borderRadius: BorderRadius.circular(24), child: Opacity(opacity: .42, child: CustomPaint(painter: _MythicArenaPainter())))),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('WELCOME BACK', style: TextStyle(color: _cyan, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.6)),
                const SizedBox(height: 5),
                Text(player?.gamerTag.isNotEmpty == true ? player!.gamerTag : 'CHAMPION',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 25, fontWeight: FontWeight.w900, letterSpacing: .3)),
              ])),
              _playerAvatar(player, radius: 29, accent: _yellow),
            ]),
            const SizedBox(height: 20),
            const Text('YOUR NEXT WIN STARTS HERE.', style: TextStyle(color: _yellow, fontSize: 12, fontWeight: FontWeight.w900, letterSpacing: 1.1)),
            const SizedBox(height: 5),
            const Text('Check your fixtures, prove your skills and climb the CHIBBYBALL ranks.',
              style: TextStyle(color: _muted, height: 1.4, fontSize: 12)),
            const SizedBox(height: 16),
            SizedBox(width: double.infinity, child: FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: _cyan, foregroundColor: const Color(0xFF06111E), padding: const EdgeInsets.symmetric(vertical: 13)),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FixturesPage())),
              icon: const Icon(Icons.sports_soccer), label: const Text('OPEN MY MATCHES', style: TextStyle(fontWeight: FontWeight.w900)),
            )),
          ]),
          ]),
        ),
        const SizedBox(height: 22),
        _neonSectionTitle('YOUR SEASON SNAPSHOT'),
        const SizedBox(height: 12),
        Row(children: [
          _neonStat(context, Icons.sports_soccer, '${myMatches.length}', 'MATCHES', _cyan, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FixturesPage()))),
          _neonStat(context, Icons.emoji_events, '$wins', 'WINS', _yellow, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PlayerStatsPage()))),
          _neonStat(context, Icons.hourglass_top, '$pending', 'PENDING', _purple, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FixturesPage(statusFilter: 'Awaiting Confirmation')))),
        ]),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
          decoration: _neonBox(_blue, radius: 16),
          child: Row(children: [
            const Icon(Icons.insights, color: _blue, size: 22), const SizedBox(width: 10),
            Expanded(child: Text('FORM  •  $wins W  /  $draws D  /  $losses L', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12))),
            Text('$goalsFor GF  ·  $goalsAgainst GA', style: const TextStyle(color: _muted, fontSize: 10, fontWeight: FontWeight.w800)),
          ]),
        ),
        const SizedBox(height: 22),
        _neonSectionTitle('ENTER THE ACTION', accent: _yellow),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 1.18,
          children: [
            quickAction(Icons.calendar_month, 'MY FIXTURES', 'Matches and result submissions', _cyan, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FixturesPage()))),
            quickAction(Icons.menu_book, 'RULES & REGULATIONS', 'Read the current CHIBBYBALL rules', _purple, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AppRulesPage()))),
            quickAction(Icons.rule, 'LEAGUE RULES', 'Read rules for your leagues', _blue, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LeagueRulesPage()))),
            quickAction(Icons.leaderboard, 'LEAGUE TABLE', 'See the live standings', _yellow, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const TablePage()))),
            quickAction(Icons.group_add, 'JOIN A LEAGUE', 'Find a competition to enter', _blue, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const JoinLeaguePage()))),
            quickAction(Icons.verified, 'CREATOR HUB', 'Explore creator leagues', _purple, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CreatorHubPage()))),
            quickAction(Icons.emoji_events, 'CHAMPIONS LEAGUE', 'Follow the championship', _yellow, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ChampionsLeaguePage()))),
            quickAction(Icons.military_tech, 'ACHIEVEMENTS', 'Unlock badges from confirmed results', _yellow, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AchievementsPage()))),
            quickAction(Icons.workspace_premium, 'HALL OF FAME', 'Celebrate CHIBBYBALL top performers', _purple, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HallOfFamePage()))),
            quickAction(Icons.public, 'GLOBAL RANKING', 'Compare points across leagues', _cyan, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GlobalLeaderboardPage()))),
            quickAction(Icons.people_alt, 'PLAYERS & CHAT', 'Find players and message them', _blue, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MessagesPage()))),
            quickAction(Icons.person, 'MY PROFILE', 'Your player identity and details', _purple, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfilePage()))),
            quickAction(Icons.auto_awesome, 'PLAYER FEATURES', 'Rivals, friends, tournaments, missions and awards', _blue, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PlayerFeaturesHubPage()))),
          ],
        ),
        const SizedBox(height: 22),
        Row(children: [
          Expanded(child: _neonSectionTitle('RECENT RESULTS')),
          TextButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PlayerStatsPage())), child: const Text('VIEW HISTORY')),
        ]),
        const SizedBox(height: 8),
        if (recent.isEmpty)
          Container(
            padding: const EdgeInsets.all(18), decoration: _neonBox(_blue, radius: 18),
            child: const Row(children: [
              Icon(Icons.sports_soccer, color: _blue, size: 30), SizedBox(width: 12),
              Expanded(child: Text('Your confirmed results will appear here. Play your first match and start building your record!', style: TextStyle(color: _muted, height: 1.4, fontSize: 12))),
            ]),
          )
        else
          ...recent.take(3).map((match) {
            final isHome = match.homeId == player?.id;
            final mine = isHome ? match.homeScore! : match.awayScore!;
            final theirs = isHome ? match.awayScore! : match.homeScore!;
            final opponentId = isHome ? match.awayId : match.homeId;
            final opponent = store.players.where((p) => p.id == opponentId).firstOrNull;
            final result = mine > theirs ? 'WIN' : mine == theirs ? 'DRAW' : 'LOSS';
            final color = mine > theirs ? _yellow : mine == theirs ? _cyan : const Color(0xFFFF5C7A);
            return Container(
              margin: const EdgeInsets.only(bottom: 9), decoration: _neonBox(color, radius: 16),
              child: ListTile(
                leading: Container(width: 42, height: 42, alignment: Alignment.center,
                  decoration: BoxDecoration(color: color.withOpacity(.12), borderRadius: BorderRadius.circular(13)),
                  child: Text(result == 'WIN' ? 'W' : result == 'DRAW' ? 'D' : 'L', style: TextStyle(color: color, fontWeight: FontWeight.w900, fontSize: 18))),
                title: Text('vs ${opponent?.gamerTag ?? store.playerName(opponentId)}', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13)),
                subtitle: Text('${result}  •  MATCHDAY ${match.round}', style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w900)),
                trailing: Text('$mine - $theirs', style: TextStyle(color: color, fontWeight: FontWeight.w900, fontSize: 19)),
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FixturesPage())),
              ),
            );
          }),
        const SizedBox(height: 10),
        if (scheduled > 0)
          Container(padding: const EdgeInsets.all(13), decoration: _neonBox(_purple, radius: 16),
            child: Row(children: [const Icon(Icons.notifications_active, color: _purple), const SizedBox(width: 10), Expanded(child: Text('You have $scheduled scheduled match${scheduled == 1 ? '' : 'es'}. Check your fixtures and get ready.', style: const TextStyle(color: _muted, fontSize: 12, height: 1.35)))])),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(15), decoration: _neonBox(_blue, radius: 18),
          child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('FAIR PLAY • REAL RESULTS', style: TextStyle(color: _cyan, fontWeight: FontWeight.w900, letterSpacing: .7)),
            SizedBox(height: 7),
            Text('Submit clear screenshot evidence after your matches. Confirm results honestly, and contact an admin if a result needs review.', style: TextStyle(color: _muted, height: 1.45, fontSize: 12)),
          ]),
        ),
        const SizedBox(height: 12),
        _neonAction(context, Icons.add_business, 'REQUEST A LEAGUE', 'Eligible players can request a league for admin approval', _purple, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LeagueRequestPage()))),
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

  Future<void> reportNoShow() async {
    final player = Store.instance.current;
    if (player == null) return;
    final isParticipant = player.id == widget.match.homeId ||
        player.id == widget.match.awayId;
    if (!isParticipant) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only players in this match can report a no-show.')),
      );
      return;
    }
    final reasonController = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Report a No-Show'),
        content: TextField(
          controller: reasonController,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Reason',
            hintText: 'Explain when you tried to play the scheduled match.',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, reasonController.text.trim()),
            child: const Text('SUBMIT REPORT'),
          ),
        ],
      ),
    );
    reasonController.dispose();
    if (reason == null || reason.trim().isEmpty || !mounted) return;
    setState(() => loading = true);
    final error = await Store.instance.reportMatchNoShow(
      matchId: widget.match.id,
      reason: reason,
    );
    if (!mounted) return;
    setState(() => loading = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error ?? 'No-show report submitted. The opponent has been notified.')),
    );
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
          if (match.screenshotResponseDeadline != null &&
              match.status != 'Confirmed') ...[
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: const Text('Screenshot response deadline'),
                subtitle: Text(match.screenshotResponseDeadline!.toLocal().toString()),
              ),
            ),
          ],
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
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: loading || Store.instance.current == null ||
                    match.status == 'Confirmed'
                ? null
                : reportNoShow,
            icon: const Icon(Icons.report_gmailerrorred_outlined),
            label: const Text('REPORT OPPONENT NO-SHOW'),
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
            color: const Color(0xE9171006),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _cyan.withOpacity(.55)),
          ),
          child: DropdownButtonFormField<String>(
            value: selected?.id,
            dropdownColor: const Color(0xFF171006),
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
                    color: const Color(0xFF241907),
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
                Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8), decoration: BoxDecoration(color: const Color(0xFF241907), borderRadius: BorderRadius.circular(11)), child: const Row(children: [
                  SizedBox(width: 30, child: Center(child: Text('#', style: TextStyle(color: _yellow, fontSize: 8, fontWeight: FontWeight.w900)))),
                  SizedBox(width: 39, child: Center(child: Text('PLAYER', style: TextStyle(color: _muted, fontSize: 8, fontWeight: FontWeight.w900)))),
                  Expanded(child: Text('LEAGUES', style: TextStyle(color: _muted, fontSize: 8, fontWeight: FontWeight.w900))),
                  SizedBox(width: 45, child: Center(child: Text('PTS', style: TextStyle(color: _yellow, fontSize: 8, fontWeight: FontWeight.w900)))),
                ])),
                const SizedBox(height: 6),
                for (int i=0;i<stats.length;i++) Builder(builder: (_) {
                  final s = stats[i]; final accent = rankColor(i+1);
                  return Container(margin: const EdgeInsets.only(bottom: 6), decoration: BoxDecoration(color: const Color(0xDD171006), borderRadius: BorderRadius.circular(14), border: Border.all(color: accent.withOpacity(i<3 ? .8 : .35))), child: InkWell(borderRadius: BorderRadius.circular(14), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerStatsPageFor(player: s.player))), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8), child: Row(children: [
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
// ACHIEVEMENTS & BADGES — custom esports badge cabinet
// ============================================================

class AchievementsPage extends StatefulWidget {
  const AchievementsPage({super.key});
  @override State<AchievementsPage> createState() => _AchievementsPageState();
}

class _AchievementsPageState extends State<AchievementsPage> {
  late Future<List<GlobalPlayerStat>> future;
  @override void initState() { super.initState(); future = Store.instance.globalLeaderboard(); }
  Future<void> _refresh() async { setState(() => future = Store.instance.globalLeaderboard()); await future; }

  @override Widget build(BuildContext context) {
    final me = Store.instance.current;
    return Scaffold(
      appBar: AppBar(title: const Text('Achievements & Badges'), actions: [IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh))]),
      body: FutureBuilder<List<GlobalPlayerStat>>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator(color: _cyan));
          if (snapshot.hasError) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Could not load achievements. Pull to refresh.\n${snapshot.error}', textAlign: TextAlign.center)));
          final stats = snapshot.data ?? <GlobalPlayerStat>[];
          final mine = stats.where((s) => s.player.id == me?.id).firstOrNull ?? GlobalPlayerStat(player: me ?? const Player(id: '', name: 'Player', gamerTag: 'PLAYER'));
          final achievements = <({String title, String description, IconData icon, Color color, bool earned, String tier})>[
            (title: 'FIRST VICTORY', description: 'Win your first confirmed match', icon: Icons.sports_soccer, color: const Color(0xFFFFC928), earned: mine.won >= 1, tier: 'BRONZE'),
            (title: 'HAT-TRICK HERO', description: 'Win 3 confirmed matches', icon: Icons.local_fire_department, color: const Color(0xFFFF512F), earned: mine.won >= 3, tier: 'SILVER'),
            (title: 'FIVE-STAR WINNER', description: 'Win 5 confirmed matches', icon: Icons.stars, color: const Color(0xFFFFB547), earned: mine.won >= 5, tier: 'GOLD'),
            (title: 'GOAL MACHINE', description: 'Score 10 goals across confirmed matches', icon: Icons.bolt, color: const Color(0xFF28BFFF), earned: mine.goals >= 10, tier: 'SILVER'),
            (title: 'CLINICAL FINISHER', description: 'Score 25 goals across confirmed matches', icon: Icons.gps_fixed, color: const Color(0xFFFF4658), earned: mine.goals >= 25, tier: 'GOLD'),
            (title: 'THE WALL', description: 'Record 5 clean sheets', icon: Icons.shield, color: const Color(0xFFFFD34A), earned: mine.cleanSheets >= 5, tier: 'GOLD'),
            (title: 'VETERAN', description: 'Play 25 confirmed matches', icon: Icons.workspace_premium, color: const Color(0xFFB45CFF), earned: mine.played >= 25, tier: 'GOLD'),
            (title: 'CENTURION', description: 'Play 100 confirmed matches', icon: Icons.workspace_premium, color: const Color(0xFFFFC928), earned: mine.played >= 100, tier: 'LEGENDARY'),
            (title: 'UNBEATEN RUN', description: 'Finish 5 matches without a loss', icon: Icons.security, color: const Color(0xFF31E69A), earned: mine.played >= 5 && mine.lost == 0, tier: 'LEGENDARY'),
            (title: 'GLOBAL TOP 3', description: 'Reach the top three in global points', icon: Icons.emoji_events, color: const Color(0xFFFF9E32), earned: stats.indexWhere((s) => s.player.id == me?.id) >= 0 && stats.indexWhere((s) => s.player.id == me?.id) < 3, tier: 'LEGENDARY'),
          ];
          final earnedCount = achievements.where((a) => a.earned).length;
          return RefreshIndicator(onRefresh: _refresh, child: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 30), children: [
            Container(padding: const EdgeInsets.all(18), decoration: BoxDecoration(borderRadius: BorderRadius.circular(22), border: Border.all(color: _yellow, width: 1.4), gradient: const LinearGradient(colors: [Color(0xFF1B1307), Color(0xFF102C55), Color(0xFF171006)]), boxShadow: [BoxShadow(color: _blue.withOpacity(.2), blurRadius: 25)]), child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('YOUR TROPHY CABINET', style: TextStyle(color: _yellow, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.3)),
                const SizedBox(height: 8), Text('$earnedCount / ${achievements.length}', style: const TextStyle(fontSize: 31, fontWeight: FontWeight.w900)),
                const Text('achievements unlocked', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(height: 13), ClipRRect(borderRadius: BorderRadius.circular(20), child: LinearProgressIndicator(value: earnedCount / achievements.length, minHeight: 8, backgroundColor: Colors.white12, color: _yellow)),
                const SizedBox(height: 10), Text('${mine.won} wins • ${mine.goals} goals • ${mine.played} matches • ${mine.cleanSheets} clean sheets', style: const TextStyle(color: _muted, fontSize: 10)),
              ])),
              const SizedBox(width: 8), Container(width: 88, height: 100, decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [_yellow.withOpacity(.25), Colors.transparent]), boxShadow: [BoxShadow(color: _yellow.withOpacity(.25), blurRadius: 20)]), child: const Icon(Icons.emoji_events, size: 72, color: _yellow)),
            ])),
            const SizedBox(height: 20), Row(crossAxisAlignment: CrossAxisAlignment.end, children: [Expanded(child: _neonSectionTitle('BADGES', accent: _cyan)), const Text('COMPLETE CHALLENGES TO UNLOCK', style: TextStyle(color: _muted, fontSize: 9, fontWeight: FontWeight.w800))]),
            const SizedBox(height: 10),
            LayoutBuilder(builder: (context, box) {
              final width = (box.maxWidth - 10) / 2;
              return Wrap(spacing: 10, runSpacing: 10, children: [for (final a in achievements) SizedBox(width: width, child: _CustomAchievementBadge(title: a.title, description: a.description, icon: a.icon, accent: a.color, earned: a.earned, tier: a.tier))]);
            }),
            const SizedBox(height: 16), Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: const Color(0xFF07172A), borderRadius: BorderRadius.circular(14), border: Border.all(color: _blue.withOpacity(.7))), child: const Row(children: [Icon(Icons.info, color: _cyan, size: 20), SizedBox(width: 9), Expanded(child: Text('Achievements are calculated from confirmed results across all leagues. Unconfirmed or disputed results do not count.', style: TextStyle(color: _muted, fontSize: 10, height: 1.4)))])),
          ]));
        },
      ),
    );
  }
}

class _CustomAchievementBadge extends StatelessWidget {
  final String title, description, tier;
  final IconData icon;
  final Color accent;
  final bool earned;
  const _CustomAchievementBadge({required this.title, required this.description, required this.icon, required this.accent, required this.earned, required this.tier});

  @override Widget build(BuildContext context) {
    final dim = earned ? 1.0 : .68;
    return Container(
      constraints: const BoxConstraints(minHeight: 180),
      padding: const EdgeInsets.fromLTRB(9, 11, 9, 10),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(17), border: Border.all(color: accent.withOpacity(earned ? .98 : .55), width: earned ? 1.5 : 1), gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color.lerp(const Color(0xFF1B1307), accent, earned ? .18 : .07)!, const Color(0xFF100B05), const Color(0xFF091A31)]), boxShadow: earned ? [BoxShadow(color: accent.withOpacity(.18), blurRadius: 17)] : []),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: SizedBox(width: 86, height: 84, child: Stack(alignment: Alignment.center, children: [
          Container(width: 76, height: 76, decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [accent.withOpacity(earned ? .42 : .16), accent.withOpacity(.02)]), border: Border.all(color: accent.withOpacity(earned ? .95 : .45), width: 2), boxShadow: [if (earned) BoxShadow(color: accent.withOpacity(.35), blurRadius: 17)])),
          Icon(Icons.stars, size: 82, color: accent.withOpacity(earned ? .9 : .3)),
          Container(width: 47, height: 47, decoration: BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: [Color.lerp(accent, Colors.white, .35)!, accent, Color.lerp(accent, Colors.black, .5)!]), border: Border.all(color: Colors.white.withOpacity(.7), width: 1.4), boxShadow: [BoxShadow(color: accent.withOpacity(.3), blurRadius: 9)]), child: Icon(icon, color: const Color(0xFF100B05), size: 27)),
          if (!earned) Positioned(right: 0, bottom: 0, child: Container(padding: const EdgeInsets.all(5), decoration: const BoxDecoration(color: Color(0xFF172A42), shape: BoxShape.circle), child: const Icon(Icons.lock, size: 16, color: Color(0xFF9DAFC5)))),
          if (earned) Positioned(right: 0, bottom: 0, child: Container(padding: const EdgeInsets.all(3), decoration: const BoxDecoration(color: Color(0xFF0DE0A0), shape: BoxShape.circle), child: const Icon(Icons.check, size: 15, color: Color(0xFF04211D)))),
        ]))),
        const SizedBox(height: 7), Center(child: Text(title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: accent.withOpacity(dim), fontSize: 10.5, fontWeight: FontWeight.w900, height: 1.15))),
        const SizedBox(height: 6), Expanded(child: Text(description, textAlign: TextAlign.center, style: const TextStyle(color: _muted, fontSize: 10, height: 1.3))),
        const SizedBox(height: 8), Container(width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 5), decoration: BoxDecoration(borderRadius: BorderRadius.circular(7), color: earned ? accent.withOpacity(.2) : const Color(0xFF1A2D46), border: Border.all(color: accent.withOpacity(earned ? .65 : .2))), child: Text(earned ? 'UNLOCKED' : tier, textAlign: TextAlign.center, style: TextStyle(color: earned ? accent : _muted, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: .6))),
      ]),
    );
  }
}

// ============================================================
// HALL OF FAME — esports-style champion leaderboards
// ============================================================

class HallOfFamePage extends StatefulWidget {
  const HallOfFamePage({super.key});
  @override State<HallOfFamePage> createState() => _HallOfFamePageState();
}

class _HallOfFamePageState extends State<HallOfFamePage> {
  late Future<List<GlobalPlayerStat>> future;
  @override void initState() { super.initState(); future = Store.instance.globalLeaderboard(); }
  Future<void> _refresh() async { setState(() => future = Store.instance.globalLeaderboard()); await future; }

  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('CHIBBYBALL Hall of Fame'), actions: [IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh))]),
    body: FutureBuilder<List<GlobalPlayerStat>>(future: future, builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator(color: _cyan));
      if (snapshot.hasError) return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Could not load Hall of Fame. Pull to refresh.\n${snapshot.error}', textAlign: TextAlign.center)));
      final stats = snapshot.data ?? <GlobalPlayerStat>[];
      if (stats.isEmpty) return const Center(child: Text('No confirmed match records yet.'));
      final points = [...stats]..sort((a,b) => b.points.compareTo(a.points));
      final wins = [...stats]..sort((a,b) => b.won.compareTo(a.won));
      final goals = [...stats]..sort((a,b) => b.goals.compareTo(a.goals));
      final clean = [...stats]..sort((a,b) => b.cleanSheets.compareTo(a.cleanSheets));
      Widget legend(String title, IconData icon, Color color, List<GlobalPlayerStat> list, int Function(GlobalPlayerStat) value, String suffix) => Container(
        margin: const EdgeInsets.only(bottom: 13), padding: const EdgeInsets.fromLTRB(13, 13, 13, 10),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(19), border: Border.all(color: color, width: 1.3), gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [color.withOpacity(.14), const Color(0xFF100B05), const Color(0xFF091A30)]), boxShadow: [BoxShadow(color: color.withOpacity(.12), blurRadius: 18)]),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Icon(icon, color: color, size: 23), const SizedBox(width: 9), Expanded(child: Text(title, style: TextStyle(color: color, fontWeight: FontWeight.w900, letterSpacing: .45, fontSize: 13))), Text('TOP 3', style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w900))]),
          const SizedBox(height: 8),
          for (int i=0; i<list.take(3).length; i++) _HallOfFameRankRow(rank: i + 1, stat: list[i], value: value(list[i]), suffix: suffix, accent: color),
        ]));
      return RefreshIndicator(onRefresh: _refresh, child: ListView(padding: const EdgeInsets.fromLTRB(14, 14, 14, 28), children: [
        Container(
          padding: const EdgeInsets.all(19),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(23),
            border: Border.all(color: _yellow, width: 1.4),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF183C65), Color(0xFF071629), Color(0xFF21162D)],
            ),
            boxShadow: [BoxShadow(color: _yellow.withOpacity(.18), blurRadius: 24)],
          ),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('LEGENDS ARE MADE HERE', style: TextStyle(color: _yellow, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.2)),
              const SizedBox(height: 8),
              const Text('HALL OF FAME', style: TextStyle(fontSize: 27, fontWeight: FontWeight.w900, height: 1)),
              const SizedBox(height: 8),
              const Text('Recognising the best performers across CHIBBYBALL leagues.', style: TextStyle(color: _muted, fontSize: 12, height: 1.4)),
            ])),
            const SizedBox(width: 8),
            Container(
              width: 76,
              height: 88,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [_yellow.withOpacity(.3), Colors.transparent]),
                boxShadow: [BoxShadow(color: _yellow.withOpacity(.22), blurRadius: 20)],
              ),
              child: const Icon(Icons.emoji_events, color: _yellow, size: 67),
            ),
          ]),
        ),
        const SizedBox(height: 16), legend('GLOBAL POINTS LEADERS', Icons.emoji_events, _yellow, points, (s) => s.points, 'PTS'),
        legend('MOST MATCH WINS', Icons.military_tech, _cyan, wins, (s) => s.won, 'WINS'),
        legend('TOP GOAL SCORERS', Icons.sports_soccer, _purple, goals, (s) => s.goals, 'GOALS'),
        legend('CLEAN-SHEET SPECIALISTS', Icons.shield, const Color(0xFF20E79A), clean, (s) => s.cleanSheets, 'CLEAN SHEETS'),
        const Text('Hall of Fame rankings use confirmed matches only and refresh from Supabase.', style: TextStyle(color: _muted, fontSize: 10)),
        const SizedBox(height: 13), SizedBox(height: 48, child: OutlinedButton.icon(style: OutlinedButton.styleFrom(foregroundColor: _cyan, side: const BorderSide(color: _cyan, width: 1.4), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GlobalLeaderboardPage())), icon: const Icon(Icons.public), label: const Text('OPEN GLOBAL RANKING', style: TextStyle(fontWeight: FontWeight.w900, letterSpacing: .4))),),
      ]));
    }),
  );
}

class _HallOfFameRankRow extends StatelessWidget {
  final int rank, value;
  final GlobalPlayerStat stat;
  final String suffix;
  final Color accent;
  const _HallOfFameRankRow({required this.rank, required this.stat, required this.value, required this.suffix, required this.accent});
  @override Widget build(BuildContext context) {
    final medal = rank == 1 ? const Color(0xFFFFC928) : rank == 2 ? const Color(0xFFD7E3F3) : const Color(0xFFFF9147);
    return Container(margin: const EdgeInsets.only(top: 4), padding: const EdgeInsets.symmetric(vertical: 7), decoration: BoxDecoration(border: Border(bottom: BorderSide(color: accent.withOpacity(.12)))), child: Row(children: [
      Container(
        width: 29,
        height: 29,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(colors: [medal, Color.lerp(medal, const Color(0xFF4B3421), .5)!]),
          border: Border.all(color: Colors.white.withOpacity(.65)),
          boxShadow: [BoxShadow(color: medal.withOpacity(.25), blurRadius: 8)],
        ),
        child: Center(
          child: Text('$rank', style: const TextStyle(color: Color(0xFF101827), fontWeight: FontWeight.w900, fontSize: 14)),
        ),
      ),
      const SizedBox(width: 8), _playerAvatar(stat.player, radius: 18, accent: accent), const SizedBox(width: 9), Expanded(child: Text(stat.player.gamerTag, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900))), const SizedBox(width: 6), Flexible(child: Text('$value $suffix', textAlign: TextAlign.end, maxLines: 2, style: TextStyle(color: accent, fontWeight: FontWeight.w900, fontSize: 11))),
    ]));
  }
}

// ============================================================
// PLAYER PROFILE ACHIEVEMENT SHOWCASE
// ============================================================

class PlayerAchievementShowcase extends StatefulWidget {
  final String playerId;
  const PlayerAchievementShowcase({super.key, required this.playerId});
  @override State<PlayerAchievementShowcase> createState() => _PlayerAchievementShowcaseState();
}

class _PlayerAchievementShowcaseState extends State<PlayerAchievementShowcase> {
  late Future<List<GlobalPlayerStat>> _future;
  @override void initState() { super.initState(); _future = Store.instance.globalLeaderboard(); }
  Future<void> _refresh() async { setState(() => _future = Store.instance.globalLeaderboard()); await _future; }

  @override Widget build(BuildContext context) {
    return FutureBuilder<List<GlobalPlayerStat>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(padding: const EdgeInsets.all(18), decoration: _neonBox(_purple, radius: 18), child: const Center(child: CircularProgressIndicator(color: _cyan)));
        }
        if (snapshot.hasError) {
          return Container(padding: const EdgeInsets.all(16), decoration: _neonBox(_purple, radius: 18), child: Row(children: [const Icon(Icons.military_tech, color: _purple), const SizedBox(width: 10), const Expanded(child: Text('Achievement showcase could not load.')), IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh, color: _cyan))]));
        }
        final all = snapshot.data ?? <GlobalPlayerStat>[];
        final index = all.indexWhere((s) => s.player.id == widget.playerId);
        if (index < 0) {
          return Container(padding: const EdgeInsets.all(16), decoration: _neonBox(_purple, radius: 18), child: const Text('Your achievements will appear here after your player statistics load.', style: TextStyle(color: _muted)));
        }
        final stat = all[index];
        final badges = <({String title, String detail, IconData icon, Color color, bool earned})>[
          (title: 'FIRST VICTORY', detail: '1 win', icon: Icons.sports_soccer, color: _yellow, earned: stat.won >= 1),
          (title: 'HAT-TRICK HERO', detail: '3 wins', icon: Icons.local_fire_department, color: const Color(0xFFFF512F), earned: stat.won >= 3),
          (title: 'FIVE-STAR WINNER', detail: '5 wins', icon: Icons.stars, color: const Color(0xFFFFB547), earned: stat.won >= 5),
          (title: 'GOAL MACHINE', detail: '10 goals', icon: Icons.bolt, color: _cyan, earned: stat.goals >= 10),
          (title: 'CLINICAL FINISHER', detail: '25 goals', icon: Icons.gps_fixed, color: const Color(0xFFFF4658), earned: stat.goals >= 25),
          (title: 'THE WALL', detail: '5 clean sheets', icon: Icons.shield, color: const Color(0xFFFFD34A), earned: stat.cleanSheets >= 5),
          (title: 'VETERAN', detail: '25 matches', icon: Icons.workspace_premium, color: _purple, earned: stat.played >= 25),
          (title: 'CENTURION', detail: '100 matches', icon: Icons.workspace_premium, color: _yellow, earned: stat.played >= 100),
          (title: 'UNBEATEN RUN', detail: '5 matches unbeaten', icon: Icons.security, color: const Color(0xFF31E69A), earned: stat.played >= 5 && stat.lost == 0),
          (title: 'GLOBAL TOP 3', detail: 'Top 3 global points', icon: Icons.emoji_events, color: const Color(0xFFFF9E32), earned: index < 3),
        ];
        final earned = badges.where((b) => b.earned).toList();
        return Container(
          padding: const EdgeInsets.all(15),
          decoration: _neonBox(_purple, radius: 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Expanded(child: _neonSectionTitle('MY ACHIEVEMENTS', accent: _purple)), IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh, color: _cyan), tooltip: 'Refresh achievements')]),
            const SizedBox(height: 4),
            Row(children: [Icon(Icons.emoji_events, color: _yellow, size: 22), const SizedBox(width: 7), Text('${earned.length} / ${badges.length} UNLOCKED', style: const TextStyle(color: _yellow, fontWeight: FontWeight.w900, fontSize: 12)), const Spacer(), Text('GLOBAL RANK #${index + 1}', style: const TextStyle(color: _cyan, fontSize: 10, fontWeight: FontWeight.w900))]),
            const SizedBox(height: 12),
            Wrap(spacing: 9, runSpacing: 9, children: [
              for (final b in earned) Container(width: 94, padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 10), decoration: BoxDecoration(borderRadius: BorderRadius.circular(13), border: Border.all(color: b.color.withOpacity(.85)), color: b.color.withOpacity(.09), boxShadow: [BoxShadow(color: b.color.withOpacity(.08), blurRadius: 10)]), child: Column(children: [Container(width: 42, height: 42, decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [b.color.withOpacity(.35), b.color.withOpacity(.06)]), border: Border.all(color: b.color, width: 1.4)), child: Icon(b.icon, color: b.color, size: 24)), const SizedBox(height: 7), Text(b.title, textAlign: TextAlign.center, maxLines: 2, style: TextStyle(color: b.color, fontSize: 9, fontWeight: FontWeight.w900)), const SizedBox(height: 3), Text(b.detail, textAlign: TextAlign.center, style: const TextStyle(color: _muted, fontSize: 9))])),
              if (earned.isEmpty) const Text('Play and win confirmed matches to unlock your first badge.', style: TextStyle(color: _muted, fontSize: 12)),
            ]),
            const SizedBox(height: 14),
            const Text('CAREER RECORD • CONFIRMED MATCHES ONLY', style: TextStyle(color: _muted, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: .4)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _profileCareerChip('PLAYED', stat.played, _cyan), _profileCareerChip('WINS', stat.won, _yellow), _profileCareerChip('GOALS', stat.goals, _purple), _profileCareerChip('CLEAN SHEETS', stat.cleanSheets, const Color(0xFF31E69A)), _profileCareerChip('POINTS', stat.points, _yellow),
            ]),
            const SizedBox(height: 10),
            SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AchievementsPage())), icon: const Icon(Icons.military_tech), label: const Text('VIEW ALL BADGES'))),
          ]),
        );
      },
    );
  }
}

Widget _profileCareerChip(String label, int value, Color color) => Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: color.withOpacity(.08), border: Border.all(color: color.withOpacity(.5))), child: Column(mainAxisSize: MainAxisSize.min, children: [Text('$value', style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.w900)), const SizedBox(height: 2), Text(label, style: const TextStyle(color: _muted, fontSize: 8, fontWeight: FontWeight.w800))]));

// ============================================================
// PROFILE
// ============================================================


// ============================================================
// ============================================================
// CHIBBYBALL PLAYER FEATURES: complete workflows for social,
// competition, missions and public community activity.
// ============================================================
class PlayerFeaturesHubPage extends StatelessWidget {
  const PlayerFeaturesHubPage({super.key});
  void _open(BuildContext context, Widget page) => Navigator.push(context, MaterialPageRoute(builder: (_) => page));
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('PLAYER FEATURES')),
    body: ListView(padding: const EdgeInsets.all(16), children: [
      Container(padding: const EdgeInsets.all(18), decoration: _neonBox(_cyan, radius: 20), child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('LEVEL UP YOUR GAME', style: TextStyle(color: _cyan, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.5)), SizedBox(height: 7), Text('More than fixtures and tables.', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900)), SizedBox(height: 5), Text('Challenge rivals, build your circle, follow activity and track your season.', style: TextStyle(color: _muted, height: 1.4))])),
      const SizedBox(height: 14),
      _featureTile(context, Icons.flash_on, 'RIVAL CHALLENGES', 'Find a player, send a challenge, and accept or decline incoming challenges.', _yellow, () => _open(context, const RivalChallengesPage())),
      _featureTile(context, Icons.dynamic_feed, 'LIVE ACTIVITY FEED', 'Read community updates and publish an announcement.', _cyan, () => _open(context, const CommunityActivityPage())),
      _featureTile(context, Icons.account_tree, 'TOURNAMENT MODE', 'Create tournaments, browse competitions, and register to play.', _purple, () => _open(context, const CommunityTournamentsPage())),
      _featureTile(context, Icons.flag, 'DAILY & WEEKLY MISSIONS', 'Create personal objectives, update progress, and mark rewards claimed.', _blue, () => _open(context, const PlayerMissionsPage())),
      _featureTile(context, Icons.people, 'FRIENDS SYSTEM', 'Find players, send requests, and accept or decline incoming requests.', const Color(0xFF20E070), () => _open(context, const PlayerFriendsPage())),
      _featureTile(context, Icons.military_tech, 'SEASON AWARDS', 'See champions, top scorers, winners and clean-sheet leaders.', _yellow, () => _open(context, const SeasonAwardsPage())),
      _featureTile(context, Icons.compare_arrows, 'HEAD-TO-HEAD', 'Compare your confirmed match record against any opponent.', _cyan, () => _open(context, const HeadToHeadPage())),
      _featureTile(context, Icons.badge, 'MY PLAYER SHOWCASE', 'Your career card and unlocked achievement badges.', _purple, () { final id=Store.instance.current?.id; if(id!=null) _open(context, PlayerShowcasePage(playerId:id)); }),
      const SizedBox(height: 10),
      const Text('Daily and weekly challenges are generated automatically from confirmed match activity. Super Beans rewards are not implemented yet.', style: TextStyle(color: _muted, fontSize: 11, height: 1.4)),
    ]));
  Widget _featureTile(BuildContext context, IconData icon, String title, String subtitle, Color color, VoidCallback tap) => Container(margin: const EdgeInsets.only(bottom: 10), decoration: _neonBox(color,radius:16), child: ListTile(onTap:tap, contentPadding: const EdgeInsets.symmetric(horizontal:14,vertical:5), leading: Container(width:43,height:43,decoration:BoxDecoration(color:color.withOpacity(.13),borderRadius:BorderRadius.circular(13)),child:Icon(icon,color:color)), title:Text(title,style:const TextStyle(fontWeight:FontWeight.w900,fontSize:13)), subtitle:Text(subtitle,style:const TextStyle(color:_muted,fontSize:11,height:1.3)), trailing:const Icon(Icons.chevron_right,color:_muted)));
}

mixin _FeaturePageHelpers<T extends StatefulWidget> on State<T> {
  String? get _userId => Store.instance.supabase.auth.currentUser?.id;
  void _toast(String message) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message))); }
  Future<List<Map<String,dynamic>>> _loadProfiles() async {
    final result = await Store.instance.supabase.from('profiles').select('id, gamer_tag, full_name').limit(300);
    return (result as List).map((e)=>Map<String,dynamic>.from(e as Map)).where((p)=>p['id']?.toString()!=_userId).toList();
  }
  String _playerName(Map<String,dynamic> p) {
    final tag=(p['gamer_tag']??'').toString().trim();
    return tag.isNotEmpty ? tag : ((p['full_name']??'Player').toString());
  }
  Future<void> _runAction(Future<void> Function() action, String success) async {
    try { await action(); if (mounted) _toast(success); }
    catch(e) { if(mounted) _toast('Action failed: $e'); }
  }
}

class RivalChallengesPage extends StatefulWidget { const RivalChallengesPage({super.key}); @override State<RivalChallengesPage> createState()=>_RivalChallengesPageState(); }
class _RivalChallengesPageState extends State<RivalChallengesPage> with _FeaturePageHelpers<RivalChallengesPage> {
  bool loading=true; String? error; List<Map<String,dynamic>> rows=[]; List<Map<String,dynamic>> profiles=[];
  @override void initState(){super.initState();_load();}
  Future<void> _load() async { if(mounted)setState(()=>loading=true); try { final id=_userId; if(id==null) throw Exception('Please sign in again.'); final a=await Store.instance.supabase.from('rival_challenges').select().order('created_at',ascending:false).limit(200); rows=(a as List).map((e)=>Map<String,dynamic>.from(e as Map)).toList(); profiles=await _loadProfiles(); error=null; } catch(e){error=e.toString();} if(mounted)setState(()=>loading=false); }
  Future<void> _sendChallenge() async { if(profiles.isEmpty){_toast('No other players were found.');return;} String? selected; final msg=TextEditingController(text:'Let’s play an eFootball match!'); final ok=await showDialog<bool>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,setD)=>AlertDialog(title:const Text('Challenge a rival'),content:Column(mainAxisSize:MainAxisSize.min,children:[DropdownButtonFormField<String>(isExpanded:true,decoration:const InputDecoration(labelText:'Choose player'),items:profiles.map((p)=>DropdownMenuItem(value:p['id'].toString(),child:Text(_playerName(p),overflow:TextOverflow.ellipsis))).toList(),onChanged:(v)=>setD(()=>selected=v)),const SizedBox(height:10),TextField(controller:msg,maxLines:2,maxLength:160,decoration:const InputDecoration(labelText:'Message (optional)',border:OutlineInputBorder()))]),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('CANCEL')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('SEND'))]))); if(ok!=true||selected==null)return; try { await Store.instance.supabase.from('rival_challenges').insert({'challenger_id':_userId,'opponent_id':selected,'message':msg.text.trim()}); _toast('Challenge sent.'); await _load(); } catch(e){_toast('Could not send challenge: $e');} finally {msg.dispose();} }
  Future<void> _status(Map<String,dynamic> r,String status) async {
    final uid = _userId;
    if (uid == null) { _toast('Please sign in again.'); return; }
    final incoming = r['opponent_id']?.toString() == uid;
    if (!incoming || (r['status'] ?? 'pending').toString().toLowerCase() != 'pending') {
      _toast('Only the recipient can respond to a pending challenge.');
      return;
    }
    try {
      final updated = await Store.instance.supabase.from('rival_challenges')
          .update({'status': status, 'updated_at': DateTime.now().toUtc().toIso8601String()})
          .eq('id', r['id']).eq('opponent_id', uid).ilike('status', 'pending').select('id');
      if ((updated as List).isEmpty) {
        _toast('Challenge was not updated. Check the database update permissions, then refresh.');
        await _load();
        return;
      }
      _toast(status == 'accepted' ? 'Challenge accepted.' : 'Challenge declined.');
      await _load();
    } catch (e) { _toast('Could not update challenge: $e'); }
  }
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('RIVAL CHALLENGES'),actions:[IconButton(onPressed:_load,icon:const Icon(Icons.refresh))]),floatingActionButton:FloatingActionButton.extended(onPressed:_sendChallenge,icon:const Icon(Icons.flash_on),label:const Text('CHALLENGE')),body:loading?const Center(child:CircularProgressIndicator()):error!=null?Center(child:Text('Could not load challenges.\n$error',textAlign:TextAlign.center)):rows.isEmpty?const _FeatureEmpty(icon:Icons.flash_on,title:'No challenges yet',message:'Send your first challenge to another CHIBBYBALL player.'):ListView(padding:const EdgeInsets.all(14),children:rows.map((r){final incoming=r['opponent_id']==_userId; final person=profiles.where((p)=>p['id']==(incoming?r['challenger_id']:r['opponent_id'])).firstOrNull; final status=(r['status']??'pending').toString(); return _featureCard(_yellow,Icons.flash_on,_playerName(person??{'gamer_tag':incoming?'Your challenger':'Opponent'}), (r['message']??'eFootball challenge').toString(),status, actions: incoming&&status=='pending'?[TextButton(onPressed:()=>_status(r,'declined'),child:const Text('DECLINE')),FilledButton(onPressed:()=>_status(r,'accepted'),child:const Text('ACCEPT'))]:status=='accepted'?[FilledButton(onPressed:()=>Navigator.of(context).push(MaterialPageRoute(builder:(_)=>FriendlyMatchPage(challenge:r,profiles:profiles))).then((_)=>_load()),child:const Text('OPEN FRIENDLY MATCH'))]:[]);}).toList()));
}

class FriendlyMatchPage extends StatefulWidget {
  final Map<String,dynamic> challenge;
  final List<Map<String,dynamic>> profiles;
  const FriendlyMatchPage({super.key, required this.challenge, required this.profiles});
  @override State<FriendlyMatchPage> createState()=>_FriendlyMatchPageState();
}
class _FriendlyMatchPageState extends State<FriendlyMatchPage> with _FeaturePageHelpers<FriendlyMatchPage> {
  bool loading=true, busy=false; String? error; Map<String,dynamic>? match;
  final oneScore=TextEditingController(), twoScore=TextEditingController(); File? proof;
  @override void initState(){super.initState();_load();}
  @override void dispose(){oneScore.dispose();twoScore.dispose();super.dispose();}
  String _tag(String? id){final p=widget.profiles.where((x)=>x['id']?.toString()==id).firstOrNull;return _playerName(p??{'gamer_tag':'Player'});}
  Future<void> _load() async {try {final c=widget.challenge; final q=await Store.instance.supabase.from('friendly_matches').select().eq('challenge_id',c['id']).maybeSingle();match=q==null?null:Map<String,dynamic>.from(q); if(match!=null){oneScore.text='${match!['player_one_score']??''}';twoScore.text='${match!['player_two_score']??''}';}} catch(e){error=e.toString();} if(mounted)setState(()=>loading=false);}
  Future<void> _pickProof() async {final x=await ImagePicker().pickImage(source:ImageSource.gallery,imageQuality:85);if(x!=null&&mounted)setState(()=>proof=File(x.path));}
  Future<void> _ensureMatch() async {final c=widget.challenge;final uid=_userId;if(uid==null)throw Exception('Please sign in again.');final a=c['challenger_id'].toString(),b=c['opponent_id'].toString();final data=await Store.instance.supabase.from('friendly_matches').upsert({'challenge_id':c['id'],'player_one_id':a,'player_two_id':b,'status':'pending'},onConflict:'challenge_id').select().single();match=Map<String,dynamic>.from(data);}
  Future<void> _submit() async {if(busy)return;setState(()=>busy=true);try{await _ensureMatch();final m=match!;final uid=_userId!;final isOne=m['player_one_id'].toString()==uid;final a=int.tryParse(oneScore.text.trim()),b=int.tryParse(twoScore.text.trim());if(a==null||b==null||a<0||b<0)throw Exception('Enter a valid final score for both players.');if(proof==null && (m[isOne?'player_one_proof_path':'player_two_proof_path']==null))throw Exception('Please select a screenshot of the completed match.');String? path=m[isOne?'player_one_proof_path':'player_two_proof_path']?.toString();if(proof!=null){path='$uid/friendly-${m['id']}-${DateTime.now().millisecondsSinceEpoch}.jpg';await Store.instance.supabase.storage.from('match-proofs').upload(path,proof!,fileOptions:const FileOptions(upsert:true));}
      final update=<String,dynamic>{isOne?'player_one_score':'player_two_score':isOne?a:b,isOne?'player_one_proof_path':'player_two_proof_path':path,isOne?'player_one_submitted_at':'player_two_submitted_at':DateTime.now().toUtc().toIso8601String(),'status':(m[isOne?'player_two_submitted_at':'player_one_submitted_at']!=null)?'confirmed':'awaiting_confirmation'};
      // Scores must agree between both submissions before a result is confirmed.
      if(m[isOne?'player_two_submitted_at':'player_one_submitted_at']!=null){final otherScoreA=(m['player_one_score'] as num?)?.toInt(), otherScoreB=(m['player_two_score'] as num?)?.toInt();if(otherScoreA!=a||otherScoreB!=b)update['status']='disputed';else update['status']='confirmed';}
      final saved=await Store.instance.supabase.from('friendly_matches').update(update).eq('id',m['id']).select().single();match=Map<String,dynamic>.from(saved);if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(match!['status']=='confirmed'?'Friendly result confirmed and added to global rankings.':'Screenshot and score submitted; waiting for the other player.')));await _load();
    }catch(e){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text('Could not submit friendly result: $e')));}finally{if(mounted)setState(()=>busy=false);}}
  @override Widget build(BuildContext context){final c=widget.challenge;final one=c['challenger_id']?.toString();final two=c['opponent_id']?.toString();return Scaffold(appBar:AppBar(title:const Text('FRIENDLY MATCH')),body:loading?const Center(child:CircularProgressIndicator()):ListView(padding:const EdgeInsets.all(16),children:[_featureCard(_cyan,Icons.sports_esports,'${_tag(one)} vs ${_tag(two)}','Friendly match • Does not affect an official league table',match?['status']?.toString()??'not started'),if(error!=null)Text(error!,style:const TextStyle(color:Colors.red)),TextField(controller:oneScore,keyboardType:TextInputType.number,decoration:InputDecoration(labelText:'${_tag(one)} score')),TextField(controller:twoScore,keyboardType:TextInputType.number,decoration:InputDecoration(labelText:'${_tag(two)} score')),const SizedBox(height:12),OutlinedButton.icon(onPressed:_pickProof,icon:const Icon(Icons.image),label:Text(proof==null?'Choose match screenshot':'Screenshot selected')),const SizedBox(height:12),FilledButton(onPressed:busy?null:_submit,child:Text(busy?'SUBMITTING...':'SUBMIT SCORE & SCREENSHOT')),const SizedBox(height:8),const Text('Both players must submit matching scores and screenshot evidence. Only confirmed friendly matches count toward the Global Leaderboard and Hall of Fame.',style:TextStyle(color:_muted))]));}
}

class CommunityActivityPage extends StatefulWidget { const CommunityActivityPage({super.key}); @override State<CommunityActivityPage> createState()=>_CommunityActivityPageState(); }
class _CommunityActivityPageState extends State<CommunityActivityPage> with _FeaturePageHelpers<CommunityActivityPage> {
  bool loading=true; String? error; List<Map<String,dynamic>> rows=[];
  @override void initState(){super.initState();_load();}

  String _nameFor(String? id, Map<String,Map<String,dynamic>> byId) {
    final p=id==null?null:byId[id];
    final tag=(p?['gamer_tag']??'').toString().trim();
    return tag.isNotEmpty?tag:(p?['full_name']??'Player').toString();
  }

  Future<void> _load() async {
    if (mounted) setState(() => loading = true);
    try {
      final id = _userId;
      if (id == null) throw Exception('Please sign in again.');
      final prof = await Store.instance.supabase
          .from('profiles').select('id,gamer_tag,full_name').limit(500);
      final byId = <String, Map<String, dynamic>>{};
      for (final item in (prof as List)) {
        final r = Map<String, dynamic>.from(item as Map);
        if (r['id'] != null) byId[r['id'].toString()] = r;
      }

      // Read stored public posts, but never try to insert generated posts from
      // a normal player's client. That was triggering the community_activity RLS error.
      final stored = await Store.instance.supabase.from('community_activity')
          .select().eq('is_public', true)
          .order('created_at', ascending: false).limit(200);
      final combined = (stored as List)
          .map((e) => Map<String, dynamic>.from(e as Map)).toList();

      // Generate confirmed-match announcements locally for this view. They are
      // not persisted, so this works without granting players broad INSERT rights.
      final raw = await Store.instance.supabase.from('matches')
          .select('id, home_player_id, away_player_id, home_score, away_score, status, created_at')
          .ilike('status', 'confirmed').order('created_at', ascending: false).limit(100).timeout(const Duration(seconds: 12));
      for (final item in (raw as List)) {
        final m = Map<String, dynamic>.from(item as Map);
        final hs = (m['home_score'] as num?)?.toInt();
        final ascore = (m['away_score'] as num?)?.toInt();
        final homeId = m['home_player_id']?.toString();
        final awayId = m['away_player_id']?.toString();
        if (hs == null || ascore == null || homeId == null || awayId == null) continue;
        final home = _nameFor(homeId, byId);
        final away = _nameFor(awayId, byId);
        final result = hs == ascore ? 'drew with' : hs > ascore ? 'defeated' : 'lost to';
        combined.add({
          'id': 'local-match-${m['id']}', 'title': 'Confirmed match result',
          'message': '$home $result $away $hs–$ascore.',
          'activity_type': 'result', 'is_public': true,
          'created_at': m['created_at'] ?? DateTime.now().toUtc().toIso8601String(),
        });
      }

      // Ranking snapshots are optional. If their table or policies are not
      // configured, the feed still loads rather than failing completely.
      try {
        final leaderboard = await Store.instance.globalLeaderboard();
        if (leaderboard.isNotEmpty) {
          final snapshotRows = await Store.instance.supabase
              .from('community_rank_snapshots').select('player_id,rank').limit(1000);
          final previous = <String, int>{};
          for (final item in (snapshotRows as List)) {
            final r = Map<String, dynamic>.from(item as Map);
            final pid = r['player_id']?.toString();
            final rank = (r['rank'] as num?)?.toInt();
            if (pid != null && rank != null) previous[pid] = rank;
          }
          for (var i = 0; i < leaderboard.length; i++) {
            final stat = leaderboard[i];
            final old = previous[stat.player.id];
            final rank = i + 1;
            if (old != null && old != rank) {
              final movement = old - rank;
              final verb = movement > 0
                  ? 'moved up $movement ${movement == 1 ? 'place' : 'places'}'
                  : 'moved down ${movement.abs()} ${movement.abs() == 1 ? 'place' : 'places'}';
              combined.add({
                'id': 'local-rank-${stat.player.id}-$rank',
                'title': 'Global ranking movement',
                'message': '${stat.player.gamerTag.isNotEmpty ? stat.player.gamerTag : stat.player.name} $verb in the global rankings (#$old → #$rank).',
                'activity_type': 'achievement', 'is_public': true,
                'created_at': DateTime.now().toUtc().toIso8601String(),
              });
            }
          }
        }
      } catch (_) {
        // Optional table/policy issue: do not block the main activity feed.
      }

      combined.sort((a, b) => (DateTime.tryParse((b['created_at'] ?? '').toString()) ?? DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(DateTime.tryParse((a['created_at'] ?? '').toString()) ?? DateTime.fromMillisecondsSinceEpoch(0)));
      rows = combined.take(200).toList();
      error = null;
    } catch (e) {
      error = e.toString();
    }
    if (mounted) setState(() => loading = false);
  }
  @override Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:const Text('LIVE ACTIVITY FEED'),actions:[IconButton(onPressed:_load,icon:const Icon(Icons.refresh))]),
    body:loading?const Center(child:CircularProgressIndicator()):error!=null
      ?Center(child:Padding(padding:const EdgeInsets.all(18),child:Text('Could not load activity.\n$error',textAlign:TextAlign.center)))
      :rows.isEmpty?const _FeatureEmpty(icon:Icons.dynamic_feed,title:'The feed is quiet',message:'Confirmed match results and ranking changes will appear here automatically.')
      :ListView(padding:const EdgeInsets.all(14),children:rows.map((r){
        final type=(r['activity_type']??'community').toString();
        final title=(r['title']??'CHIBBYBALL update').toString();
        final icon=type=='result'?Icons.sports_soccer:type=='achievement'?Icons.leaderboard:Icons.dynamic_feed;
        final color=type=='result'?_yellow:type=='achievement'?_purple:_cyan;
        return _featureCard(color,icon,title,(r['message']??'').toString(),type);
      }).toList()));
}

class CommunityTournamentsPage extends StatefulWidget { const CommunityTournamentsPage({super.key}); @override State<CommunityTournamentsPage> createState()=>_CommunityTournamentsPageState(); }
class _CommunityTournamentsPageState extends State<CommunityTournamentsPage> with _FeaturePageHelpers<CommunityTournamentsPage> {
  bool loading=true; String? error; List<Map<String,dynamic>> rows=[];
  List<Map<String,dynamic>> entries=[];
  List<Map<String,dynamic>> profiles=[];
  List<Map<String,dynamic>> tournamentMatches=[];
  bool get _isAdmin => Store.instance.current?.admin == true;
  @override void initState(){super.initState();_load();}

  Future<void> _load() async {
    if(mounted)setState(()=>loading=true);
    try {
      final q=await Store.instance.supabase.from('community_tournaments').select().order('created_at',ascending:false).limit(150);
      rows=(q as List).map((e)=>Map<String,dynamic>.from(e as Map)).toList();
      final uid=_userId;
      if (uid != null) {
        final query=Store.instance.supabase.from('tournament_entries').select('id,tournament_id,player_id,status');
        final e=_isAdmin ? await query.limit(1000) : await query.eq('player_id',uid).limit(300);
        entries=(e as List).map((x)=>Map<String,dynamic>.from(x as Map)).toList();
      } else { entries=[]; }
      final p=await Store.instance.supabase.from('profiles').select('id,gamer_tag,full_name').limit(1000);
      profiles=(p as List).map((x)=>Map<String,dynamic>.from(x as Map)).toList();
      try { final mm=await Store.instance.supabase.from('tournament_matches').select().order('round_number').limit(2000); tournamentMatches=(mm as List).map((x)=>Map<String,dynamic>.from(x as Map)).toList(); } catch (_) { tournamentMatches=[]; }
      error=null;
    } catch(e) { error=e.toString(); }
    if(mounted)setState(()=>loading=false);
  }

  String _playerTag(String? id) {
    final p=profiles.where((x)=>x['id']?.toString()==id).firstOrNull;
    final tag=(p?['gamer_tag']??'').toString().trim();
    if(tag.isNotEmpty) return tag;
    final name=(p?['full_name']??'').toString().trim();
    return name.isNotEmpty?name:'Player';
  }

  List<Map<String,dynamic>> _matchesFor(String id)=>tournamentMatches.where((m)=>m['tournament_id']?.toString()==id).toList();

  Future<void> _generateFixtures(Map<String,dynamic> t) async {
    if(!_isAdmin) { _toast('Only an administrator can generate fixtures.'); return; }
    final tid=t['id'].toString();
    try {
      if(_matchesFor(tid).isNotEmpty) { _toast('Fixtures already exist.'); return; }
      final approved=_entriesFor(tid).where((e)=>e['status'].toString().toLowerCase()=='approved').toList();
      if(approved.length<2) { _toast('Approve at least two players before generating fixtures.'); return; }
      final format=(t['format']??'knockout').toString().toLowerCase();
      final players=approved.map((e)=>e['player_id'].toString()).toList()..sort();
      final fixtures=<Map<String,dynamic>>[];
      void addMatch(String stage,int round,String a,String b) {
        if(a==b || a=='BYE' || b=='BYE') return;
        fixtures.add({'tournament_id':tid,'stage':stage,'round_number':round,
          'match_number':fixtures.length+1,'player_one_id':a,'player_two_id':b,'status':'scheduled'});
      }
      // Round-robin generator. For Groups, split the approved entrants into groups
      // of up to four; the current table schema stores the stage/round, but not a
      // group label, so each group's fixtures are kept in separate round blocks.
      List<List<String>> roundRobin(List<String> entrants) {
        final pool=List<String>.from(entrants);
        if(pool.length.isOdd) pool.add('BYE');
        final out=<List<String>>[];
        for(var round=0;round<pool.length-1;round++) {
          final pairings=<List<String>>[];
          for(var i=0;i<pool.length~/2;i++) pairings.add([pool[i],pool[pool.length-1-i]]);
          out.add(pairings.expand((p)=>p).toList());
          final last=pool.removeLast(); pool.insert(1,last);
        }
        return out;
      }
      if(format=='league') {
        final rounds=roundRobin(players);
        for(var r=0;r<rounds.length;r++) {
          final flat=rounds[r];
          for(var i=0;i<flat.length;i+=2) addMatch('league',r+1,flat[i],flat[i+1]);
        }
      } else if(format=='groups' || format=='groups_knockout') {
        const groupSize=4;
        final groups=<List<String>>[];
        for(var i=0;i<players.length;i+=groupSize) groups.add(players.sublist(i,(i+groupSize>players.length)?players.length:i+groupSize));
        var roundOffset=0;
        for(final group in groups) {
          final rounds=roundRobin(group);
          for(var r=0;r<rounds.length;r++) {
            final flat=rounds[r];
            for(var i=0;i<flat.length;i+=2) {
              addMatch('groups',roundOffset+r+1,flat[i],flat[i+1]);
            }
          }
          roundOffset+=rounds.length;
        }
        if(format=='groups_knockout') {
          // The knockout phase is created after group results are entered and
          // standings can be calculated. Avoid inventing qualifiers in advance.
        }
      } else {
        // Seed a knockout bracket to the next power of two. First-round byes
        // are advanced automatically by omitting BYE fixtures; the admin can
        // create the next round after entering all first-round results.
        final seeded=List<String>.from(players);
        final target=1<<((seeded.length-1).bitLength);
        while(seeded.length<target) seeded.add('BYE');
        for(var i=0;i<seeded.length;i+=2) addMatch('knockout',1,seeded[i],seeded[i+1]);
      }
      if(fixtures.isEmpty) { _toast('No fixtures could be generated.'); return; }
      await Store.instance.supabase.from('tournament_matches').insert(fixtures);
      await _load();
      _toast(format=='groups_knockout'
        ? 'Group-stage fixtures generated. Generate the knockout phase after group results are complete.'
        : 'Fixtures generated and saved.');
    } catch(e) { _toast('Could not generate fixtures. Check the tournament SQL migration and permissions. Details: $e'); }
  }

  Future<void> _generateNextKnockoutRound(Map<String,dynamic> t) async {
    if(!_isAdmin) { _toast('Only an administrator can generate rounds.'); return; }
    final tid=t['id'].toString();
    try {
      final matches=_matchesFor(tid).where((m)=>(m['stage']??'').toString()=='knockout').toList()
        ..sort((a,b)=>(a['round_number'] as num).compareTo(b['round_number'] as num));
      if(matches.isEmpty) { _toast('Generate the first knockout round first.'); return; }
      final currentRound=matches.map((m)=>(m['round_number'] as num).toInt()).reduce((a,b)=>a>b?a:b);
      final current=matches.where((m)=>(m['round_number'] as num).toInt()==currentRound).toList();
      if(current.any((m)=>(m['status']??'').toString()!='completed')) {
        _toast('Enter results for every match in the current knockout round first.'); return;
      }
      final winners=<String>[];
      for(final m in current) {
        final winner=m['winner_id']?.toString();
        if(winner==null || winner.isEmpty) { _toast('A knockout match is tied. Resolve it before progressing.'); return; }
        winners.add(winner);
      }
      if(winners.length==1) { await _setTournamentStatus(t,'completed'); _toast('Champion: ${_playerTag(winners.single)}'); return; }
      final nextRound=currentRound+1;
      final existing=_matchesFor(tid).any((m)=>(m['stage']??'').toString()=='knockout' && ((m['round_number'] as num?)?.toInt() ?? 0)==nextRound);
      if(existing) { _toast('The next round already exists.'); return; }
      final fixtures=<Map<String,dynamic>>[];
      for(var i=0;i<winners.length;i+=2) {
        if(i+1>=winners.length) { _toast('The winner count is uneven; please review the bracket.'); return; }
        fixtures.add({'tournament_id':tid,'stage':'knockout','round_number':nextRound,
          'match_number':fixtures.length+1,'player_one_id':winners[i],'player_two_id':winners[i+1],'status':'scheduled'});
      }
      await Store.instance.supabase.from('tournament_matches').insert(fixtures);
      await _load(); _toast('Round $nextRound fixtures generated.');
    } catch(e) { _toast('Could not advance knockout round: $e'); }
  }

  Future<void> _enterScore(Map<String,dynamic> m) async {
    if(!_isAdmin) { _toast('Only an administrator can enter tournament scores.'); return; }
    final a=TextEditingController(text:'${m['player_one_score']??''}');
    final b=TextEditingController(text:'${m['player_two_score']??''}');
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(title:const Text('Enter match result'),content:Row(children:[Expanded(child:TextField(controller:a,keyboardType:TextInputType.number,decoration:InputDecoration(labelText:_playerTag(m['player_one_id']?.toString())))),const Padding(padding:EdgeInsets.all(8),child:Text('–')),Expanded(child:TextField(controller:b,keyboardType:TextInputType.number,decoration:InputDecoration(labelText:_playerTag(m['player_two_id']?.toString()))))]),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('CANCEL')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('SAVE'))]));
    if(ok==true) { final x=int.tryParse(a.text.trim()), y=int.tryParse(b.text.trim()); if(x==null||y==null||x<0||y<0) {_toast('Enter valid non-negative scores.');} else { try { await Store.instance.supabase.from('tournament_matches').update({'player_one_score':x,'player_two_score':y,'winner_id':x==y?null:(x>y?m['player_one_id']:m['player_two_id']),'status':'completed'}).eq('id',m['id']); await _load(); _toast('Match result saved.'); if((m['stage']??'').toString()=='knockout') { final tournament=rows.where((t)=>t['id']?.toString()==m['tournament_id']?.toString()).firstOrNull; if(tournament!=null) await _generateNextKnockoutRound(tournament); } } catch(e) {_toast('Could not save result: $e');} } }
    a.dispose(); b.dispose();
  }

  Future<void> _create() async {
    if (!_isAdmin) { _toast('Only an administrator can create tournaments.'); return; }
    final name=TextEditingController(); final desc=TextEditingController(); final max=TextEditingController(text:'8');
    String format='knockout';
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,setD)=>AlertDialog(
      title:const Text('Create tournament'),
      content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
        TextField(controller:name,maxLength:80,decoration:const InputDecoration(labelText:'Tournament name',border:OutlineInputBorder())),
        const SizedBox(height:10),
        TextField(controller:desc,maxLines:3,maxLength:300,decoration:const InputDecoration(labelText:'Description',border:OutlineInputBorder())),
        const SizedBox(height:10),
        DropdownButtonFormField<String>(value:format,decoration:const InputDecoration(labelText:'Format'),items:const [
          DropdownMenuItem(value:'knockout',child:Text('Knockout')),
          DropdownMenuItem(value:'groups',child:Text('Groups')),
          DropdownMenuItem(value:'groups_knockout',child:Text('Groups + knockout')),
          DropdownMenuItem(value:'league',child:Text('League')),
        ],onChanged:(v)=>setD(()=>format=v??'knockout')),
        TextField(controller:max,keyboardType:TextInputType.number,decoration:const InputDecoration(labelText:'Maximum players (2–256)',border:OutlineInputBorder())),
      ])),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('CANCEL')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('CREATE'))],
    )));
    if(ok==true) {
      final count=int.tryParse(max.text.trim())??8;
      if(name.text.trim().length<3||count<2||count>256) { _toast('Use a name of at least 3 characters and a player limit from 2 to 256.'); }
      else {
        try {
          await Store.instance.supabase.from('community_tournaments').insert({
            'created_by':_userId,'name':name.text.trim(),'description':desc.text.trim(),
            'format':format,'max_players':count,'status':'registration',
            // The table also requires tournament_type; keep it aligned with the selected format.
            'tournament_type':format,
          });
          _toast('Tournament created.'); await _load();
        } catch(e) { _toast('Could not create tournament: $e'); }
      }
    }
    name.dispose(); desc.dispose(); max.dispose();
  }

  String _tournamentStatus(Map<String,dynamic> t)=>(t['status']??'registration').toString().trim().toLowerCase();
  List<Map<String,dynamic>> _entriesFor(String tournamentId) => entries.where((e)=>e['tournament_id'].toString()==tournamentId).toList();
  Map<String,dynamic>? _myEntry(String tournamentId) {
    final uid=_userId; if(uid==null)return null;
    for(final e in entries) { if(e['tournament_id'].toString()==tournamentId && e['player_id'].toString()==uid)return e; }
    return null;
  }

  Future<void> _join(Map<String,dynamic> t) async {
    try {
      final status=_tournamentStatus(t);
      if(status!='registration'&&status!='upcoming') { _toast('Registration is closed for this tournament.'); return; }
      final playerId=_userId;
      if(playerId==null) { _toast('Please sign in before requesting to join.'); return; }
      final existing=_myEntry(t['id'].toString());
      if(existing!=null) { _toast('You already have a request or entry for this tournament.'); return; }
      final currentResult=await Store.instance.supabase.from('tournament_entries')
          .select('status').eq('tournament_id',t['id']);
      final currentEntries=(currentResult as List).map((e)=>Map<String,dynamic>.from(e as Map)).toList();
      final maxPlayers=(t['max_players'] as num?)?.toInt()??8;
      final activeCount=currentEntries.where((e) {
        final entryStatus=e['status'].toString().toLowerCase();
        return entryStatus=='approved'||entryStatus=='registered';
      }).length;
      if(activeCount>=maxPlayers) { _toast('This tournament has reached its entry limit, including pending requests.'); return; }
      await Store.instance.supabase.from('tournament_entries').insert({'tournament_id':t['id'],'player_id':playerId,'status':'registered'});
      _toast('Join request sent. The administrator must approve it.'); await _load();
    } catch(e) {
      _toast(e.toString().toLowerCase().contains('duplicate')||e.toString().toLowerCase().contains('unique')
        ? 'You already requested to join this tournament.' : 'Could not send tournament request: $e');
    }
  }

  Future<void> _reviewEntry(Map<String,dynamic> entry, bool approve) async {
    if(!_isAdmin) { _toast('Only an administrator can review tournament requests.'); return; }
    try {
      final id=entry['id'];
      if(approve) {
        final tournamentId=entry['tournament_id'].toString();
        Map<String,dynamic>? tournament;
        for(final item in rows) { if(item['id'].toString()==tournamentId) { tournament=item; break; } }
        final maxPlayers=(tournament?['max_players'] as num?)?.toInt()??8;
        final approved=_entriesFor(tournamentId).where((e)=>e['status'].toString().toLowerCase()=='approved').length;
        if(approved>=maxPlayers) { _toast('The tournament is full. Reject or remove an entry before approving another player.'); return; }
        await Store.instance.supabase.from('tournament_entries').update({'status':'approved'}).eq('id',id).eq('status','registered');
        _toast('Tournament request approved.');
      } else {
        // Rejection is represented by deleting the pending request; no new database status is needed.
        await Store.instance.supabase.from('tournament_entries').delete().eq('id',id).eq('status','registered');
        _toast('Tournament request rejected.');
      }
      await _load();
    } catch(e) { _toast('Could not review tournament request: $e'); }
  }

  Future<void> _showRequests(Map<String,dynamic> t) async {
    final tournamentId=t['id'].toString();
    final requests=_entriesFor(tournamentId).where((e)=>e['status'].toString().toLowerCase()=='registered').toList();
    await showDialog<void>(context:context,builder:(ctx)=>AlertDialog(
      title:Text('JOIN REQUESTS — ${(t['name']??'Tournament').toString()}'),
      content:SizedBox(width:420,child:requests.isEmpty?const Text('There are no pending join requests.'):SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:requests.map((entry)=>Card(child:Padding(padding:const EdgeInsets.all(8),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Text('Player: ${_playerTag(entry['player_id']?.toString())}',style:const TextStyle(fontWeight:FontWeight.bold)),
        const SizedBox(height:6),
        Wrap(spacing:8,children:[OutlinedButton(onPressed:()=>_reviewEntry(entry,true).then((_) { if(ctx.mounted)Navigator.pop(ctx); }),child:const Text('APPROVE')),TextButton(onPressed:()=>_reviewEntry(entry,false).then((_) { if(ctx.mounted)Navigator.pop(ctx); }),child:const Text('REJECT'))]),
      ])))).toList()))),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx),child:const Text('CLOSE'))],
    ));
  }

  Widget _buildTournamentBracket(List<Map<String,dynamic>> matches) {
    if (matches.isEmpty) return const SizedBox.shrink();
    final knockout = matches.where((m) => (m['stage'] ?? '').toString().toLowerCase() == 'knockout').toList();
    final grouped = <int, List<Map<String,dynamic>>>{};
    for (final m in knockout) {
      final round = (m['round_number'] as num?)?.toInt() ?? 1;
      (grouped[round] ??= <Map<String,dynamic>>[]).add(m);
    }
    for (final list in grouped.values) {
      list.sort((a,b) => ((a['match_number'] as num?)?.toInt() ?? 0).compareTo((b['match_number'] as num?)?.toInt() ?? 0));
    }
    String roundName(int round, int maxRound) {
      if (round == maxRound && maxRound > 1) return 'FINAL';
      if (round == maxRound - 1 && maxRound >= 3) return 'SEMI-FINALS';
      if (round == maxRound - 2 && maxRound >= 4) return 'QUARTER-FINALS';
      return 'ROUND $round';
    }
    final maxRound = grouped.keys.isEmpty ? 0 : grouped.keys.reduce((a,b) => a > b ? a : b);
    Widget matchCard(Map<String,dynamic> m) {
      final p1 = _playerTag(m['player_one_id']?.toString());
      final p2 = _playerTag(m['player_two_id']?.toString());
      final winner = m['winner_id']?.toString();
      Widget playerLine(String id, String tag, dynamic score) {
        final isWinner = winner != null && winner == id;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: isWinner ? _cyan.withOpacity(.13) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(children: [
            Expanded(child: Text(tag, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, fontWeight: isWinner ? FontWeight.w900 : FontWeight.w700,
                color: isWinner ? _cyan : null))),
            Text(score?.toString() ?? '—', style: TextStyle(fontWeight: FontWeight.w900,
              color: isWinner ? _cyan : null)),
          ]),
        );
      }
      return Container(
        width: 205, margin: const EdgeInsets.symmetric(vertical: 8), padding: const EdgeInsets.all(8),
        decoration: _neonBox(_purple, radius: 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('MATCH ${m['match_number'] ?? ''}', style: const TextStyle(color: _cyan, fontSize: 10, fontWeight: FontWeight.w900)),
          const SizedBox(height: 5),
          playerLine(m['player_one_id']?.toString() ?? '', p1, m['player_one_score']),
          const Divider(height: 1),
          playerLine(m['player_two_id']?.toString() ?? '', p2, m['player_two_score']),
          const SizedBox(height: 4),
          Row(children: [
            Expanded(child: Text((m['status'] ?? 'scheduled').toString().toUpperCase(), style: const TextStyle(color: _muted, fontSize: 9))),
            if (_isAdmin) IconButton(padding: EdgeInsets.zero, constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              onPressed: () => _enterScore(m), icon: const Icon(Icons.edit_note, color: _cyan, size: 20), tooltip: 'Enter score'),
          ]),
        ]),
      );
    }
    return Container(
      margin: const EdgeInsets.only(top: 10), padding: const EdgeInsets.all(12),
      decoration: _neonBox(_cyan, radius: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('KNOCKOUT BRACKET  •  ${grouped.isEmpty ? 'FIXTURES' : '${grouped.length} ROUNDS'}  •  ${matches.length} MATCHES', style: const TextStyle(color: _cyan, fontWeight: FontWeight.w900)),
        const SizedBox(height: 10),
        if (grouped.isNotEmpty)
          Builder(builder: (context) {
            final firstRound = grouped.keys.reduce((a,b) => a < b ? a : b);
            final firstCount = grouped[firstRound]!.length;
            // Reserve every stage from the opening round to the final, including
            // future stages that have not yet been written to Supabase.
            final stageCount = firstCount <= 1 ? 1 : firstCount.bitLength;
            const cardWidth = 190.0, cardHeight = 116.0;
            const gap = 66.0, rowHeight = 140.0;
            final width = stageCount * (cardWidth + gap) - gap;
            final height = firstCount * rowHeight;
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(width: width, height: height + 38,
                child: Stack(children: [
                  Positioned(top: 35, left: 0,
                    child: CustomPaint(size: Size(width, height),
                      painter: _TournamentTreePainter(firstCount, stageCount,
                        cardWidth, gap, rowHeight))),
                  for (var stage = 0; stage < stageCount; stage++) ...[
                    Positioned(left: stage * (cardWidth + gap), top: 0,
                      width: cardWidth,
                      child: Text(stage == stageCount - 1 ? 'FINAL' :
                        stage == stageCount - 2 ? 'SEMI-FINALS' :
                        stage == stageCount - 3 ? 'QUARTER-FINALS' : 'ROUND ${stage+1}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: _cyan, fontWeight: FontWeight.w900))),
                    for (var index = 0; index < (firstCount >> stage); index++)
                      Positioned(
                        left: stage * (cardWidth + gap),
                        top: 35 + ((1 << stage) * (index + .5) - .5) * rowHeight + (rowHeight-cardHeight)/2,
                        width: cardWidth, height: cardHeight,
                        child: Builder(builder: (_) {
                          final roundMatches = grouped[firstRound + stage] ?? [];
                          if (index < roundMatches.length) {
                            return FittedBox(fit: BoxFit.fill,
                              child: SizedBox(width: 205, height: 130,
                                child: matchCard(roundMatches[index])));
                          }
                          return Container(padding: const EdgeInsets.all(10),
                            decoration: _neonBox(_purple, radius: 10),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center, children: [
                                Text('MATCH ${index+1}', style: const TextStyle(color: _cyan, fontSize: 10)),
                                const SizedBox(height: 8),
                                const Text('Awaiting winner', style: TextStyle(color: _muted)),
                                const Divider(),
                                const Text('Awaiting winner', style: TextStyle(color: _muted)),
                              ]));
                        }),
                      ),
                  ],
                ])),
            );
          }),
        if (grouped.isEmpty)
          ...matches.map((m) => matchCard(m)),
        if (grouped.isNotEmpty && grouped[maxRound]!.length == 1 && (grouped[maxRound]!.first['status'] ?? '').toString() == 'completed') ...[
          const SizedBox(height: 10),
          Container(width: double.infinity, padding: const EdgeInsets.all(12), decoration: _neonBox(_yellow, radius: 10),
            child: Text('🏆 CHAMPION: ${_playerTag(grouped[maxRound]!.first['winner_id']?.toString())}',
              textAlign: TextAlign.center, style: const TextStyle(color: _yellow, fontWeight: FontWeight.w900))),
        ],
      ]),
    );
  }

  Future<void> _reuseTournament(Map<String,dynamic> t) async {
    if (!_isAdmin) { _toast('Only an administrator can restart a tournament.'); return; }
    final tid=t['id'].toString();
    final existing=_matchesFor(tid);
    final confirm=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(
      title:const Text('RESTART THIS TOURNAMENT?'),
      content:Text('This reuses “${t['name'] ?? 'Tournament'}” and keeps its approved players. The current fixture results will be deleted so a fresh run can begin. This database version has no tournament-history archive, so previous match results will not remain available.'),
      actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('CANCEL')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('RESTART'))],
    ));
    if(confirm!=true) return;
    try {
      if(existing.isNotEmpty) await Store.instance.supabase.from('tournament_matches').delete().eq('tournament_id',tid);
      await Store.instance.supabase.from('community_tournaments').update({'status':'ongoing'}).eq('id',tid);
      await _load();
      _toast('Tournament restarted. Tap GENERATE FIXTURES to begin the new run.');
    } catch(e) { _toast('Could not restart tournament: $e'); }
  }

  Future<void> _openFullBracket(Map<String,dynamic> t, List<Map<String,dynamic>> matches) async {
    // Force landscape while the full bracket is open, then restore portrait on exit.
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    try {
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (routeContext) => Scaffold(
          appBar: AppBar(
            title: Text('${t['name'] ?? 'TOURNAMENT'} • BRACKET'),
          ),
          body: SafeArea(
            child: LayoutBuilder(builder: (context, constraints) {
              final knockout = matches.where((m) =>
                (m['stage'] ?? '').toString().toLowerCase() == 'knockout').toList();
              final roundNumbers = knockout.map((m) =>
                (m['round_number'] as num?)?.toInt() ?? 1).toList()..sort();
              final firstRound = roundNumbers.isEmpty ? 1 : roundNumbers.first;
              final firstCount = knockout.where((m) =>
                ((m['round_number'] as num?)?.toInt() ?? 1) == firstRound).length;
              final stages = firstCount <= 1 ? 1 : firstCount.bitLength;
              const cardWidth = 190.0;
              const gap = 66.0;
              const rowHeight = 140.0;
              final contentWidth = (stages * (cardWidth + gap) - gap + 48)
                .clamp(300.0, 100000.0).toDouble();
              final contentHeight = ((firstCount > 0 ? firstCount : 1) * rowHeight + 100)
                .clamp(220.0, 100000.0).toDouble();
              final widthScale = (constraints.maxWidth / contentWidth).clamp(0.1, 1.0).toDouble();
              final heightScale = (constraints.maxHeight / contentHeight).clamp(0.1, 1.0).toDouble();
              final initialScale = widthScale < heightScale ? widthScale : heightScale;

              // Give the bracket its real content dimensions. Without this, the
              // horizontal scroll view sizes itself to the viewport and clips later rounds.
              return Center(child: InteractiveViewer(
                constrained: false,
                minScale: 0.08,
                maxScale: 2.5,
                boundaryMargin: const EdgeInsets.all(100),
                child: Transform.scale(
                  alignment: Alignment.topLeft,
                  scale: initialScale,
                  child: SizedBox(
                    width: contentWidth,
                    height: contentHeight,
                    child: OverflowBox(
                      alignment: Alignment.topLeft,
                      minWidth: contentWidth,
                      maxWidth: contentWidth,
                      minHeight: contentHeight,
                      maxHeight: contentHeight,
                      child: _buildTournamentBracket(matches),
                    ),
                  ),
                ),
              ));
            }),
          ),
        ),
      ));
    } finally {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
    }
  }

  Future<void> _setTournamentStatus(Map<String,dynamic> t,String status) async {
    if(!_isAdmin) { _toast('Only an administrator can manage tournaments.'); return; }
    try {
      await Store.instance.supabase.from('community_tournaments').update({'status':status}).eq('id',t['id']);
      _toast(status=='ongoing'?'Tournament started.':'Tournament status updated.'); await _load();
    } catch(e) { _toast('Could not update tournament: $e'); }
  }

  @override
  Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:const Text('TOURNAMENT MODE'),actions:[IconButton(onPressed:_load,icon:const Icon(Icons.refresh))]),
    floatingActionButton:_isAdmin?FloatingActionButton.extended(onPressed:_create,icon:const Icon(Icons.add),label:const Text('CREATE')):null,
    body:loading?const Center(child:CircularProgressIndicator()):error!=null?Center(child:Text('Could not load tournaments.\n$error',textAlign:TextAlign.center)):
      rows.isEmpty?const _FeatureEmpty(icon:Icons.account_tree,title:'No tournaments yet',message:'The administrator will publish community tournaments here.'):
      ListView(padding:const EdgeInsets.all(14),children:rows.map((t){
        final status=_tournamentStatus(t); final id=t['id'].toString(); final myEntry=_myEntry(id);
        final isOpen=status=='registration'||status=='upcoming';
        final myStatus=myEntry?['status']?.toString().toLowerCase();
        final actions=<Widget>[];
        if(isOpen&&myEntry==null) actions.add(FilledButton(onPressed:()=>_join(t),child:const Text('REQUEST TO JOIN')));
        if(myStatus=='registered') actions.add(const Chip(label:Text('REQUEST PENDING')));
        if(myStatus=='approved') actions.add(const Chip(label:Text('APPROVED')));
        if(_isAdmin) {
          final pending=_entriesFor(id).where((e)=>e['status'].toString().toLowerCase()=='registered').length;
          actions.add(OutlinedButton(onPressed:()=>_showRequests(t),child:Text('JOIN REQUESTS ($pending)')));
          if(isOpen) actions.add(TextButton(onPressed:()=>_setTournamentStatus(t,'ongoing'),child:const Text('START')));
          if(status=='ongoing' && _matchesFor(id).isEmpty) actions.add(TextButton(onPressed:()=>_generateFixtures(t),child:const Text('GENERATE FIXTURES')));
          if(status=='completed' || status=='cancelled') actions.add(TextButton(onPressed:()=>_reuseTournament(t),child:const Text('REUSE TOURNAMENT')));
          if(status=='ongoing' && _matchesFor(id).any((m)=>(m['stage']??'').toString()=='knockout')) actions.add(TextButton(onPressed:()=>_generateNextKnockoutRound(t),child:const Text('NEXT KNOCKOUT ROUND')));
          if(status=='ongoing') actions.add(TextButton(onPressed:()=>_setTournamentStatus(t,'completed'),child:const Text('FINISH')));
          if(status!='completed'&&status!='cancelled') actions.add(TextButton(onPressed:()=>_setTournamentStatus(t,'cancelled'),child:const Text('CANCEL')));
        }
        final displayStatus=status.replaceAll('_',' ').toUpperCase();
        final approved=_entriesFor(id).where((e)=>e['status'].toString().toLowerCase()=='approved').length;
        final matchRows=_matchesFor(id);
        final orderedMatches=List<Map<String,dynamic>>.from(matchRows)..sort((a,b){ final stage=(a['stage']??'').toString().compareTo((b['stage']??'').toString()); if(stage!=0)return stage; final round=((a['round_number']??1) as num).compareTo((b['round_number']??1) as num); if(round!=0)return round; return ((a['match_number']??0) as num).compareTo((b['match_number']??0) as num); });
        // Keep the tournament list compact. The actual bracket opens on its
        // own screen so it is not clipped inside a tournament card.
        final matchesPanel = matchRows.isEmpty
            ? const SizedBox.shrink()
            : Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => _openFullBracket(t, orderedMatches),
                  icon: const Icon(Icons.fullscreen),
                  label: const Text('OPEN FULL-SCREEN BRACKET'),
                ),
              );
        return Column(children:[_featureCard(_purple,Icons.account_tree,(t['name']??t['title']??'Tournament').toString(),
          '${t['description']??''}\nFormat: ${(t['format']??'knockout').toString()} • Players: $approved/${t['max_players']??8}',displayStatus,actions:actions),matchesPanel]);
      }).toList()),
  );
}

class PlayerMissionsPage extends StatefulWidget { const PlayerMissionsPage({super.key}); @override State<PlayerMissionsPage> createState()=>_PlayerMissionsPageState(); }
class _PlayerMissionsPageState extends State<PlayerMissionsPage> with _FeaturePageHelpers<PlayerMissionsPage> {
  bool loading=true; String? error; List<Map<String,dynamic>> rows=[];
  DateTime _dayStart(DateTime now)=>DateTime(now.year,now.month,now.day);
  DateTime _weekStart(DateTime now) { final d=_dayStart(now); return d.subtract(Duration(days:d.weekday-1)); }
  String _date(DateTime d)=>'${d.year.toString().padLeft(4,'0')}-${d.month.toString().padLeft(2,'0')}-${d.day.toString().padLeft(2,'0')}';
  Future<int> _confirmedCount(DateTime start, DateTime end) async {
    final id=_userId!;
    final data=await Store.instance.supabase.from('matches')
      .select('id,home_player_id,away_player_id,scheduled_date,status')
      .ilike('status','confirmed')
      .or('home_player_id.eq.$id,away_player_id.eq.$id')
      .gte('scheduled_date',_date(start)).lt('scheduled_date',_date(end)).limit(1000)
      .timeout(const Duration(seconds: 12));
    return (data as List).length;
  }
  Future<void> _load() async {
    if(mounted)setState(()=>loading=true);
    try {
      if(_userId==null) throw Exception('Please sign in again.');
      final now=DateTime.now(); final day=_dayStart(now); final week=_weekStart(now);
      // Challenges are derived from confirmed fixtures at read time. No mission
      // rows are inserted, so an RLS policy or optional mission table cannot hang the page.
      final daily=await _confirmedCount(day,day.add(const Duration(days:1)));
      final weekly=await _confirmedCount(week,week.add(const Duration(days:7)));
      rows=[
        {'id':'daily-${_date(day)}','mission_title':'Daily: Complete 1 confirmed match','description':'Play and confirm one eligible match today.','cadence':'daily','progress_count':daily.clamp(0,1),'target_count':1,'status':daily>=1?'completed':'active','reward_label':'Not configured'},
        {'id':'weekly-${_date(week)}','mission_title':'Weekly: Complete 5 confirmed matches','description':'Complete five eligible confirmed matches this week. Pending or disputed results do not count.','cadence':'weekly','progress_count':weekly.clamp(0,5),'target_count':5,'status':weekly>=5?'completed':'active','reward_label':'Not configured'},
      ];
      error=null;
    } catch(e) { error=e.toString(); }
    if(mounted)setState(()=>loading=false);
  }
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('DAILY & WEEKLY CHALLENGES'),actions:[IconButton(onPressed:_load,icon:const Icon(Icons.refresh))]),body:loading?const Center(child:CircularProgressIndicator()):error!=null?Center(child:Padding(padding:const EdgeInsets.all(18),child:Text('Could not load challenges.\n$error',textAlign:TextAlign.center))):ListView(padding:const EdgeInsets.all(14),children:[Container(margin:const EdgeInsets.only(bottom:12),padding:const EdgeInsets.all(12),decoration:_neonBox(_cyan,radius:14),child:const Text('Challenges are generated automatically. Progress counts confirmed matches only. Super Beans rewards are not implemented.',style:TextStyle(color:_muted,fontSize:12,height:1.4))),...rows.map((m){final progress=(m['progress_count'] as num?)?.toInt()??0;final target=(m['target_count'] as num?)?.toInt()??1;final cadence=(m['cadence']??'daily').toString();return _featureCard(cadence=='daily'?_blue:_purple,cadence=='daily'?Icons.today:Icons.date_range,(m['mission_title']??'Challenge').toString(),'${m['description']}\n${cadence.toUpperCase()} • Progress: $progress/$target\nReward: Not configured', (m['status']??'active').toString());})]));
}

class PlayerFriendsPage extends StatefulWidget { const PlayerFriendsPage({super.key}); @override State<PlayerFriendsPage> createState()=>_PlayerFriendsPageState(); }
class _PlayerFriendsPageState extends State<PlayerFriendsPage> with _FeaturePageHelpers<PlayerFriendsPage> {
  bool loading=true; String? error; List<Map<String,dynamic>> rows=[]; List<Map<String,dynamic>> profiles=[]; final search=TextEditingController();
  @override void initState(){super.initState();_load();}
  @override void dispose(){search.dispose();super.dispose();}
  Future<void> _load() async {if(mounted)setState(()=>loading=true);try{final q=await Store.instance.supabase.from('player_friends').select().order('created_at',ascending:false).limit(300);rows=(q as List).map((e)=>Map<String,dynamic>.from(e as Map)).toList();profiles=await _loadProfiles();error=null;}catch(e){error=e.toString();}if(mounted)setState(()=>loading=false);}
  Future<void> _send(Map<String,dynamic> p) async {try{final existing=rows.where((r)=>(r['sender_id']==_userId&&r['receiver_id']==p['id'])||(r['receiver_id']==_userId&&r['sender_id']==p['id'])).firstOrNull;if(existing!=null){_toast('A friend request or friendship already exists with this player.');return;}await Store.instance.supabase.from('player_friends').insert({'sender_id':_userId,'receiver_id':p['id'],'status':'pending'});_toast('Friend request sent to ${_playerName(p)}.');await _load();}catch(e){_toast('Could not send friend request: $e');}}
  Future<void> _status(Map<String,dynamic> r,String status) async {
    final uid = _userId;
    if (uid == null) { _toast('Please sign in again.'); return; }
    if (r['receiver_id']?.toString() != uid || (r['status'] ?? 'pending').toString().toLowerCase() != 'pending') {
      _toast('Only the recipient can respond to a pending friend request.');
      return;
    }
    try {
      final updated = await Store.instance.supabase.from('player_friends')
          .update({'status': status, 'updated_at': DateTime.now().toUtc().toIso8601String()})
          .eq('id', r['id']).eq('receiver_id', uid).ilike('status', 'pending').select('id');
      if ((updated as List).isEmpty) {
        _toast('Request was not updated. Check the database update permissions, then refresh.');
        await _load();
        return;
      }
      _toast(status == 'accepted' ? 'Friend request accepted.' : 'Friend request declined.');
      await _load();
    } catch (e) { _toast('Could not update friend request: $e'); }
  }
  @override Widget build(BuildContext context){final accepted=rows.where((r)=>(r['status']??'').toString().toLowerCase()=='accepted'&&(r['sender_id']==_userId||r['receiver_id']==_userId)).toList();final filtered=profiles.where((p)=>p['id']!=_userId&&_playerName(p).toLowerCase().contains(search.text.trim().toLowerCase())).take(80).toList();return Scaffold(appBar:AppBar(title:const Text('FRIENDS SYSTEM'),actions:[IconButton(onPressed:_load,icon:const Icon(Icons.refresh))]),body:loading?const Center(child:CircularProgressIndicator()):error!=null?Center(child:Text('Could not load friends.\n$error',textAlign:TextAlign.center)):ListView(padding:const EdgeInsets.all(14),children:[TextField(controller:search,onChanged:(_)=>setState((){}),decoration:const InputDecoration(prefixIcon:Icon(Icons.search),labelText:'Find a player by gamer tag or name',border:OutlineInputBorder())),const SizedBox(height:16),const Text('PLAYER DIRECTORY',style:TextStyle(fontWeight:FontWeight.w900,color:_cyan)),const SizedBox(height:8),...filtered.map((p)=>Card(child:ListTile(leading:const CircleAvatar(child:Icon(Icons.person)),title:Text(_playerName(p)),trailing:OutlinedButton(onPressed:()=>_send(p),child:const Text('ADD FRIEND'))))),const SizedBox(height:16),const Text('MY FRIENDS',style:TextStyle(fontWeight:FontWeight.w900,color:_cyan)),const SizedBox(height:8),if(accepted.isEmpty)const Text('Your accepted friends will appear here.',style:TextStyle(color:_muted)) else ...accepted.map((r){final otherId=r['sender_id']==_userId?r['receiver_id']:r['sender_id'];final person=profiles.where((p)=>p['id']==otherId).firstOrNull;return _featureCard(_cyan,Icons.person,_playerName(person??{'gamer_tag':'CHIBBYBALL player'}),'Accepted friend', 'accepted');}),const SizedBox(height:16),const Text('FRIEND REQUESTS',style:TextStyle(fontWeight:FontWeight.w900,color:_cyan)),const SizedBox(height:8),if(rows.where((r)=>(r['status']??'pending').toString().toLowerCase()!='accepted').isEmpty)const Text('No pending requests.',style:TextStyle(color:_muted)) else ...rows.where((r)=>(r['status']??'pending').toString().toLowerCase()!='accepted').map((r){final incoming=r['receiver_id']==_userId;final person=profiles.where((p)=>p['id']==(incoming?r['sender_id']:r['receiver_id'])).firstOrNull;final status=(r['status']??'pending').toString();final actions=<Widget>[];if(incoming&&status=='pending'){actions.add(TextButton(onPressed:()=>_status(r,'declined'),child:const Text('DECLINE')));actions.add(FilledButton(onPressed:()=>_status(r,'accepted'),child:const Text('ACCEPT')));}else if(!incoming&&status=='pending'){actions.add(const Chip(label:Text('SENT')));}return _featureCard(const Color(0xFF20E070),Icons.people,_playerName(person??{'gamer_tag':'CHIBBYBALL player'}),incoming?'Friend request received':'Friend request sent',status,actions:actions);})]));}
}

class _FeatureEmpty extends StatelessWidget { final IconData icon; final String title,message; const _FeatureEmpty({required this.icon,required this.title,required this.message}); @override Widget build(BuildContext context)=>Center(child:Padding(padding:const EdgeInsets.all(28),child:Column(mainAxisSize:MainAxisSize.min,children:[Icon(icon,color:_cyan,size:54),const SizedBox(height:14),Text(title,style:const TextStyle(fontSize:20,fontWeight:FontWeight.w900),textAlign:TextAlign.center),const SizedBox(height:8),Text(message,style:const TextStyle(color:_muted,height:1.4),textAlign:TextAlign.center)]))); }
Widget _featureCard(Color color,IconData icon,String title,String description,String status,{List<Widget> actions=const []})=>Container(margin:const EdgeInsets.only(bottom:10),padding:const EdgeInsets.all(13),decoration:_neonBox(color,radius:16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Row(children:[Icon(icon,color:color),const SizedBox(width:10),Expanded(child:Text(title,style:const TextStyle(fontWeight:FontWeight.w900,fontSize:14))),Container(padding:const EdgeInsets.symmetric(horizontal:8,vertical:5),decoration:BoxDecoration(color:color.withOpacity(.12),borderRadius:BorderRadius.circular(20)),child:Text(status.toUpperCase(),style:TextStyle(color:color,fontWeight:FontWeight.w900,fontSize:9)))]),if(description.trim().isNotEmpty)Padding(padding:const EdgeInsets.only(top:8),child:Text(description,style:const TextStyle(color:_muted,fontSize:12,height:1.4))),if(actions.isNotEmpty)Padding(padding:const EdgeInsets.only(top:8),child:Wrap(spacing:8,runSpacing:4,alignment:WrapAlignment.end,children:actions))]));

class SeasonAwardsPage extends StatelessWidget {
 const SeasonAwardsPage({super.key});
 @override Widget build(BuildContext context){
  final store=Store.instance; final players=store.players; final matches=store.matches.where((m)=>m.status=='Confirmed'&&m.homeScore!=null&&m.awayScore!=null).toList();
  final wins=<String,int>{},goals=<String,int>{},clean=<String,int>{},points=<String,int>{};
  for(final m in matches){final h=m.homeId,a=m.awayId,hs=m.homeScore!,as=m.awayScore!;goals[h]=(goals[h]??0)+hs;goals[a]=(goals[a]??0)+as;if(hs>as){wins[h]=(wins[h]??0)+1;points[h]=(points[h]??0)+3;}else if(as>hs){wins[a]=(wins[a]??0)+1;points[a]=(points[a]??0)+3;}else{points[h]=(points[h]??0)+1;points[a]=(points[a]??0)+1;}if(as==0)clean[h]=(clean[h]??0)+1;if(hs==0)clean[a]=(clean[a]??0)+1;}
  Widget award(String title,IconData icon,Color color,Map<String,int> data){final sorted=data.entries.toList()..sort((a,b)=>b.value.compareTo(a.value));final top=sorted.take(3).toList();return Container(margin:const EdgeInsets.only(bottom:12),padding:const EdgeInsets.all(14),decoration:_neonBox(color,radius:16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Row(children:[Icon(icon,color:color),const SizedBox(width:9),Text(title,style:const TextStyle(fontWeight:FontWeight.w900))]),const SizedBox(height:9),if(top.isEmpty)const Text('No confirmed match data yet.',style:TextStyle(color:_muted,fontSize:12)) else ...top.map((e){final p=players.where((x)=>x.id==e.key).firstOrNull;return Padding(padding:const EdgeInsets.symmetric(vertical:4),child:Row(children:[Expanded(child:Text(p?.gamerTag??p?.name??'Player',style:const TextStyle(fontWeight:FontWeight.w700))),Text('${e.value}',style:TextStyle(color:color,fontWeight:FontWeight.w900))]));})]));}
  return Scaffold(appBar:AppBar(title:const Text('SEASON AWARDS')),body:ListView(padding:const EdgeInsets.all(16),children:[const Text('Calculated from confirmed matches in the loaded app records. Awards refresh as results are confirmed.',style:TextStyle(color:_muted,height:1.4)),const SizedBox(height:14),award('SEASON POINTS LEADER',Icons.emoji_events,_yellow,points),award('TOP GOAL SCORER',Icons.sports_soccer,_cyan,goals),award('MOST MATCH WINS',Icons.military_tech,_purple,wins),award('CLEAN-SHEET SPECIALIST',Icons.shield,_blue,clean)]));
 }
}

class HeadToHeadPage extends StatefulWidget { const HeadToHeadPage({super.key}); @override State<HeadToHeadPage> createState()=>_HeadToHeadPageState(); }
class _HeadToHeadPageState extends State<HeadToHeadPage>{String? opponent; @override Widget build(BuildContext context){final me=Store.instance.current;final others=Store.instance.players.where((p)=>p.id!=me?.id).toList();final selected=others.where((p)=>p.id==opponent).firstOrNull;final ms=Store.instance.matches.where((m)=>m.status=='Confirmed'&&m.homeScore!=null&&m.awayScore!=null&&me!=null&&selected!=null&&((m.homeId==me.id&&m.awayId==selected.id)||(m.awayId==me.id&&m.homeId==selected.id))).toList();int w=0,d=0,l=0,gf=0,ga=0;for(final m in ms){final home=m.homeId==me?.id;final a=home?m.homeScore!:m.awayScore!,b=home?m.awayScore!:m.homeScore!;gf+=a;ga+=b;if(a>b)w++;else if(a==b)d++;else l++;}return Scaffold(appBar:AppBar(title:const Text('HEAD-TO-HEAD')),body:ListView(padding:const EdgeInsets.all(16),children:[const Text('Choose an opponent to compare confirmed results.',style:TextStyle(color:_muted)),const SizedBox(height:12),DropdownButtonFormField<String>(value:opponent,decoration:const InputDecoration(labelText:'Opponent',border:OutlineInputBorder()),items:others.map((p)=>DropdownMenuItem(value:p.id,child:Text(p.gamerTag.isNotEmpty?p.gamerTag:p.name))).toList(),onChanged:(v)=>setState(()=>opponent=v)),const SizedBox(height:16),if(selected!=null)...[Container(padding:const EdgeInsets.all(18),decoration:_neonBox(_cyan,radius:18),child:Column(children:[Text('${me?.gamerTag??'You'}  vs  ${selected.gamerTag}',textAlign:TextAlign.center,style:const TextStyle(fontSize:18,fontWeight:FontWeight.w900)),const SizedBox(height:16),Row(children:[_h2hStat('WINS','$w',_yellow),_h2hStat('DRAWS','$d',_cyan),_h2hStat('LOSSES','$l',const Color(0xFFFF4D7D))]),const SizedBox(height:12),Text('$gf goals for  •  $ga goals against',style:const TextStyle(color:_muted)),Text('${ms.length} confirmed matches',style:const TextStyle(color:_muted,fontSize:11))])),if(ms.isEmpty)const Padding(padding:EdgeInsets.all(14),child:Text('No confirmed head-to-head matches yet.',textAlign:TextAlign.center,style:TextStyle(color:_muted)))]]));}
 Widget _h2hStat(String label,String value,Color color)=>Expanded(child:Column(children:[Text(value,style:TextStyle(color:color,fontSize:25,fontWeight:FontWeight.w900)),Text(label,style:const TextStyle(color:_muted,fontSize:10,fontWeight:FontWeight.w800))]));
}

class PlayerShowcasePage extends StatelessWidget { final String playerId; const PlayerShowcasePage({super.key,required this.playerId}); @override Widget build(BuildContext context){final p=Store.instance.players.where((x)=>x.id==playerId).firstOrNull;return Scaffold(appBar:AppBar(title:const Text('PLAYER SHOWCASE')),body:ListView(padding:const EdgeInsets.all(16),children:[Container(padding:const EdgeInsets.all(20),decoration:BoxDecoration(gradient:const LinearGradient(colors:[Color(0xFF102D50),Color(0xFF11152D)]),borderRadius:BorderRadius.circular(24),border:Border.all(color:_cyan)),child:Column(children:[_playerAvatar(p,radius:45,accent:_yellow),const SizedBox(height:12),Text(p?.gamerTag.isNotEmpty==true?p!.gamerTag:'CHIBBYBALL PLAYER',style:const TextStyle(fontSize:22,fontWeight:FontWeight.w900),textAlign:TextAlign.center),Text(p?.country.isNotEmpty==true?p!.country:'eFootball Competitor',style:const TextStyle(color:_muted)),const SizedBox(height:14),const Text('PLAYER CARD • CHIBBYBALL',style:TextStyle(color:_cyan,fontWeight:FontWeight.w900,letterSpacing:1.1))])),const SizedBox(height:14),PlayerAchievementShowcase(playerId:playerId),const SizedBox(height:14),_neonAction(context,Icons.bar_chart,'CAREER STATS','View confirmed results and match history',_yellow,()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>const PlayerStatsPage()))) ]));}}

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshProfile());
  }

  Future<void> _refreshProfile() async {
    final id = Store.instance.current?.id;
    if (id == null) return;
    final oldPhone = phoneController.text;
    final oldCountry = countryController.text;
    final oldCountryCode = countryCodeController.text;
    final oldWhatsapp = whatsappController.text;
    try {
      await Store.instance.refreshPlayers();
      if (!mounted) return;
      final p = Store.instance.current;
      if (p == null || p.id != id) return;
      // Update controllers only if the user has not changed them while loading.
      if (phoneController.text == oldPhone) phoneController.text = p.phoneNumber;
      if (countryController.text == oldCountry) countryController.text = p.country;
      if (countryCodeController.text == oldCountryCode) countryCodeController.text = p.countryCode;
      if (whatsappController.text == oldWhatsapp) whatsappController.text = p.whatsappNumber;
      setState(() {});
    } catch (e) {
      debugPrint('Profile refresh failed: $e');
    }
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
    return Scaffold(
      appBar: AppBar(title: const Text('PLAYER PROFILE')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 30),
        children: [
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
        Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), decoration: BoxDecoration(color: (online ? const Color(0xFF20E070) : const Color(0xFFB7A77C)).withOpacity(.12), borderRadius: BorderRadius.circular(30), border: Border.all(color: online ? const Color(0xFF20E070) : const Color(0xFFB7A77C))), child: Row(mainAxisSize: MainAxisSize.min, children: [Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: online ? const Color(0xFF20E070) : const Color(0xFFB7A77C))), const SizedBox(width: 7), Text(online ? 'ONLINE' : 'OFFLINE', style: TextStyle(color: online ? const Color(0xFF20E070) : _muted, fontSize: 11, fontWeight: FontWeight.w900))])),
      ])),
      const SizedBox(height: 16),
      if (p != null) PlayerAchievementShowcase(playerId: p.id),
      const SizedBox(height: 16),
      _neonSectionTitle('ACCOUNT', accent: _yellow), const SizedBox(height: 10),
      _info(Icons.badge_outlined, 'Gamer Tag', p?.gamerTag ?? '', _cyan),
      _info(Icons.person_outline, 'Full Name', p?.name ?? '', _cyan),
      _info(Icons.shield_outlined, 'Account Role', p?.admin == true ? 'Administrator' : 'Player', _purple),
      if (p != null && !p.profileComplete) ...[
        Container(padding: const EdgeInsets.all(14), decoration: _neonBox(const Color(0xFFFF4D7D), radius: 16), child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(Icons.warning_amber_rounded, color: Color(0xFFFF4D7D)), SizedBox(width: 10), Expanded(child: Text('PROFILE INCOMPLETE\nComplete your phone, country, country code and WhatsApp details before you can join a league.', style: TextStyle(fontWeight: FontWeight.w800)))])),
        const SizedBox(height: 10),
      ],
      if (p != null && Store.instance.hasCreatorBadge(p.id)) ...[
        Container(padding: const EdgeInsets.all(14), decoration: _neonBox(_yellow, radius: 16), child: Row(children: [const Icon(Icons.verified, color: _yellow, size: 30), const SizedBox(width: 10), Expanded(child: Text('CHIBBYBALL CREATOR BADGE\nYou are eligible to create/request leagues.', style: const TextStyle(fontWeight: FontWeight.w900)))])),
        const SizedBox(height: 10),
      ],
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
      Container(decoration: _neonBox(_purple, radius: 18), child: ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 4), leading: Stack(children: [const Icon(Icons.chat_bubble_outline, color: _purple, size: 29), Positioned(right: -2, bottom: -2, child: Container(width: 9, height: 9, decoration: BoxDecoration(shape: BoxShape.circle, color: online ? const Color(0xFF20E070) : const Color(0xFFB7A77C), border: Border.all(color: _panel, width: 2))))]), title: const Text('PLAYERS & MESSAGES', style: TextStyle(fontWeight: FontWeight.w900)), subtitle: Text(online ? 'You are online • chat with other players' : 'Chat with other players and see their status'), trailing: const Icon(Icons.chevron_right, color: _purple), onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MessagesPage())))),
      const SizedBox(height: 10),
      _neonAction(context, Icons.bar_chart, 'MY STATS & HISTORY', 'Confirmed results and league statistics', _yellow, () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PlayerStatsPage()))),
      const SizedBox(height: 9),
      _neonAction(context, Icons.workspace_premium, 'PLAYER PROFILE SHOWCASE', 'Show your player card, achievements and career record', _cyan, () { final id = Store.instance.current?.id; if (id != null) Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerShowcasePage(playerId: id))); }),
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
        ],
      ),
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
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a league name first.')),
      );
      return;
    }
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
            // Keep the league name field and CREATE action in a vertical layout.
            // This is more reliable on narrow mobile screens than squeezing both
            // controls into one Row, and explicit styles keep the input readable.
            TextField(
              key: const ValueKey('league-name-input'),
              controller: nameController,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) { if (!loading) _createLeague(); },
              style: const TextStyle(color: Color(0xFFE8F1FF), fontSize: 16),
              decoration: const InputDecoration(
                labelText: 'League name',
                hintText: 'e.g. CHIBBYBALL Season 1',
                labelStyle: TextStyle(color: Color(0xFFFFE9B0)),
                hintStyle: TextStyle(color: Color(0xFF8193AA)),
                prefixIcon: Icon(Icons.emoji_events_outlined),
                filled: true,
                fillColor: Color(0xE6120D05),
                border: OutlineInputBorder(),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF14728B)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFFFFC928), width: 2),
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: FilledButton.icon(
                key: const ValueKey('create-league-button'),
                onPressed: loading ? null : _createLeague,
                icon: const Icon(Icons.add),
                label: Text(loading ? 'PLEASE WAIT...' : 'CREATE LEAGUE'),
              ),
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
                      const SizedBox(height: 8),
                      Text('Fixture format: ${selected.fixtureModeLabel}', style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 12),
                      if (!selected.isHomeAway)
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: loading ? null : () async {
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (dialogContext) => AlertDialog(
                                  title: const Text('Convert to Home & Away?'),
                                  content: const Text(
                                    'This will keep all existing fixtures and results, then add missing return fixtures with home and away reversed. Return fixtures will need their Match Day dates scheduled. Continue?',
                                  ),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('CANCEL')),
                                    FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('ADD RETURN FIXTURES')),
                                  ],
                                ),
                              );
                              if (confirmed != true || !mounted) return;
                              setState(() => loading = true);
                              final result = await store.convertLeagueToHomeAway(selected.id);
                              if (!mounted) return;
                              await _refresh();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text(result ?? 'League converted to Home & Away.')),
                              );
                            },
                            icon: const Icon(Icons.swap_horiz),
                            label: const Text('CONVERT TO HOME & AWAY'),
                          ),
                        )
                      else
                        const Text('Home & Away is already enabled.', style: TextStyle(color: Color(0xFFFFC928), fontWeight: FontWeight.w800)),
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
  bool hasCreatorBadge = false;
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
        hasCreatorBadge = permission['has_creator_badge'] == true || eligible;
        pendingStatus = permission['pending_status']?.toString();
      }
    } catch (_) {}
    if (mounted) setState(() => loading = false);
  }

  Future<void> _submit() async {
    if (!eligible) return;
    setState(() => submitting = true);
    final error = await Store.instance.submitLeagueRequest(
      leagueName: nameController.text,
      batchName: 'CREATOR BADGE',
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
          Text(hasCreatorBadge ? 'Creator Badge verified.' : 'You do not currently have a Creator Badge.', style: const TextStyle(color: _muted)),
          const SizedBox(height: 5),
          Text(eligible ? 'You are eligible to request a league.' : 'A Creator Badge is required before you can create leagues.', style: TextStyle(color: eligible ? _cyan : const Color(0xFFFF4D7D), fontWeight: FontWeight.w800)),
        ])),
        const SizedBox(height: 14),
        if (pendingStatus != null) Card(child: ListTile(leading: const Icon(Icons.hourglass_top, color: _yellow), title: const Text('REQUEST STATUS'), subtitle: Text(pendingStatus!.toUpperCase()))),
        if (!eligible) const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('Finish in the Top 3 of a completed qualifying league, or ask an administrator to award you a Creator Badge.')))
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      requests = await Store.instance.fetchLeagueRequests();
    } catch (_) {}
    if (mounted) setState(() => loading = false);
  }

  Future<void> _review(Map<String, dynamic> request, String decision) async {
    final noteController = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(decision == 'approved' ? 'Approve League' : 'Reject League'),
        content: TextField(
          controller: noteController,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'Admin note (optional)'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, noteController.text),
            child: Text(decision == 'approved' ? 'APPROVE' : 'REJECT'),
          ),
        ],
      ),
    );

    noteController.dispose();
    if (note == null) return;

    setState(() => loading = true);
    final error = await Store.instance.reviewLeagueRequest(
      requestId: request['id'].toString(),
      decision: decision,
      note: note,
    );

    if (mounted) {
      setState(() => loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error ?? 'Request $decision.')),
      );
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('League Requests')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: requests.isEmpty
                  ? const Center(child: Text('No league requests.'))
                  : ListView.builder(
                      padding: const EdgeInsets.all(14),
                      itemCount: requests.length,
                      itemBuilder: (_, i) {
                        final r = requests[i];
                        final status = r['status']?.toString() ?? 'pending';
                        final requester = Store.instance.playerName(
                          r['requested_by']?.toString() ?? '',
                        );

                        return Card(
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  r['league_name']?.toString() ?? '',
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text('Requested by: $requester'),
                                Text('Batch: ${r['batch_name']}'),
                                if ((r['description']?.toString() ?? '').isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 5),
                                    child: Text(
                                      r['description'].toString(),
                                      style: const TextStyle(color: _muted),
                                    ),
                                  ),
                                const SizedBox(height: 8),
                                Text(
                                  'Status: ${status.toUpperCase()}',
                                  style: const TextStyle(fontWeight: FontWeight.w800),
                                ),
                                if (status == 'pending')
                                  Row(
                                    children: [
                                      Expanded(
                                        child: OutlinedButton.icon(
                                          onPressed: () => _review(r, 'rejected'),
                                          icon: const Icon(Icons.close),
                                          label: const Text('REJECT'),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: FilledButton.icon(
                                          onPressed: () => _review(r, 'approved'),
                                          icon: const Icon(Icons.check),
                                          label: const Text('APPROVE'),
                                        ),
                                      ),
                                    ],
                                  ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
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
  @override Widget build(BuildContext context){ final players=Store.instance.players.where((p)=>!p.admin).toList(); return Scaffold(appBar:AppBar(title:const Text('Creator Batch Access')),body:ListView(padding:const EdgeInsets.all(16),children:[DropdownButtonFormField<String>(value:selectedPlayerId,decoration:const InputDecoration(labelText:'PLAYER'),items:players.map((p)=>DropdownMenuItem(value:p.id,child:Text(p.gamerTag))).toList(),onChanged:loading?(v){}:(v)=>setState(()=>selectedPlayerId=v)),const SizedBox(height:12),TextField(controller:batchController,decoration:const InputDecoration(labelText:'Batch name',hintText:'e.g. Batch 1')),SwitchListTile(title:const Text('Allow this batch/player to request leagues'),value:canCreate,onChanged:loading?null:(v)=>setState(()=>canCreate=v)),const SizedBox(height:12),FilledButton.icon(onPressed:loading?null:_save,icon:const Icon(Icons.save),label:const Text('SAVE ACCESS')),const SizedBox(height:20),const Text('Legacy batch settings are retained for compatibility. A Creator Badge is required to create a league.',style:TextStyle(color:_muted))])); }
}

// ============================================================
// ADMIN BADGE MANAGEMENT
// ============================================================

class BadgeAdminPage extends StatefulWidget {
  const BadgeAdminPage({super.key});
  @override State<BadgeAdminPage> createState() => _BadgeAdminPageState();
}

class _BadgeAdminPageState extends State<BadgeAdminPage> {
  String? selectedPlayerId;
  bool loading = false;

  Future<void> _award() async {
    if (selectedPlayerId == null) return;
    setState(() => loading = true);
    final error = await Store.instance.awardCreatorBadge(playerId: selectedPlayerId!);
    if (!mounted) return;
    setState(() => loading = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error ?? 'Creator Badge awarded.')));
  }

  @override
  Widget build(BuildContext context) {
    final players = Store.instance.players.where((p) => !p.admin).toList();
    return Scaffold(appBar: AppBar(title: const Text('Badge Management')), body: ListView(padding: const EdgeInsets.all(16), children: [
      const Text('MANUALLY AWARD CREATOR BADGE', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
      const SizedBox(height: 8),
      const Text('Use this only when an administrator wants to grant creator privileges directly.', style: TextStyle(color: _muted)),
      const SizedBox(height: 16),
      DropdownButtonFormField<String>(value: selectedPlayerId, decoration: const InputDecoration(labelText: 'PLAYER'), items: players.map((p) => DropdownMenuItem(value: p.id, child: Text(p.gamerTag))).toList(), onChanged: loading ? null : (v) => setState(() => selectedPlayerId = v)),
      const SizedBox(height: 16),
      FilledButton.icon(onPressed: loading ? null : _award, icon: const Icon(Icons.verified), label: const Text('AWARD CREATOR BADGE')),
    ]));
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

  Future<void> _replacePlayer(Player outgoing) async {
    final leagueId = selectedLeagueId;
    if (leagueId == null || !memberIds.contains(outgoing.id)) return;
    final candidates = store.players.where((p) =>
      !p.admin && p.id != outgoing.id && !memberIds.contains(p.id) && p.profileComplete
    ).toList();
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No eligible replacement players found. A replacement must not already be in this league and must have a complete profile.')));
      return;
    }
    String? replacementId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (dialogContext, setDialogState) => AlertDialog(
        title: const Text('REPLACE PLAYER IN THIS LEAGUE'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Outgoing player: ${outgoing.gamerTag}'),
          const SizedBox(height: 10),
          const Text('The replacement inherits the league-table record only. Personal histories and global statistics remain attached to the original players.'),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: replacementId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Replacement player'),
            items: candidates.map((p) => DropdownMenuItem(value: p.id, child: Text('${p.gamerTag} • ${p.whatsappNumber}'))).toList(),
            onChanged: (value) => setDialogState(() => replacementId = value),
          ),
          const SizedBox(height: 8),
          const Text('Upcoming scheduled fixtures will be reassigned. Historical match records remain unchanged.', style: TextStyle(fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('CANCEL')),
          FilledButton(onPressed: replacementId == null ? null : () => Navigator.pop(dialogContext, true), child: const Text('REVIEW & REPLACE')),
        ],
      )),
    );
    if (confirmed != true || replacementId == null) return;
    final replacement = store.findPlayer(replacementId!);
    if (replacement == null) return;
    final finalConfirm = await showDialog<bool>(context: context, builder: (dialogContext) => AlertDialog(
      title: const Text('CONFIRM PLAYER REPLACEMENT'),
      content: Text('${outgoing.gamerTag} will leave this league and ${replacement.gamerTag} will take over the league position and eligible upcoming fixtures. Their personal/global statistics will not be transferred. Historical matches remain linked to the players who played them. This action cannot be automatically undone.'),
      actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('GO BACK')), FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('CONFIRM REPLACEMENT'))],
    ));
    if (finalConfirm != true) return;
    setState(() => loading = true);
    final error = await store.replaceLeaguePlayer(leagueId: leagueId, outgoingPlayerId: outgoing.id, replacementPlayerId: replacement.id);
    if (mounted) {
      await _load();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error ?? '${outgoing.gamerTag} replaced by ${replacement.gamerTag} in this league.')));
    }
  }

  Future<void> _disregister(Player player) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(title: const Text('Disregister player?'), content: Text('${player.gamerTag} will be removed from every league. The account itself will not be deleted.'), actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('CANCEL')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('DISREGISTER'))]));
    if (ok != true) return;
    setState(() => loading = true);
    final error = await store.disregisterPlayerFromAllLeagues(player.id);
    if (error == null) { memberIds.remove(player.id); await store.refreshLeagues(); await store.loadMatchesFromSupabase(); }
    if (mounted) { setState(() => loading = false); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error ?? '${player.gamerTag} disregistered from all leagues.'))); }
  }

  Future<void> _deletePlayer(Player player) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('DELETE PLAYER ACCOUNT?'),
        content: Text(
          'This will permanently delete ${player.gamerTag} and remove the account from CHIBBYBALL. This cannot be undone.\n\nUse DISREGISTER instead if you only want to remove the player from leagues.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFFF4D7D)),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('DELETE ACCOUNT'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => loading = true);
    final error = await store.adminDeletePlayer(player.id);
    if (error == null) {
      memberIds.remove(player.id);
      await store.refreshPlayers();
      await store.refreshLeagues();
      await store.loadMatchesFromSupabase();
    }
    if (mounted) {
      setState(() => loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error ?? '${player.gamerTag} account deleted permanently.')),
      );
    }
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
            Stack(children: [_playerAvatar(player, radius: 23, accent: isMember ? _cyan : _blue), Positioned(right: 0, bottom: 0, child: Container(width: 11, height: 11, decoration: BoxDecoration(shape: BoxShape.circle, color: online ? const Color(0xFF20E070) : const Color(0xFFB7A77C), border: Border.all(color: _panel, width: 2))))]),
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
                if (value == 'replace') _replacePlayer(player);
                if (value == 'delete') _deletePlayer(player);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'suspend', child: Text('Suspend player')),
                PopupMenuItem(value: 'unsuspend', child: Text('Unsuspend player')),
                PopupMenuItem(value: 'deduct', child: Text('Deduct points')),
                PopupMenuItem(value: 'fine', child: Text('Fine player')),
                PopupMenuItem(value: 'replace', child: Text('Replace in selected league')),
                PopupMenuDivider(),
                PopupMenuItem(value: 'disregister', child: Text('Disregister from all leagues')),
                PopupMenuItem(value: 'delete', child: Text('DELETE PLAYER ACCOUNT')),
              ],
            ),
          ])));
        }),
      ])),
    );
  }
}

// ============================================================
// JOIN A LEAGUE
// ============================================================

class JoinLeaguePage extends StatefulWidget {
  const JoinLeaguePage({super.key});
  @override State<JoinLeaguePage> createState() => _JoinLeaguePageState();
}

class _JoinLeaguePageState extends State<JoinLeaguePage> {
  bool loading = true;
  final Set<String> memberIds = {};
  final Map<String, String> requestStatuses = {};

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    if (mounted) setState(() => loading = true);
    try {
      final me = Store.instance.current;
      memberIds.clear();
      if (me != null) {
        for (final league in Store.instance.leagues) {
          try {
            final ids = await Store.instance.leagueMemberIds(league.id);
            if (ids.contains(me.id)) memberIds.add(league.id);
          } catch (_) {}
        }
      }
      requestStatuses.clear();
      final requests = await Store.instance.fetchMyJoinRequestStatuses();
      for (final r in requests) {
        final leagueId = r['league_id']?.toString();
        final status = r['status']?.toString();
        if (leagueId != null && status != null) requestStatuses[leagueId] = status;
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _request(LeagueInfo league) async {
    final me = Store.instance.current;
    if (me == null) return;
    if (!me.profileComplete) {
      final go = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
        title: const Text('PROFILE REQUIRED'),
        content: const Text('Complete your phone, country, country code and WhatsApp details before joining a league.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('CANCEL')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('COMPLETE PROFILE')),
        ],
      ));
      if (go == true && mounted) {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfilePage()));
        await _load();
      }
      return;
    }
    setState(() => loading = true);
    final error = await Store.instance.requestToJoinLeague(league.id);
    if (!mounted) return;
    await _load();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error ?? 'Join request sent. Wait for approval.')));
  }

  String _statusFor(LeagueInfo league) {
    if (memberIds.contains(league.id)) return 'MEMBER';
    final status = requestStatuses[league.id];
    if (status == 'pending') return 'REQUESTED';
    if (status == 'approved') return 'APPROVED';
    if (status == 'rejected') return 'REJECTED';
    return 'AVAILABLE';
  }

  @override
  Widget build(BuildContext context) {
    final leagues = Store.instance.leagues.where((l) => l.status != 'completed').toList();
    return Scaffold(
      appBar: AppBar(title: const Text('JOIN A LEAGUE')),
      body: loading ? const Center(child: CircularProgressIndicator()) : RefreshIndicator(
        onRefresh: _load,
        child: leagues.isEmpty
            ? ListView(children: const [SizedBox(height: 180), Center(child: Text('No leagues are available right now.'))])
            : ListView.builder(
                padding: const EdgeInsets.all(14),
                itemCount: leagues.length,
                itemBuilder: (context, index) {
                  final league = leagues[index];
                  final status = _statusFor(league);
                  final canRequest = status == 'AVAILABLE' || status == 'REJECTED';
                  return Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: _neonBox(status == 'MEMBER' ? const Color(0xFF20E070) : _cyan, radius: 18),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(child: Text(league.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900))),
                          Text(status, style: TextStyle(color: status == 'MEMBER' ? const Color(0xFF20E070) : _yellow, fontSize: 10, fontWeight: FontWeight.w900)),
                        ]),
                        const SizedBox(height: 6),
                        Text(league.status.toUpperCase(), style: const TextStyle(color: _muted, fontSize: 11)),
                        const SizedBox(height: 4),
                        Text(league.feeLabel, style: const TextStyle(color: _cyan, fontWeight: FontWeight.w800)),
                        const SizedBox(height: 12),
                        if (canRequest) SizedBox(width: double.infinity, child: FilledButton.icon(
                          onPressed: () => _request(league), icon: const Icon(Icons.person_add),
                          label: Text(status == 'REJECTED' ? 'REQUEST AGAIN' : 'REQUEST TO JOIN'),
                        )) else if (status == 'REQUESTED')
                          const Text('Waiting for approval.', style: TextStyle(color: _yellow, fontWeight: FontWeight.w700))
                        else if (status == 'MEMBER')
                          const Text('You are already in this league.', style: TextStyle(color: Color(0xFF20E070), fontWeight: FontWeight.w700))
                        else if (status == 'APPROVED')
                          const Text('Your request was approved.', style: TextStyle(color: Color(0xFF20E070), fontWeight: FontWeight.w700)),
                      ]),
                    ),
                  );
                },
              ),
      ),
    );
  }
}

// CREATOR HUB
// ============================================================

class CreatorHubPage extends StatefulWidget {
  const CreatorHubPage({super.key});
  @override State<CreatorHubPage> createState() => _CreatorHubPageState();
}

class _CreatorHubPageState extends State<CreatorHubPage> {
  bool loading = true;
  List<Map<String, dynamic>> creators = [];

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    creators = await Store.instance.fetchCreators();
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('CHIBBYBALL CREATORS')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: creators.isEmpty
                  ? const Center(child: Text('No league creators are available yet.'))
                  : ListView.builder(
                      padding: const EdgeInsets.all(14),
                      itemCount: creators.length,
                      itemBuilder: (_, i) {
                        final c = creators[i];
                        return Card(
                          child: ListTile(
                            leading: const CircleAvatar(child: Icon(Icons.verified)),
                            title: Text(c['gamer_tag']?.toString() ?? 'Creator', style: const TextStyle(fontWeight: FontWeight.w900)),
                            subtitle: Text('${c['badge_count'] ?? 1} creator badge(s) • ${c['league_count'] ?? 0} league(s) created'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CreatorPage(creator: c))),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}

class CreatorPage extends StatefulWidget {
  final Map<String, dynamic> creator;
  const CreatorPage({super.key, required this.creator});
  @override State<CreatorPage> createState() => _CreatorPageState();
}

class _CreatorPageState extends State<CreatorPage> {
  bool loading = true;
  List<Map<String, dynamic>> leagues = [];

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    leagues = await Store.instance.fetchCreatorLeagues(widget.creator['player_id'].toString());
    if (mounted) setState(() => loading = false);
  }

  Future<void> _join(String leagueId) async {
    final me = Store.instance.current;
    if (me == null) return;
    if (!me.profileComplete) {
      final go = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
        title: const Text('PROFILE REQUIRED'),
        content: const Text('Complete your phone, country, country code and WhatsApp details before joining a league.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('CANCEL')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('COMPLETE PROFILE')),
        ],
      ));
      if (go == true && mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfilePage()));
      return;
    }
    final error = await Store.instance.requestToJoinLeague(leagueId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error ?? 'Join request sent to the league creator.')));
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.creator;
    return Scaffold(
      appBar: AppBar(title: Text('${c['gamer_tag'] ?? 'Creator'}')),
      body: loading ? const Center(child: CircularProgressIndicator()) : ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Container(padding: const EdgeInsets.all(18), decoration: _neonBox(_yellow, radius: 20), child: Column(children: [
            const Icon(Icons.verified, color: _yellow, size: 52),
            const SizedBox(height: 8),
            Text(c['gamer_tag']?.toString() ?? 'Creator', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
            Text('${c['league_count'] ?? 0} leagues created', style: const TextStyle(color: _muted)),
          ])),
          const SizedBox(height: 16),
          const Text('ACTIVE CREATOR LEAGUES', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          if (leagues.isEmpty) const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('This creator has no active leagues available right now.'))),
          ...leagues.map((l) => Card(child: ListTile(
            title: Text(l['league_name']?.toString() ?? '', style: const TextStyle(fontWeight: FontWeight.w900)),
            subtitle: Text('${l['status']?.toString().toUpperCase() ?? 'OPEN'} • ${l['member_count'] ?? 0} players'),
            trailing: FilledButton(onPressed: l['status']?.toString() == 'completed' ? null : () => _join(l['league_id'].toString()), child: const Text('JOIN')),
          ))),
          if (Store.instance.current?.id == widget.creator['player_id']?.toString()) ...[
            const SizedBox(height: 16),
            const Text('JOIN REQUESTS', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            CreatorJoinRequestsWidget(creatorId: widget.creator['player_id'].toString()),
          ],
        ],
      ),
    );
  }
}

class CreatorJoinRequestsWidget extends StatefulWidget {
  final String creatorId;
  const CreatorJoinRequestsWidget({super.key, required this.creatorId});
  @override State<CreatorJoinRequestsWidget> createState() => _CreatorJoinRequestsWidgetState();
}

class _CreatorJoinRequestsWidgetState extends State<CreatorJoinRequestsWidget> {
  bool loading = true;
  List<Map<String, dynamic>> requests = [];

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    requests = await Store.instance.fetchMyLeagueJoinRequests();
    if (mounted) setState(() => loading = false);
  }

  Future<void> _review(String id, String decision) async {
    final error = await Store.instance.reviewLeagueJoinRequest(requestId: id, decision: decision);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error ?? 'Join request $decision.')));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator());
    final pending = requests.where((r) => r['status']?.toString() == 'pending').toList();
    if (pending.isEmpty) return const Card(child: Padding(padding: EdgeInsets.all(14), child: Text('No pending join requests.')));
    return Column(children: pending.map((r) => Card(child: ListTile(
      title: Text(r['gamer_tag']?.toString() ?? '', style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Text(r['league_name']?.toString() ?? ''),
      trailing: Wrap(children: [
        IconButton(onPressed: () => _review(r['id'].toString(), 'rejected'), icon: const Icon(Icons.close, color: Color(0xFFFF4D7D))),
        IconButton(onPressed: () => _review(r['id'].toString(), 'approved'), icon: const Icon(Icons.check, color: _cyan)),
      ]),
    ))).toList());
  }
}

// ============================================================
// CHAMPIONS LEAGUE
// ============================================================

class ChampionsLeaguePage extends StatefulWidget {
  const ChampionsLeaguePage({super.key});
  @override State<ChampionsLeaguePage> createState() => _ChampionsLeaguePageState();
}

class _ChampionsLeaguePageState extends State<ChampionsLeaguePage> {
  bool loading = true;
  Map<String, dynamic>? data;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    data = await Store.instance.championsStatus();
    if (mounted) setState(() => loading = false);
  }

  Future<void> _createSeason() async {
    final nameController = TextEditingController(text: 'CHIBBYBALL Champions League');
    final name = await showDialog<String>(context: context, builder: (_) => AlertDialog(
      title: const Text('CREATE CHAMPIONS LEAGUE'),
      content: TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Season name')),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')), FilledButton(onPressed: () => Navigator.pop(context, nameController.text.trim()), child: const Text('CREATE'))],
    ));
    nameController.dispose();
    if (name == null || name.isEmpty) return;
    final error = await Store.instance.createChampionsSeason(name: name);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error ?? 'Champions League season created.')));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final qualified = (data?['qualified_players'] as List?)?.map((e) => Map<String, dynamic>.from(e as Map)).toList() ?? [];
    final groups = (data?['groups'] as List?)?.map((e) => Map<String, dynamic>.from(e as Map)).toList() ?? [];
    return Scaffold(
      appBar: AppBar(title: const Text('CHIBBYBALL CHAMPIONS LEAGUE'), actions: [if (Store.instance.current?.admin == true) IconButton(onPressed: _createSeason, icon: const Icon(Icons.add))]),
      body: loading ? const Center(child: CircularProgressIndicator()) : ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Container(padding: const EdgeInsets.all(18), decoration: _neonBox(_yellow, radius: 20), child: const Column(children: [Icon(Icons.emoji_events, color: _yellow, size: 58), SizedBox(height: 8), Text('TOP CREATOR LEAGUE FINISHERS', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)), SizedBox(height: 5), Text('Top 3 from each completed qualifying league can enter the overall championship.', textAlign: TextAlign.center, style: TextStyle(color: _muted))])),
          const SizedBox(height: 16),
          if (data == null || data!['season_id'] == null) const Card(child: Padding(padding: EdgeInsets.all(16), child: Text('No Champions League season is active yet. A season becomes available when enough qualifying leagues have completed.'))),
          if (data != null && data!['season_id'] != null) ...[
            Text(data!['season_name']?.toString() ?? 'Champions League', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            Text('STATUS: ${data!['status']?.toString().toUpperCase() ?? 'OPEN'}', style: const TextStyle(color: _cyan, fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            if (Store.instance.current?.admin == true && groups.isEmpty)
              FilledButton.icon(onPressed: () async { final e = await Store.instance.generateChampionsGroups(data!['season_id'].toString()); if (!mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e ?? 'Groups generated.'))); await _load(); }, icon: const Icon(Icons.account_tree), label: const Text('GENERATE GROUP STAGE')),
            const SizedBox(height: 10),
            const Text('QUALIFIED PLAYERS', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
            ...qualified.map((q) => ListTile(leading: CircleAvatar(child: Text('${q['position'] ?? ''}')), title: Text(q['gamer_tag']?.toString() ?? ''), subtitle: Text(q['source_league_name']?.toString() ?? 'Qualified'),)),
            if (groups.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text('GROUP STAGE', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
              ...groups.map((g) { final gp = (g['players'] as List?)?.map((e) => Map<String, dynamic>.from(e as Map)).toList() ?? []; return Card(child: ExpansionTile(title: Text(g['group_name']?.toString() ?? 'Group', style: const TextStyle(fontWeight: FontWeight.w900)), children: gp.map((p) => ListTile(leading: const Icon(Icons.person), title: Text(p['gamer_tag']?.toString() ?? ''))).toList())); }),
            ],
          ],
        ],
      ),
    );
  }
}

// ============================================================
// ADMIN LEAGUE JOIN REQUESTS
// ============================================================

class LeagueJoinRequestsAdminPage extends StatefulWidget {
  const LeagueJoinRequestsAdminPage({super.key});
  @override State<LeagueJoinRequestsAdminPage> createState() => _LeagueJoinRequestsAdminPageState();
}

class _LeagueJoinRequestsAdminPageState extends State<LeagueJoinRequestsAdminPage> {
  bool loading = true;
  List<LeagueJoinRequest> requests = [];

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    if (mounted) setState(() => loading = true);
    try {
      requests = await Store.instance.fetchLeagueJoinRequests(pendingOnly: true);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load join requests: $e')));
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> _review(LeagueJoinRequest request, String decision) async {
    setState(() => loading = true);
    final error = await Store.instance.adminReviewLeagueJoinRequest(requestId: request.id, decision: decision);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error ?? 'Request $decision.')));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PLAYER JOIN REQUESTS'), actions: [IconButton(onPressed: _load, icon: const Icon(Icons.refresh))]),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: requests.isEmpty
                  ? ListView(children: const [SizedBox(height: 180), Center(child: Text('No pending player join requests.'))])
                  : ListView.builder(
                      padding: const EdgeInsets.all(14),
                      itemCount: requests.length,
                      itemBuilder: (_, i) {
                        final r = requests[i];
                        return Card(
                          child: ListTile(
                            title: Text(r.gamerTag, style: const TextStyle(fontWeight: FontWeight.w900)),
                            subtitle: Text(r.leagueName),
                            trailing: Wrap(children: [
                              IconButton(onPressed: () => _review(r, 'rejected'), icon: const Icon(Icons.close, color: Color(0xFFFF4D7D))),
                              IconButton(onPressed: () => _review(r, 'approved'), icon: const Icon(Icons.check, color: _cyan)),
                            ]),
                          ),
                        );
                      },
                    ),
            ),
    );
  }
}

// ADMIN
// ============================================================

class AdminForfeitMatchesPage extends StatefulWidget {
  const AdminForfeitMatchesPage({super.key});
  @override State<AdminForfeitMatchesPage> createState() => _AdminForfeitMatchesPageState();
}

class _AdminForfeitMatchesPageState extends State<AdminForfeitMatchesPage> {
  final store = Store.instance;
  String? leagueId;
  bool loading = true;
  String? error;
  final Set<String> forfeitMatchIds = {};

  @override
  void initState() {
    super.initState();
    leagueId = store.activeLeagueId ?? (store.leagues.isNotEmpty ? store.leagues.first.id : null);
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { loading = true; error = null; });
    try {
      if (leagueId != null) {
        await store.selectLeague(leagueId!);
        final rows = await store.supabase
            .from('match_forfeit_audit')
            .select('match_id')
            .eq('league_id', leagueId!);
        forfeitMatchIds
          ..clear()
          ..addAll((rows as List).map((r) => r['match_id'].toString()));
      }
    } catch (e) {
      // The migration may not have been run yet; surface this so admins know.
      error = e.toString();
    }
    if (mounted) setState(() => loading = false);
  }

  String playerName(String id) {
    final p = store.players.where((p) => p.id == id).firstOrNull;
    return p?.gamerTag.isNotEmpty == true ? p!.gamerTag : (p?.name ?? 'Unknown player');
  }

  Future<void> _decide(MatchItem match, String action, String label) async {
    final note = TextEditingController();
    final accepted = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text(label),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${playerName(match.homeId)} vs ${playerName(match.awayId)}'),
        const SizedBox(height: 10),
        Text(action == 'home_win' ? 'This records a 3–0 forfeit win for ${playerName(match.homeId)}.' : action == 'away_win' ? 'This records a 0–3 forfeit win for ${playerName(match.awayId)}.' : action == 'double_forfeit' ? 'This records a 0–0 double forfeit with no winner.' : 'This cancels the result and returns the fixture to Scheduled so it can be rescheduled.'),
        const SizedBox(height: 10),
        TextField(controller: note, maxLines: 3, decoration: const InputDecoration(labelText: 'Reason / admin note (required)', border: OutlineInputBorder())),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCEL')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('CONFIRM DECISION'))],
    ));
    if (accepted != true) { note.dispose(); return; }
    if (note.text.trim().isEmpty) {
      note.dispose();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a reason before applying this decision.')));
      return;
    }
    setState(() => loading = true);
    final result = await store.adminForfeitMatch(matchId: match.id, action: action, note: note.text.trim());
    note.dispose();
    if (!mounted) return;
    if (result != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
      setState(() => loading = false);
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label saved.')));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final matches = [...store.matches]..sort((a, b) => a.round.compareTo(b.round));
    return Scaffold(
      appBar: AppBar(title: const Text('Admin Forfeit & Match Decisions'), actions: [IconButton(onPressed: loading ? null : _load, icon: const Icon(Icons.refresh))]),
      body: loading ? const Center(child: CircularProgressIndicator()) : ListView(padding: const EdgeInsets.all(14), children: [
        const Text('ADMIN-ONLY MATCH RESOLUTION', style: TextStyle(color: _yellow, fontWeight: FontWeight.w900, fontSize: 17)),
        const SizedBox(height: 6),
        const Text('Use only after reviewing the situation. Forfeit wins are recorded as confirmed league results and logged separately from screenshot-verified matches.', style: TextStyle(color: _muted)),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(value: leagueId, decoration: const InputDecoration(labelText: 'SELECT LEAGUE'), items: store.leagues.map((l) => DropdownMenuItem(value: l.id, child: Text(l.name))).toList(), onChanged: loading ? null : (v) async { if (v == null) return; setState(() => leagueId = v); await _load(); }),
        if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text('Could not load forfeit history. Make sure the admin-forfeit SQL migration has been run.\n$error', style: const TextStyle(color: Colors.redAccent))),
        const SizedBox(height: 10),
        if (matches.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Text('No fixtures found for this league.')),
        ...matches.map((m) {
          final done = m.status == 'Confirmed';
          final wasForfeit = forfeitMatchIds.contains(m.id);
          return Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('MATCH DAY ${m.round} • ${m.status.toUpperCase()}', style: const TextStyle(color: _cyan, fontWeight: FontWeight.w900, fontSize: 11)),
            const SizedBox(height: 5),
            Text('${playerName(m.homeId)}  vs  ${playerName(m.awayId)}', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
            if (m.homeScore != null && m.awayScore != null) Text('Current score: ${m.homeScore} – ${m.awayScore}'),
            if (wasForfeit) const Padding(padding: EdgeInsets.only(top: 5), child: Text('⚠ ADMIN FORFEIT / DECISION LOGGED', style: TextStyle(color: _yellow, fontWeight: FontWeight.w900, fontSize: 11))),
            if (done) const Padding(padding: EdgeInsets.only(top: 5), child: Text('Already confirmed. This screen will not overwrite a confirmed result.', style: TextStyle(color: _muted, fontSize: 12))),
            if (!done) Wrap(spacing: 4, runSpacing: 4, children: [
              TextButton(onPressed: loading ? null : () => _decide(m, 'home_win', 'Award home-player forfeit win'), child: const Text('HOME WINS 3–0')),
              TextButton(onPressed: loading ? null : () => _decide(m, 'away_win', 'Award away-player forfeit win'), child: const Text('AWAY WINS 3–0')),
              TextButton(onPressed: loading ? null : () => _decide(m, 'double_forfeit', 'Record double forfeit'), child: const Text('DOUBLE FORFEIT 0–0')),
              TextButton(onPressed: loading ? null : () => _decide(m, 'cancel_reschedule', 'Cancel / reschedule fixture'), child: const Text('CANCEL / RESCHEDULE')),
            ]),
          ])));
        }),
      ]),
    );
  }
}

class NoShowReportsAdminPage extends StatefulWidget {
  const NoShowReportsAdminPage({super.key});
  @override State<NoShowReportsAdminPage> createState() => _NoShowReportsAdminPageState();
}

class _NoShowReportsAdminPageState extends State<NoShowReportsAdminPage> {
  bool loading = true;
  String? error;
  List<Map<String, dynamic>> reports = [];

  Future<void> load() async {
    setState(() { loading = true; error = null; });
    try {
      final data = await Store.instance.supabase
          .from('no_show_reports')
          .select('id, match_id, league_id, reporter_id, reported_player_id, reason, status, response_deadline, admin_decision, admin_note, created_at')
          .order('created_at', ascending: false);
      reports = (data as List).map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (e) { error = e.toString(); }
    if (mounted) setState(() => loading = false);
  }

  Future<void> resolve(Map<String, dynamic> report, String decision) async {
    final note = TextEditingController();
    final extension = TextEditingController(text: '24');
    final accepted = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text('Resolve report: ${decision.replaceAll('_', ' ')}'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: note, decoration: const InputDecoration(labelText: 'Admin note (optional)')),
        if (decision == 'extend_deadline') TextField(controller: extension, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Extra hours (1–168)')),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('CANCEL')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('CONFIRM'))],
    ));
    if (accepted != true) return;
    try {
      await Store.instance.supabase.rpc('resolve_no_show_report', params: {
        'p_report_id': report['id'], 'p_decision': decision,
        'p_admin_note': note.text.trim().isEmpty ? null : note.text.trim(),
        'p_extend_hours': decision == 'extend_deadline' ? int.tryParse(extension.text) : null,
      });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No-show report updated.')));
      await load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not resolve report: $e')));
    }
  }

  @override void initState() { super.initState(); load(); }
  String playerName(dynamic id) {
    final p = Store.instance.players.where((p) => p.id == id?.toString()).toList();
    return p.isEmpty ? (id?.toString() ?? 'Unknown player') : p.first.gamerTag;
  }
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('No-show Reports'), actions: [IconButton(onPressed: loading ? null : load, icon: const Icon(Icons.refresh))]),
    body: loading ? const Center(child: CircularProgressIndicator()) : error != null
      ? Center(child: Padding(padding: const EdgeInsets.all(20), child: Text('Could not load reports:\n$error')))
      : reports.isEmpty ? const Center(child: Text('No no-show reports yet.'))
      : ListView(padding: const EdgeInsets.all(14), children: reports.map((r) {
          final status = r['status']?.toString() ?? 'unknown';
          final deadline = DateTime.tryParse(r['response_deadline']?.toString() ?? '')?.toLocal().toString() ?? 'Not set';
          final pending = !['resolved', 'rejected'].contains(status);
          return Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${playerName(r['reporter_id'])} reported ${playerName(r['reported_player_id'])}', style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6), Text('Reason: ${r['reason']}'),
            Text('Status: $status'), Text('Response deadline: $deadline'),
            if ((r['admin_note'] ?? '').toString().isNotEmpty) Text('Admin note: ${r['admin_note']}'),
            if (pending) Wrap(spacing: 6, runSpacing: 4, children: [
              TextButton(onPressed: () => resolve(r, 'award_reporter'), child: const Text('Award reporter')),
              TextButton(onPressed: () => resolve(r, 'award_reported_player'), child: const Text('Award opponent')),
              TextButton(onPressed: () => resolve(r, 'extend_deadline'), child: const Text('Extend deadline')),
              TextButton(onPressed: () => resolve(r, 'reject_report'), child: const Text('Reject')),
              TextButton(onPressed: () => resolve(r, 'no_penalty'), child: const Text('No penalty')),
            ]),
          ])));
        }).toList()),
  );
}

class ScreenshotTimerAdminPage extends StatefulWidget {
  const ScreenshotTimerAdminPage({super.key});
  @override State<ScreenshotTimerAdminPage> createState() => _ScreenshotTimerAdminPageState();
}

class _ScreenshotTimerAdminPageState extends State<ScreenshotTimerAdminPage> {
  String? leagueId;
  int screenshotHours = 24;
  int noShowHours = 24;
  bool enabled = true;
  bool loading = true;
  bool saving = false;

  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try {
      await Store.instance.refreshLeagues();
      if (Store.instance.leagues.isNotEmpty) {
        final league = Store.instance.leagues.firstWhere((l) => l.id == leagueId, orElse: () => Store.instance.leagues.first);
        leagueId = league.id; screenshotHours = league.screenshotResponseHours; noShowHours = league.noShowResponseHours; enabled = league.noShowReportsEnabled;
      }
    } catch (_) {}
    if (mounted) setState(() => loading = false);
  }
  Future<void> _save() async {
    if (leagueId == null) return;
    setState(() => saving = true);
    try {
      await Store.instance.supabase.from('leagues').update({
        'screenshot_response_hours': screenshotHours,
        'no_show_response_hours': noShowHours,
        'no_show_reports_enabled': enabled,
      }).eq('id', leagueId!);
      await Store.instance.refreshLeagues();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('League timer settings saved.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save settings: $e')));
    }
    if (mounted) setState(() => saving = false);
  }
  Widget _hours(String title, int value, ValueChanged<int> changed) => Card(child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [Expanded(child: Text(title)), IconButton(onPressed: value <= 1 ? null : () => changed(value - 1), icon: const Icon(Icons.remove)), Text('$value h', style: const TextStyle(fontWeight: FontWeight.bold)), IconButton(onPressed: value >= 168 ? null : () => changed(value + 1), icon: const Icon(Icons.add))])));
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Screenshot & No-show Timers')),
    body: loading ? const Center(child: CircularProgressIndicator()) : Store.instance.leagues.isEmpty ? const Center(child: Text('Create a league first.')) : ListView(padding: const EdgeInsets.all(16), children: [
      DropdownButtonFormField<String>(value: leagueId, decoration: const InputDecoration(labelText: 'League'), items: Store.instance.leagues.map((l) => DropdownMenuItem(value: l.id, child: Text(l.name, overflow: TextOverflow.ellipsis))).toList(), onChanged: (id) { final l = Store.instance.leagues.firstWhere((x) => x.id == id); setState(() { leagueId = id; screenshotHours = l.screenshotResponseHours; noShowHours = l.noShowResponseHours; enabled = l.noShowReportsEnabled; }); }),
      const SizedBox(height: 12),
      _hours('Screenshot response window', screenshotHours, (v) => setState(() => screenshotHours = v)),
      _hours('No-show response window', noShowHours, (v) => setState(() => noShowHours = v)),
      SwitchListTile(title: const Text('Enable no-show reports'), value: enabled, onChanged: (v) => setState(() => enabled = v)),
      const SizedBox(height: 12), FilledButton.icon(onPressed: saving ? null : _save, icon: const Icon(Icons.save), label: Text(saving ? 'SAVING…' : 'SAVE SETTINGS')),
      const SizedBox(height: 8), const Text('Timer settings apply to future reports/submissions. Existing deadlines are not automatically recalculated.'),
    ]),
  );
}

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
        _neonAction(context, Icons.menu_book, 'MANAGE APP RULES', 'Edit and publish the general CHIBBYBALL rules', _purple, () => open(const AppRulesPage())),
        const SizedBox(height: 9),
        _neonAction(context, Icons.rule, 'MANAGE LEAGUE RULES', 'Publish rules for individual leagues', _blue, () => open(const LeagueRulesPage())),
        const SizedBox(height: 9),
        _neonAction(context, Icons.emoji_events, 'MANAGE LEAGUES', 'Create and activate multiple leagues', _yellow, () => open(const LeagueManagementPage())),
        const SizedBox(height: 9),
        _neonAction(context, Icons.fact_check_outlined, 'LEAGUE REQUESTS', 'Approve or reject player league requests', _purple, () => open(const LeagueRequestsAdminPage())),
         _neonAction(context, Icons.person_add_alt_1, 'PLAYER JOIN REQUESTS', 'Approve or reject requests to join admin and creator leagues', _cyan, () => open(const LeagueJoinRequestsAdminPage())),
         const SizedBox(height: 9),
        const SizedBox(height: 9),
        _neonAction(context, Icons.groups_2_outlined, 'LEGACY BATCH ACCESS', 'Legacy batch settings; Creator Badge is now required to create leagues', _cyan, () => open(const CreatorBatchAdminPage())),
        const SizedBox(height: 9),
        _neonAction(context, Icons.verified, 'BADGE MANAGEMENT', 'Manually award a Creator Badge to a player', _yellow, () => open(const BadgeAdminPage())),
        const SizedBox(height: 9),
        _neonAction(context, Icons.emoji_events, 'CHAMPIONS LEAGUE', 'Create and manage the overall championship season', _purple, () => open(const ChampionsLeaguePage())),
        const SizedBox(height: 9),
        _neonAction(context, Icons.calendar_month, 'MATCH SCHEDULE', 'Set date and time windows', _cyan, () => open(const AdminMatchSchedulePage())),
        const SizedBox(height: 9),
        _neonAction(context, Icons.fact_check, 'RESULT REVIEW', 'Confirm or dispute submitted results', _purple, () => open(const ResultReviewPage())),
        const SizedBox(height: 9),
        _neonAction(context, Icons.flag_outlined, 'NO-SHOW REPORTS', 'Review and resolve player no-show reports', _yellow, () => open(const NoShowReportsAdminPage())),
        const SizedBox(height: 9),
        _neonAction(context, Icons.gavel, 'ADMIN FORFEIT & MATCH DECISIONS', 'Award a forfeit win, record double forfeits, or cancel/reschedule fixtures', _yellow, () => open(const AdminForfeitMatchesPage())),
        const SizedBox(height: 9),
        _neonAction(context, Icons.timer_outlined, 'SCREENSHOT & NO-SHOW TIMERS', 'Configure response windows for each league', _purple, () => open(const ScreenshotTimerAdminPage())),
        const SizedBox(height: 9),
        _neonAction(context, Icons.manage_accounts, 'MANAGE PLAYERS', 'Assign, remove or disregister players', _cyan, () => open(const PlayerManagementPage())),
        const SizedBox(height: 9),
        _neonAction(context, Icons.refresh, 'REFRESH PLAYERS', 'Reload players and league data', _blue, refresh),
        const SizedBox(height: 9),
        _neonAction(context, Icons.auto_awesome, 'GENERATE FIXTURES', 'Create single-round or Home & Away fixtures', _yellow, loading ? () {} : generateFixtures),
        const SizedBox(height: 9),
        _neonAction(context, Icons.account_tree, 'COMMUNITY TOURNAMENTS', 'Create, publish, start and manage tournaments', _purple, () => open(const CommunityTournamentsPage())),
        const SizedBox(height: 9),
        _neonAction(context, Icons.today, 'DAILY & WEEKLY CHALLENGES', 'Review automatically generated player challenges', _cyan, () => open(const PlayerMissionsPage())),
        const SizedBox(height: 9),
        _neonAction(context, Icons.dynamic_feed, 'LIVE ACTIVITY FEED', 'View confirmed match and community activity', _yellow, () => open(const CommunityActivityPage())),
        const SizedBox(height: 18),
        Row(children: [Expanded(child: _neonSectionTitle('REGISTERED PLAYERS', accent: _cyan)), Text('${players.length}', style: const TextStyle(color: _yellow, fontSize: 18, fontWeight: FontWeight.w900))]),
        const SizedBox(height: 10),
        ...players.take(20).map((player) {
          final online = player.isOnline && (player.lastSeen == null || DateTime.now().toUtc().difference(player.lastSeen!.toUtc()).inMinutes < 3);
          return Container(margin: const EdgeInsets.only(bottom: 8), decoration: _neonBox(online ? _cyan : _blue, radius: 16), child: ListTile(contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2), leading: Stack(children: [_playerAvatar(player, radius: 22, accent: online ? _cyan : _blue), Positioned(right: 0, bottom: 0, child: Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle, color: online ? const Color(0xFF20E070) : const Color(0xFFB7A77C), border: Border.all(color: _panel, width: 2))))]), title: Text(player.gamerTag, style: const TextStyle(fontWeight: FontWeight.w900)), subtitle: Text(online ? 'Online' : 'Offline', style: TextStyle(color: online ? const Color(0xFF20E070) : _muted, fontSize: 11)), trailing: IconButton(tooltip: 'Message', onPressed: () => open(ChatPage(player: player)), icon: const Icon(Icons.chat_bubble_outline, color: _purple))));
        }),
      ])),
    );
  }
}



// ============================================================
// GENERAL APP RULES — editable by admins, readable by players
// Requires the chibbyball_app_rules SQL migration.
// ============================================================
class AppRulesPage extends StatefulWidget {
  const AppRulesPage({super.key});
  @override
  State<AppRulesPage> createState() => _AppRulesPageState();
}

class _AppRulesPageState extends State<AppRulesPage> {
  final TextEditingController _rules = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  String? _error;
  DateTime? _updatedAt;
  bool get _isAdmin => Store.instance.current?.admin == true;

  @override
  void initState() { super.initState(); _loadRules(); }
  @override
  void dispose() { _rules.dispose(); super.dispose(); }

  Future<void> _loadRules() async {
    setState(() { _loading = true; _error = null; });
    try {
      final row = await Store.instance.supabase
          .from('chibbyball_app_rules')
          .select('rules_text, updated_at')
          .eq('id', 1)
          .maybeSingle();
      if (row != null) {
        _rules.text = row['rules_text']?.toString() ?? '';
        _updatedAt = DateTime.tryParse(row['updated_at']?.toString() ?? '');
      } else {
        _rules.text = 'Welcome to CHIBBYBALL!\n\n1. Treat every player with respect.\n2. Play fairly; cheating and deliberate result manipulation are prohibited.\n3. Submit honest scores and genuine screenshots when required.\n4. Respect scheduled match times and deadlines.\n5. Report disputes and no-shows honestly.\n6. Follow league-specific rules and admin decisions made under those rules.\n7. Harassment, threats, fake evidence, and repeated abuse may lead to disciplinary action.';
      }
    } catch (e) {
      _error = 'Could not load rules. Confirm the CHIBBYBALL rules SQL migration has been run. Details: $e';
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _saveRules() async {
    if (!_isAdmin) return;
    final text = _rules.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter the rules before publishing.')));
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      await Store.instance.supabase.from('chibbyball_app_rules').upsert({
        'id': 1,
        'rules_text': text,
        'updated_by': Store.instance.current!.id,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
      await _loadRules();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('CHIBBYBALL rules published successfully.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not publish rules: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(_isAdmin ? 'Manage App Rules' : 'Rules & Regulations'), actions: [IconButton(onPressed: _loading ? null : _loadRules, icon: const Icon(Icons.refresh))]),
    body: _loading ? const Center(child: CircularProgressIndicator()) : ListView(padding: const EdgeInsets.all(16), children: [
      Container(padding: const EdgeInsets.all(16), decoration: _neonBox(_purple, radius: 18), child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('CHIBBYBALL COMMUNITY STANDARDS', style: TextStyle(color: _purple, fontWeight: FontWeight.w900, fontSize: 16)), SizedBox(height: 8), Text('These general rules apply across the app. Individual leagues may publish additional competition rules.', style: TextStyle(color: _muted, height: 1.4))])),
      const SizedBox(height: 12),
      if (_error != null) Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(border: Border.all(color: Colors.redAccent), borderRadius: BorderRadius.circular(12)), child: Text(_error!, style: const TextStyle(color: Colors.redAccent))),
      TextField(controller: _rules, readOnly: !_isAdmin, minLines: 12, maxLines: null, keyboardType: TextInputType.multiline, decoration: InputDecoration(labelText: _isAdmin ? 'Edit general rules' : 'Current rules', alignLabelWithHint: true, hintText: 'Write the CHIBBYBALL rules here...', border: const OutlineInputBorder())),
      if (_updatedAt != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text('Last published: ${_updatedAt!.toLocal()}', style: const TextStyle(color: _muted, fontSize: 12))),
      if (_isAdmin) ...[const SizedBox(height: 14), SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: _saving ? null : _saveRules, icon: const Icon(Icons.publish), label: Text(_saving ? 'PUBLISHING…' : 'SAVE & PUBLISH RULES')))],
      const SizedBox(height: 10),
      const Text('Please read these rules carefully. Updates are shared through the app and do not require a new APK.', style: TextStyle(color: _muted, height: 1.4)),
    ]),
  );
}


// ============================================================
// INDIVIDUAL LEAGUE RULES
// Requires chibbyball_league_rules_migration.sql.
// Main admins and registered league managers can edit; members can read.
// ============================================================
class LeagueRulesPage extends StatefulWidget {
  const LeagueRulesPage({super.key});
  @override
  State<LeagueRulesPage> createState() => _LeagueRulesPageState();
}

class _LeagueRulesPageState extends State<LeagueRulesPage> {
  final TextEditingController _rules = TextEditingController();
  String? _selectedLeagueId;
  bool _loading = true;
  bool _saving = false;
  bool _canEdit = false;
  String? _error;
  DateTime? _updatedAt;
  List<LeagueInfo> _visibleLeagues = [];
  final Store _store = Store.instance;

  @override
  void initState() { super.initState(); _init(); }
  @override
  void dispose() { _rules.dispose(); super.dispose(); }

  Future<void> _init() async {
    setState(() { _loading = true; _error = null; });
    try {
      await _store.refreshLeagues();
      final me = _store.current;
      if (me == null) throw Exception('Please sign in again.');
      if (me.admin) {
        _visibleLeagues = List<LeagueInfo>.from(_store.leagues);
      } else {
        final rows = await _store.supabase.from('league_members').select('league_id').eq('player_id', me.id);
        final ids = (rows as List).map((r) => r['league_id'].toString()).toSet();
        final managerRows = await _store.supabase.from('league_managers').select('league_id').eq('player_id', me.id);
        ids.addAll((managerRows as List).map((r) => r['league_id'].toString()));
        _visibleLeagues = _store.leagues.where((l) => ids.contains(l.id)).toList();
      }
      if (_visibleLeagues.isNotEmpty) {
        _selectedLeagueId ??= _visibleLeagues.first.id;
        if (!_visibleLeagues.any((l) => l.id == _selectedLeagueId)) _selectedLeagueId = _visibleLeagues.first.id;
      }
      await _loadSelectedRules();
    } catch (e) { _error = 'Could not load league rules: $e'; }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadSelectedRules() async {
    final id = _selectedLeagueId;
    final me = _store.current;
    if (id == null || me == null) { _rules.clear(); _canEdit = false; return; }
    setState(() { _loading = true; _error = null; });
    try {
      _canEdit = me.admin;
      if (!_canEdit) {
        final manager = await _store.supabase.from('league_managers').select('player_id').eq('league_id', id).eq('player_id', me.id).maybeSingle();
        _canEdit = manager != null;
      }
      final row = await _store.supabase.from('chibbyball_league_rules').select('rules_text, updated_at').eq('league_id', id).maybeSingle();
      _rules.text = row?['rules_text']?.toString() ?? '';
      _updatedAt = row?['updated_at'] == null ? null : DateTime.tryParse(row!['updated_at'].toString());
    } catch (e) { _error = 'Could not load rules. Confirm the league-rules SQL migration has been run. Details: $e'; }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _saveRules() async {
    final id = _selectedLeagueId;
    final me = _store.current;
    if (!_canEdit || id == null || me == null) return;
    if (_rules.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter the league rules before publishing.')));
      return;
    }
    setState(() { _saving = true; _error = null; });
    try {
      await _store.supabase.from('chibbyball_league_rules').upsert({
        'league_id': id, 'rules_text': _rules.text.trim(),
        'updated_by': me.id, 'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
      await _loadSelectedRules();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('League rules published successfully.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not publish league rules: $e')));
    } finally { if (mounted) setState(() => _saving = false); }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(_canEdit ? 'Manage League Rules' : 'League Rules'), actions: [IconButton(onPressed: _loading ? null : _init, icon: const Icon(Icons.refresh))]),
    body: _loading ? const Center(child: CircularProgressIndicator()) : ListView(padding: const EdgeInsets.all(16), children: [
      Container(padding: const EdgeInsets.all(16), decoration: _neonBox(_blue, radius: 18), child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('INDIVIDUAL LEAGUE RULES', style: TextStyle(color: _cyan, fontWeight: FontWeight.w900, fontSize: 16)), SizedBox(height: 8), Text('Each league has separate rules. Changes are published to the app without requiring a new APK.', style: TextStyle(color: _muted))])),
      const SizedBox(height: 14),
      if (_visibleLeagues.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No leagues are available for your account yet.'))
      else ...[
        DropdownButtonFormField<String>(value: _selectedLeagueId, isExpanded: true, decoration: const InputDecoration(labelText: 'SELECT LEAGUE'), items: _visibleLeagues.map((l) => DropdownMenuItem(value: l.id, child: Text(l.name, overflow: TextOverflow.ellipsis))).toList(), onChanged: _loading ? null : (v) async { setState(() => _selectedLeagueId = v); await _loadSelectedRules(); }),
        const SizedBox(height: 12),
        TextField(controller: _rules, readOnly: !_canEdit, minLines: 10, maxLines: null, textCapitalization: TextCapitalization.sentences, decoration: InputDecoration(labelText: _canEdit ? 'Edit league rules' : 'Current league rules', alignLabelWithHint: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(16))),),
        if (_updatedAt != null) ...[const SizedBox(height: 8), Text('Last published: ${_updatedAt!.toLocal()}', style: const TextStyle(color: _muted, fontSize: 12))],
        if (_canEdit) ...[const SizedBox(height: 14), SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: _saving ? null : _saveRules, icon: const Icon(Icons.publish), label: Text(_saving ? 'PUBLISHING…' : 'SAVE & PUBLISH LEAGUE RULES')))],
      ],
      if (_error != null) ...[const SizedBox(height: 12), Text(_error!, style: const TextStyle(color: Colors.redAccent))],
    ]),
  );
}

// Draws actual branching connections between knockout rounds.
class _TournamentTreePainter extends CustomPainter {
  final int firstCount, stages;
  final double cardWidth, gap, rowHeight;
  const _TournamentTreePainter(this.firstCount, this.stages,
      this.cardWidth, this.gap, this.rowHeight);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFFFFC928)
      ..strokeWidth = 2..style = PaintingStyle.stroke;
    for (var stage = 0; stage < stages - 1; stage++) {
      final count = firstCount >> stage;
      final x1 = stage * (cardWidth + gap) + cardWidth;
      final x2 = (stage + 1) * (cardWidth + gap);
      for (var i = 0; i + 1 < count; i += 2) {
        final y1 = ((1 << stage) * (i + .5) - .5) * rowHeight + rowHeight / 2;
        final y2 = ((1 << stage) * (i + 1.5) - .5) * rowHeight + rowHeight / 2;
        final midX = (x1 + x2) / 2;
        final midY = (y1 + y2) / 2;
        canvas.drawLine(Offset(x1, y1), Offset(midX, y1), paint);
        canvas.drawLine(Offset(x1, y2), Offset(midX, y2), paint);
        canvas.drawLine(Offset(midX, y1), Offset(midX, y2), paint);
        canvas.drawLine(Offset(midX, midY), Offset(x2, midY), paint);
      }
    }
  }
  @override
  bool shouldRepaint(covariant _TournamentTreePainter oldDelegate) =>
      firstCount != oldDelegate.firstCount || stages != oldDelegate.stages;
}
