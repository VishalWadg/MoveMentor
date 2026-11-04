import 'dart:async';
import 'dart:convert';
import 'package:archive/archive.dart';
import '../../domain/chess/chess_models.dart';
import '../../domain/chess/pgn_parser.dart';
import '../../domain/coach/coach_contracts.dart';
import '../../ports/ports.dart';

/// Part 26.3: ImportJob State Machine transitions.
class ImportJobStateMachine {
  String state = 'queued';
  String? errorCode;
  String? resumeToken;

  void onOnlineAvailable({required bool offlineOnly}) {
    if (state == 'queued' && !offlineOnly) {
      state = 'running';
    }
  }

  void onUserCancel() {
    if (state == 'queued' || state == 'running' || state == 'paused_rate_limit') {
      state = 'cancelled';
    }
  }

  void onRateLimit429({String? token}) {
    if (state == 'running') {
      state = 'paused_rate_limit';
      resumeToken = token;
      errorCode = 'E-IMP-02';
    }
  }

  void onRateLimitTimerComplete() {
    if (state == 'paused_rate_limit') {
      state = 'running';
      errorCode = null;
    }
  }

  void onNetworkLoss({String? token}) {
    if (state == 'running') {
      state = 'queued';
      resumeToken = token;
      errorCode = 'E-IMP-03';
    }
  }

  void onAllPagesFetched() {
    if (state == 'running') {
      state = 'done';
    }
  }

  void onNonRetryableError(String code) {
    state = 'failed';
    errorCode = code;
  }

  void onUserRetry() {
    if (state == 'failed') {
      state = 'queued';
      errorCode = null;
    }
  }
}

/// Part 10.1 & 26.1: Lichess API Source.
/// One concurrent request at a time; max=100 default; clocks=true, opening=true;
/// HTTP 429 pauses >= 60 s with countdown (E-IMP-02).
class LichessGameSource implements GameSource {
  final NetworkGatewayPort gateway;
  final String contactEmail;
  final Duration rateLimitWaitDuration;

  LichessGameSource({
    required this.gateway,
    this.contactEmail = 'support@movementor.app',
    this.rateLimitWaitDuration = const Duration(seconds: 60),
  });

  @override
  String get sourceId => 'lichess';

  @override
  bool get requiresOnline => true;

  @override
  Stream<ImportProgressUpdate> fetchGames(
    ImportRequestParams params, {
    CancelToken? cancel,
  }) async* {
    final username = (params.username ?? '').trim();
    if (username.isEmpty) {
      yield const ImportProgressUpdate(
        status: 'failed',
        errorCode: 'E-IMP-01',
        message: 'No account with that name. Edit name.',
      );
      return;
    }

    if (!gateway.isDeviceOnline) {
      yield const ImportProgressUpdate(
        status: 'queued',
        errorCode: 'E-IMP-04',
        message: 'Needs internet. Queue for later?',
      );
      return;
    }

    yield const ImportProgressUpdate(
      status: 'fetching',
      message: 'Connecting to Lichess...',
    );

    final queryParams = <String, String>{
      'max': params.maxGames.toString(),
      'clocks': 'true',
      'opening': 'true',
      'evals': 'true',
      if (params.sinceEpochMs != null) 'since': params.sinceEpochMs.toString(),
      if (params.untilEpochMs != null) 'until': params.untilEpochMs.toString(),
      if (params.ratedOnly) 'rated': 'true',
      if (params.timeClass != null && params.timeClass!.isNotEmpty)
        'perfType': params.timeClass!,
      if (params.colorFilter != null) 'color': params.colorFilter!.label,
    };

    final uri = Uri.https(
      'lichess.org',
      '/api/games/user/$username',
      queryParams,
    );

    var attempts = 0;
    while (attempts < 3) {
      if (cancel?.isCancelled == true) {
        yield const ImportProgressUpdate(status: 'cancelled');
        return;
      }

      try {
        final resp = await gateway.get(
          uri,
          purpose: 'lichess_import',
          headers: {
            'Accept': 'application/x-chess-pgn',
            'User-Agent': 'MoveMentor/0.2.0 (contact: $contactEmail)',
          },
          cancel: cancel,
        );

        if (resp.statusCode == 404) {
          yield const ImportProgressUpdate(
            status: 'failed',
            errorCode: 'E-IMP-01',
            message: 'No account with that name. Edit name.',
          );
          return;
        }

        if (resp.statusCode == 429) {
          final waitSecs = rateLimitWaitDuration.inSeconds;
          yield ImportProgressUpdate(
            status: 'paused_rate_limit',
            errorCode: 'E-IMP-02',
            rateLimitRemainingSec: waitSecs,
            message: 'The site asked us to slow down. Resuming in $waitSecs s.',
          );
          await Future<void>.delayed(rateLimitWaitDuration);
          attempts++;
          continue;
        }

        if (resp.statusCode >= 500) {
          attempts++;
          if (attempts >= 3) {
            yield const ImportProgressUpdate(
              status: 'failed',
              errorCode: 'E-IMP-03',
              message: 'Lichess server error after 3 retries.',
            );
            return;
          }
          continue;
        }

        final report = PgnParser.parseMultiGamePgn(
          resp.body,
          source: 'lichess',
          savedUsernames: [username],
        );
        yield ImportProgressUpdate(
          status: 'done',
          fetchedCount: report.games.length,
          newCount: report.games.length,
          previewGames: report.games,
        );
        return;
      } catch (e) {
        final code = e.toString().contains('E-IMP-04') ? 'E-IMP-04' : 'E-IMP-03';
        yield ImportProgressUpdate(
          status: code == 'E-IMP-04' ? 'queued' : 'failed',
          errorCode: code,
          message: e.toString(),
        );
        return;
      }
    }
  }
}

