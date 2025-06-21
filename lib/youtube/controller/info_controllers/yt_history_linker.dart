part of '../youtube_info_controller.dart';

class _YoutubeHistoryLinker {
  final String? Function() activeAccId;
  _YoutubeHistoryLinker(this.activeAccId);

  late String _dbDirectory;
  void init(String directory) {
    _dbDirectory = directory;
    _ensureDBOpened();
    ConnectivityController.inst.registerOnConnectionRestored(_onConnectionRestored);
  }

  void dispose() {
    _pendingRequestsDBIdle?.close();
  }

  void _onConnectionRestored() {
    if (_hasPendingRequests) executePendingRequests();
  }

  String? _dbOpenedAccId;
  void _ensureDBOpened() {
    final accId = activeAccId();
    if (accId == _dbOpenedAccId) return; // if both null, means no db will be opened, meaning db operations will not execute.. keikaku dori

    _dbOpenedAccId = accId;
    _pendingRequestsDBIdle?.close();
    if (accId == null) return;
    _pendingRequestsDBIdle = DBWrapper.open(_dbDirectory, 'pending_history_$accId')..claimFreeSpace();
    _pendingRequestsCompleter?.completeIfWasnt();
    _pendingRequestsCompleter = null;
    executePendingRequests();
  }

  DBWrapperAsync? _pendingRequestsDBIdle;
  DBWrapperAsync? get _pendingRequestsDB {
    _ensureDBOpened();
    return _pendingRequestsDBIdle;
  }

  bool get _hasConnection => ConnectivityController.inst.hasConnection;

  bool _hasPendingRequests = true;

  Completer<void>? _pendingRequestsCompleter;

  void _addPendingRequest({required String videoId, required VideoStreamsResult? streamResult}) {
    _hasPendingRequests = true;
    final db = _pendingRequestsDB;
    if (db == null) return;

    final vId = streamResult?.videoId ?? videoId;
    final key = "${vId}_${DateTime.now().millisecondsSinceEpoch}";
    final map = {
      'videoId': vId,
      'statsPlaybackUrl': streamResult?.statsPlaybackUrl,
      'statsWatchtimeUrl': streamResult?.statsWatchtimeUrl,
    };
    unawaited(db.put(key, map));
  }

  Future<List<String>>? getPendingRequests() {
    return _pendingRequestsDB?.loadAllKeysResult();
  }

  void executePendingRequests() async {
    if (!_hasConnection) return;
    if (!settings.youtube.markVideoWatched) return;

    if (_pendingRequestsCompleter != null) {
      // -- already executing
      return;
    }

    _pendingRequestsCompleter ??= Completer<void>();

    final queue = Queue(parallel: 1);

    bool hadError = false;

    int itemsAddedToQueue = 0;

    final db = _pendingRequestsDB;

    final result = await db?.loadEverythingKeyedResult();
    if (db != null && result != null) {
      for (final e in result.entries) {
        if (hadError) return;
        if (!_hasConnection) {
          hadError = true;
          return;
        }

        itemsAddedToQueue++;

        queue.add(
          () async {
            if (hadError) return;
            if (!_hasConnection) {
              hadError = true;
              return;
            }

            final key = e.key;
            final value = e.value;
            bool added = false;
            try {
              String? statsPlaybackUrl = value['statsPlaybackUrl'];
              String? statsWatchtimeUrl = value['statsWatchtimeUrl'];
              if (statsPlaybackUrl == null && _hasConnection) {
                final videoId = value['videoId'] ?? key.substring(0, 11);
                final streamsRes = await YoutubeInfoController.video.fetchVideoStreams(videoId, forceRequest: true);
                statsPlaybackUrl = streamsRes?.statsPlaybackUrl;
                statsWatchtimeUrl ??= streamsRes?.statsWatchtimeUrl;
              }
              if (statsPlaybackUrl != null) {
                // -- we check beforehand to supress internal error
                final res = await YoutiPie.history.addVideoToHistory(
                  statsPlaybackUrl: statsPlaybackUrl,
                  statsWatchtimeUrl: statsWatchtimeUrl,
                );
                added = res.$1;
              }
            } catch (_) {}
            if (added || _hasConnection) {
              // had connection but didnt mark. idc
              unawaited(db.delete(key));
            } else {
              hadError = true; // no connection, will not proceed anymore
            }
          },
        );
      }
    }

    if (itemsAddedToQueue > 0) await queue.onComplete;

    if (!hadError) _hasPendingRequests = false;

    _pendingRequestsCompleter?.completeIfWasnt();
    _pendingRequestsCompleter = null;
  }

  Future<YTMarkVideoWatchedResult> markVideoWatched({required String videoId, required VideoStreamsResult? streamResult, bool errorOnMissingParam = true}) async {
    if (_dbOpenedAccId == null) return YTMarkVideoWatchedResult.noAccount; // no acc signed in
    if (!settings.youtube.markVideoWatched) return YTMarkVideoWatchedResult.userDenied;

    if (_hasPendingRequests) {
      executePendingRequests();
    }

    if (_pendingRequestsCompleter != null) {
      await _pendingRequestsCompleter!.future;
    }

    bool added = false;

    if (_hasConnection && !_hasPendingRequests) {
      String? statsPlaybackUrl = streamResult?.statsPlaybackUrl;
      String? statsWatchtimeUrl = streamResult?.statsWatchtimeUrl;
      if (statsPlaybackUrl == null) {
        final streamsRes = await YoutubeInfoController.video.fetchVideoStreams(videoId, forceRequest: false);
        statsPlaybackUrl = streamsRes?.statsPlaybackUrl;
        statsWatchtimeUrl ??= streamsRes?.statsWatchtimeUrl;
      }
      if (statsPlaybackUrl != null || errorOnMissingParam) {
        final res = await YoutiPie.history.addVideoToHistory(
          statsPlaybackUrl: statsPlaybackUrl,
          statsWatchtimeUrl: statsWatchtimeUrl,
        );
        added = res.$1;
      }
    }
    if (added) {
      return YTMarkVideoWatchedResult.marked;
    } else {
      // -- the handling of executing pending requests is different.
      // -- even if `added` is false due to missing params/etc, it will
      // -- properly get removed while exeuting pending.
      _addPendingRequest(videoId: videoId, streamResult: streamResult);
      return YTMarkVideoWatchedResult.addedAsPending;
    }
  }

  Future<YoutiPieHistoryResult?> fetchHistory({ExecuteDetails? details}) {
    return YoutiPie.history.fetchHistory(details: details);
  }
}

enum YTMarkVideoWatchedResult {
  noAccount,
  userDenied,
  marked,
  addedAsPending,
}