/// Part 10.2 & 26.1: Chess.com PubAPI Source.
/// Strictly sequential requests; User-Agent `MoveMentor/0.2.0 (contact: <address>)` (D-10);
/// ETag & Last-Modified conditional requests (304); 410 stops retries immediately (E-IMP-09);
/// 403 triggers blocked version notice (E-IMP-10).
class ChessComGameSource implements GameSource {
  final NetworkGatewayPort gateway;
  final String contactEmail;
  final Map<String, String> _etagCache = {};
  final Map<String, String> _bodyCache = {};

  ChessComGameSource({
    required this.gateway,
    this.contactEmail = 'support@movementor.app',
  });

  @override
  String get sourceId => 'chesscom';

  @override
  bool get requiresOnline => true;

  String get userAgent => 'MoveMentor/0.2.0 (contact: $contactEmail)';

  @override
  Stream<ImportProgressUpdate> fetchGames(
    ImportRequestParams params, {
    CancelToken? cancel,
  }) async* {
    // D-10: Contact address is required before any Chess.com request ships
    if (contactEmail.trim().isEmpty || !contactEmail.contains('@')) {
      yield const ImportProgressUpdate(
        status: 'failed',
        errorCode: 'E-IMP-10',
        message: 'A valid contact address is required for Chess.com User-Agent.',
      );
      return;
    }

    final username = (params.username ?? '').trim().toLowerCase();
    if (username.isEmpty) {
      yield const ImportProgressUpdate(
        status: 'failed',
        errorCode: 'E-IMP-01',
        message: 'No account with that name.',
      );
      return;
    }

    final archivesUri = Uri.https(
      'api.chess.com',
      '/pub/player/$username/games/archives',
    );

    try {
      final archResp = await gateway.get(
        archivesUri,
        purpose: 'chesscom_archives',
        headers: {'User-Agent': userAgent},
        cancel: cancel,
      );

      if (archResp.statusCode == 404) {
        yield const ImportProgressUpdate(
          status: 'failed',
          errorCode: 'E-IMP-01',
          message: 'No account with that name.',
        );
        return;
      }
      if (archResp.statusCode == 410) {
        yield const ImportProgressUpdate(
          status: 'failed',
          errorCode: 'E-IMP-09',
          message: 'Account unavailable.',
        );
        return;
      }
      if (archResp.statusCode == 403) {
        yield const ImportProgressUpdate(
          status: 'failed',
          errorCode: 'E-IMP-10',
          message: 'This version may be blocked. Please update the app.',
        );
        return;
      }

      final decoded = jsonDecode(archResp.body) as Map<String, dynamic>;
      final archiveUrls = ((decoded['archives'] as List<dynamic>?) ?? [])
          .cast<String>()
          .reversed
          .toList(); // Newest month first (Part 26.2)

      final collected = <ParsedPgnGame>[];

      for (final monthUrl in archiveUrls) {
        if (cancel?.isCancelled == true) {
          yield ImportProgressUpdate(
            status: 'cancelled',
            fetchedCount: collected.length,
            previewGames: collected,
          );
          return;
        }
        if (collected.length >= params.maxGames) break;

        final monthUri = Uri.parse(monthUrl);
        final reqHeaders = <String, String>{
          'User-Agent': userAgent,
          if (_etagCache.containsKey(monthUrl))
            'If-None-Match': _etagCache[monthUrl]!,
        };

        final monthResp = await gateway.get(
          monthUri,
          purpose: 'chesscom_month',
          headers: reqHeaders,
          cancel: cancel,
        );

        if (monthResp.statusCode == 410) {
          yield ImportProgressUpdate(
            status: 'failed',
            errorCode: 'E-IMP-09',
            previewGames: collected,
          );
          return;
        }
        if (monthResp.statusCode == 429) {
          yield ImportProgressUpdate(
            status: 'paused_rate_limit',
            errorCode: 'E-IMP-02',
            rateLimitRemainingSec: 60,
            previewGames: collected,
          );
          return;
        }

        String bodyToUse = monthResp.body;
        if (monthResp.statusCode == 304 && _bodyCache.containsKey(monthUrl)) {
          bodyToUse = _bodyCache[monthUrl]!;
        } else if (monthResp.statusCode == 200) {
          if (monthResp.headers.containsKey('etag')) {
            _etagCache[monthUrl] = monthResp.headers['etag']!;
          }
          _bodyCache[monthUrl] = bodyToUse;
        }

        if (bodyToUse.isNotEmpty) {
          final monthJson = jsonDecode(bodyToUse) as Map<String, dynamic>;
          final gamesList = (monthJson['games'] as List<dynamic>?) ?? [];
          for (final gItem in gamesList.reversed) {
            if (collected.length >= params.maxGames) break;
            final gMap = gItem as Map<String, dynamic>;
            final pgnStr = (gMap['pgn'] as String?) ?? '';
            if (pgnStr.isEmpty) continue;
            final rules = (gMap['rules'] as String?) ?? 'chess';
            final report = PgnParser.parseMultiGamePgn(
              pgnStr,
              source: 'chesscom',
              savedUsernames: [username],
            );
            for (final pg in report.games) {
              if (rules != 'chess') {
                // Part 10.2: rules != chess stored but marked not analysable
                collected.add(
                  ParsedPgnGame(
                    game: GameEntity(
                      id: pg.game.id,
                      fingerprint: pg.game.fingerprint,
                      movesHash: pg.game.movesHash,
                      source: 'chesscom',
                      sourceGameId: gMap['url']?.toString(),
                      url: gMap['url']?.toString(),
                      white: pg.game.white,
                      black: pg.game.black,
                      whiteRating: pg.game.whiteRating,
                      blackRating: pg.game.blackRating,
                      result: pg.game.result,
                      playedAt: pg.game.playedAt,
                      variant: rules,
                      pgnRaw: pg.game.pgnRaw,
                      movesSan: pg.game.movesSan,
                      myColor: pg.game.myColor,
                      status: 'not_analysable',
                      importedAt: pg.game.importedAt,
                    ),
                    positions: pg.positions,
                    errorCode: 'E-IMP-08',
                  ),
                );
              } else {
                collected.add(pg);
              }
            }
          }
        }

        yield ImportProgressUpdate(
          status: 'fetching',
          fetchedCount: collected.length,
          previewGames: List.unmodifiable(collected),
        );
      }

      yield ImportProgressUpdate(
        status: 'done',
        fetchedCount: collected.length,
        newCount: collected.length,
        previewGames: collected,
      );
    } catch (e) {
      final code = e.toString().contains('E-IMP-04') ? 'E-IMP-04' : 'E-IMP-03';
      yield ImportProgressUpdate(
        status: code == 'E-IMP-04' ? 'queued' : 'failed',
        errorCode: code,
        message: e.toString(),
      );
    }
  }
}

/// Offline PGN Text / File & ZIP Import Source (Stories B-1, B-2, B-7).
class OfflinePgnGameSource implements GameSource {
  @override
  String get sourceId => 'pgn';

  @override
  bool get requiresOnline => false;

  @override
  Stream<ImportProgressUpdate> fetchGames(
    ImportRequestParams params, {
    CancelToken? cancel,
  }) async* {
    yield const ImportProgressUpdate(
      status: 'validating',
      message: 'Validating PGN games offline...',
    );

    if (params.source == 'zip' && params.fileBytes != null) {
      yield _extractAndParseZip(params.fileBytes!, studentTag: params.studentTag);
      return;
    }

    String rawPgn = params.rawPgnOrPath ?? '';
    if (params.fileBytes != null) {
      if (params.fileBytes!.length > PgnParser.maxFileBytes) {
        yield const ImportProgressUpdate(
          status: 'failed',
          errorCode: 'E-IMP-07',
          message: 'File over 50 MB limit.',
        );
        return;
      }
      rawPgn = PgnParser.decodeBytes(params.fileBytes!);
    }

    final report = PgnParser.parseMultiGamePgn(rawPgn, source: 'pgn');
    if (report.games.isEmpty) {
      yield ImportProgressUpdate(
        status: 'failed',
        errorCode: report.topLevelErrorCode ?? 'E-IMP-05',
        message: 'No valid chess games found in PGN.',
      );
      return;
    }

    yield ImportProgressUpdate(
      status: 'done',
      fetchedCount: report.games.length,
      newCount: report.games.length,
      failedCount: report.partiallyValidCount,
      errorCode: report.topLevelErrorCode,
      previewGames: report.games,
    );
  }

  /// Story B-7: ZIP import (<= 200 MB, only .pgn/.txt entries, rejects path traversal `..`).
  ImportProgressUpdate _extractAndParseZip(
    List<int> zipBytes, {
    String? studentTag,
  }) {
    const maxZipBytes = 200 * 1024 * 1024; // 200 MB
    if (zipBytes.length > maxZipBytes) {
      return const ImportProgressUpdate(
        status: 'failed',
        errorCode: 'E-IMP-07',
        message: 'ZIP exceeds 200 MB limit.',
      );
    }

    final archive = ZipDecoder().decodeBytes(zipBytes);
    final allGames = <ParsedPgnGame>[];

    for (final file in archive) {
      if (!file.isFile) continue;
      final name = file.name.replaceAll(r'\', '/');
      // Reject path traversal
      if (name.contains('../') || name.startsWith('/')) {
        return const ImportProgressUpdate(
          status: 'failed',
          errorCode: 'E-IMP-05',
          message: 'Rejected ZIP entry with unsafe path traversal.',
        );
      }
      final lower = name.toLowerCase();
      if (!lower.endsWith('.pgn') && !lower.endsWith('.txt')) {
        continue;
      }
      final contentBytes = file.content as List<int>;
      final text = PgnParser.decodeBytes(contentBytes);
      final report = PgnParser.parseMultiGamePgn(text, source: 'pgn');
      for (final g in report.games) {
        if (studentTag != null && studentTag.isNotEmpty) {
          allGames.add(
            ParsedPgnGame(
              game: GameEntity(
                id: g.game.id,
                fingerprint: g.game.fingerprint,
                movesHash: g.game.movesHash,
                source: g.game.source,
                white: g.game.white,
                black: g.game.black,
                result: g.game.result,
                event: '${g.game.event ?? "Practice"} [Student: $studentTag]',
                playedAt: g.game.playedAt,
                pgnRaw: g.game.pgnRaw,
                movesSan: g.game.movesSan,
                myColor: g.game.myColor,
                importedAt: g.game.importedAt,
              ),
              positions: g.positions,
            ),
          );
        } else {
          allGames.add(g);
        }
      }
    }

    if (allGames.isEmpty) {
      return const ImportProgressUpdate(
        status: 'failed',
        errorCode: 'E-IMP-05',
        message: 'No .pgn or .txt games found in ZIP archive.',
      );
    }

    return ImportProgressUpdate(
      status: 'done',
      fetchedCount: allGames.length,
      newCount: allGames.length,
      previewGames: allGames,
    );
  }
}
