// ignore_for_file: depend_on_referenced_packages

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';

import 'package:youtipie/class/thumbnail.dart';

import 'package:namida/base/ports_provider.dart';
import 'package:namida/class/http_manager.dart';
import 'package:namida/class/http_response_wrapper.dart';
import 'package:namida/controller/ffmpeg_controller.dart';
import 'package:namida/core/constants.dart';
import 'package:namida/core/extensions.dart';
import 'package:namida/youtube/class/download_task_base.dart';
import 'package:namida/youtube/controller/youtube_history_controller.dart';
import 'package:namida/youtube/widgets/yt_thumbnail.dart';

class ThumbnailManager {
  static final ThumbnailManager inst = ThumbnailManager._internal();
  ThumbnailManager._internal();

  final _thumbnailDownloader = _YTThumbnailDownloadManager();

  static String getPathToYTImage(String? id) {
    String getPath(String prefix) => "${AppDirs.YT_THUMBNAILS}$prefix$id.png";

    final path = getPath('');
    if (File(path).existsSync()) {
      return path;
    }

    return getPath('EXT_');
  }

  File? imageUrlToCacheFile({
    required String? id,
    required String? url,
    required ThumbnailType type,
    String? symlinkId,
    bool isTemp = false,
  }) {
    final dirPrefix = isTemp ? 'temp${Platform.pathSeparator}' : '';

    final goodId = id != null && id.isNotEmpty;
    if (goodId || type == ThumbnailType.video) {
      String? filename;
      if (symlinkId != null) {
        filename = symlinkId;
      } else if (goodId) {
        filename = '$id.png';
      } else if (url != null && isTemp) {
        try {
          int? indexStart;
          final index1try = url.indexOf('/vi/shorts/');
          if (index1try > -1) {
            indexStart = index1try + 11; // '/vi/shorts/'.length
          } else {
            final index2try = url.indexOf('/vi/');
            if (index2try > -1) {
              indexStart = index2try + 4; // '/vi/'.length
            }
          }
          if (indexStart != null) {
            filename = url.substring(indexStart, indexStart + 11); // custom urls like dAdjsaB_GKL_hqdefault.jpg
          } else {
            // -- just a backup
            bool isFirstMatch = false;
            filename = url.splitLastM(
              '/',
              onMatch: (part) {
                if (isFirstMatch) return part;
                isFirstMatch = true;
                return null;
              },
            );
            if (filename != null) filename = DownloadTaskFilename.cleanupFilename(filename);
          }
        } catch (_) {}
      }
      if (filename == null || filename.isEmpty) return null;
      return File("${AppDirs.YT_THUMBNAILS}$dirPrefix$filename");
    }
    String? finalUrl = url;
    final imageUrl = finalUrl?.split(RegExp(r'i\.ytimg\.com/vi.*?/'));
    if (imageUrl != null && imageUrl.length > 1) {
      finalUrl = imageUrl.last.splitFirst('?').replaceAll('/', '_');
    } else {
      if (finalUrl != null) finalUrl = '${finalUrl.splitLast('/')}.png'; // we need the quality after the =
    }

    if (finalUrl != null) {
      finalUrl = DownloadTaskFilename.cleanupFilename(finalUrl);
      return File("${AppDirs.YT_THUMBNAILS_CHANNELS}$dirPrefix${symlinkId ?? finalUrl}");
    }

    return null;
  }

  Future<File?> extractVideoThumbnailAndSave({
    required String videoPath,
    required bool isLocal,
    required String idOrFileNameWithExt,
    required bool forceExtract,
    String? cacheDirPath,
  }) async {
    final prefix = !isLocal ? 'EXT_' : '';
    final dir = cacheDirPath ?? (isLocal ? AppDirs.THUMBNAILS : AppDirs.YT_THUMBNAILS);
    final file = File("$dir$prefix$idOrFileNameWithExt.png");
    if (forceExtract == false && file.existsSync()) return file;
    await NamidaFFMPEG.inst.extractVideoThumbnail(videoPath: videoPath, thumbnailSavePath: file.path);
    final fileExists = await file.exists();
    return fileExists ? file : null;
  }

  File? getYoutubeThumbnailFromCacheSync({
    String? id,
    String? customUrl,
    bool isTemp = false,
    required ThumbnailType type,
  }) {
    if (id == null && customUrl == null) return null;
    final file = imageUrlToCacheFile(id: id, url: customUrl, isTemp: isTemp, type: type);
    if (file != null && file.existsSync()) return file;
    return null;
  }

  Future<File?> getYoutubeThumbnailAndCache({
    String? id,
    String? customUrl,
    bool isImportantInCache = true,
    String? symlinkId,
    required ThumbnailType type,
  }) async {
    if (id == null && customUrl == null) return null;

    final isTemp = isImportantInCache ? false : true;

    final file = imageUrlToCacheFile(id: id, url: customUrl, isTemp: isTemp, type: type);
    if (file == null) return null;
    if (file.existsSync()) return file;

    if (symlinkId != null) {
      try {
        final symlinkfile = imageUrlToCacheFile(id: id, url: customUrl, symlinkId: symlinkId, isTemp: isTemp, type: type);
        if (symlinkfile != null && symlinkfile.existsSync()) {
          final targetFilePath = Link.fromUri(symlinkfile.uri).targetSync();
          final targetFile = File(targetFilePath);
          if (targetFile.existsSync()) return targetFile;
        }
      } catch (_) {}
    }

    final itemId = file.path.getFilenameWOExt;
    final downloaded = await _getYoutubeThumbnail(
      itemId: itemId,
      urls: customUrl == null ? null : [customUrl],
      isVideo: id != null,
      isImportantInCache: isImportantInCache,
      destinationFile: file,
      symlinkId: symlinkId,
      isTemp: isTemp,
      forceRequest: false,
      lowerResYTID: false,
    );

    if (downloaded != null) return downloaded;

    if (isTemp == false) {
      // return the low res if high res failed
      final filetemp = imageUrlToCacheFile(id: id, url: customUrl, isTemp: true, type: type);
      if (filetemp != null && filetemp.existsSync()) return filetemp;
    }

    return null;
  }

  Future<File?> getLowResYoutubeVideoThumbnail(String? videoId, {String? symlinkId, bool useHighQualityIfEnoughListens = true, VoidCallback? onNotFound}) async {
    if (videoId == null) return null;

    bool isTemp = true;
    if (useHighQualityIfEnoughListens) {
      final listens = YoutubeHistoryController.inst.topTracksMapListens[videoId]?.length ?? 0;
      if (listens >= 10) isTemp = false; // fetch full res if listens >= 10
    }
    final bool lowerResYTID = isTemp;

    final file = imageUrlToCacheFile(id: videoId, url: null, isTemp: isTemp, type: ThumbnailType.video);
    if (file == null) return null;
    final downloaded = await _getYoutubeThumbnail(
      itemId: videoId,
      urls: null,
      isVideo: true,
      isImportantInCache: false,
      destinationFile: file,
      symlinkId: symlinkId,
      isTemp: isTemp,
      forceRequest: false,
      lowerResYTID: lowerResYTID,
    );

    return downloaded;
  }

  void closeThumbnailClients(String itemId, bool isTemp) {
    _thumbnailDownloader.stopDownload(id: itemId, isTemp: isTemp);
  }

  Future<File?> _getYoutubeThumbnail({
    required String itemId,
    required List<String>? urls,
    required bool isVideo,
    required bool lowerResYTID,
    required bool isTemp,
    required bool forceRequest,
    required bool isImportantInCache,
    required File destinationFile,
    required String? symlinkId,
  }) async {
    final activeRequest = _thumbnailDownloader.resultForId(itemId, isTemp);
    if (activeRequest != null) return activeRequest;

    final links = <String>[];
    if (urls != null) links.addAll(urls);
    if (isVideo) {
      final yth = lowerResYTID ? YoutiPieVideoThumbnail.mixLow(itemId) : YoutiPieVideoThumbnail.mix(itemId);
      links.addAll(yth);
    }
    if (links.isEmpty) return null;

    return _thumbnailDownloader.download(
      urls: links,
      id: itemId,
      forceRequest: forceRequest,
      isImportantInCache: isImportantInCache,
      destinationFile: destinationFile,
      symlinkId: symlinkId,
      isTemp: isTemp,
    );
  }
}

class _VideoIdAndTemp {
  final String videoId;
  final bool isTemp;

  const _VideoIdAndTemp({
    required this.videoId,
    required this.isTemp,
  });

  @override
  bool operator ==(covariant _VideoIdAndTemp other) {
    if (identical(this, other)) return true;
    return other.videoId == videoId && other.isTemp == isTemp;
  }

  @override
  int get hashCode => videoId.hashCode ^ isTemp.hashCode;
}

class _YTThumbnailDownloadManager with PortsProvider<SendPort> {
  final _downloadCompleters = <_VideoIdAndTemp, Completer<File?>?>{}; // item id
  final _requestsCountForId = <String, int>{}; // item id
  final _shouldRetry = <String, bool>{}; // item id
  final _notFoundThumbnails = <String, bool?>{}; // item id

  Future<File?>? resultForId(String id, bool temp) => _downloadCompleters[_VideoIdAndTemp(videoId: id, isTemp: temp)]?.future;

  Future<File?> download({
    required List<String> urls,
    required String id,
    bool forceRequest = false,
    required bool isTemp,
    required bool isImportantInCache,
    required File destinationFile,
    required String? symlinkId,
  }) async {
    final mapKey = _VideoIdAndTemp(videoId: id, isTemp: isTemp);
    if (_notFoundThumbnails[id] == true) return null;

    _requestsCountForId.update(id, (value) => value + 1, ifAbsent: () => 1);

    if (forceRequest == false && _downloadCompleters[mapKey] != null) {
      final res = await _downloadCompleters[mapKey]!.future;
      _requestsCountForId.update(id, (value) => value - 1, ifAbsent: () => 0);
      if (res != null || _shouldRetry[id] != true) {
        return res;
      }
    }
    _downloadCompleters[mapKey]?.completeIfWasnt(null);
    _downloadCompleters[mapKey] = Completer<File?>();

    final p = {
      'urls': urls,
      'id': id,
      'forceRequest': forceRequest,
      'isImportantInCache': isImportantInCache,
      'isTemp': isTemp,
      'destinationFile': destinationFile,
      'symlinkId': symlinkId,
    };
    if (!isInitialized) await initialize();
    await sendPort(p);
    final res = await _downloadCompleters[mapKey]?.future;

    _requestsCountForId.update(id, (value) => value - 1, ifAbsent: () => 0);
    return res;
  }

  Future<void> stopDownload({required String id, required bool isTemp}) async {
    final otherActiveRequests = _requestsCountForId[id];
    if (otherActiveRequests == null || otherActiveRequests <= 1) {
      // -- only close if active requests only 1
      _onFileFinish(id, null, null, true, isTemp);
      final p = {'id': id, 'stop': true};
      await sendPort(p);
    }
  }

  static Future<void> _prepareDownloadResources(SendPort sendPort) async {
    final recievePort = ReceivePort();
    sendPort.send(recievePort.sendPort);

    final httpManager = HttpMultiRequestManager();
    final requesters = <String, Map<String, HttpClientWrapper>?>{}; // itemId: {urlPath: HttpClientWrapper}

    const bool deleteOldExtracted = true;
    final sep = Platform.pathSeparator;

    void updateLastAccessed(File file) async {
      try {
        await file.setLastAccessed(DateTime.now());
      } catch (_) {}
    }

    Future<void> onThumbRequest(Map p) async {
      final stop = p['stop'] as bool?;
      final id = p['id'] as String;

      if (stop == true) {
        final requestersForId = requesters[id]?.values;
        if (requestersForId != null) {
          for (final requester in requestersForId) {
            requester.close();
          }
          requesters[id] = null;
        }
      } else {
        final urls = p['urls'] as List<String>;
        final forceRequest = p['forceRequest'] as bool? ?? false;
        final isImportantInCache = p['isImportantInCache'] as bool? ?? false;
        final isTemp = p['isTemp'] as bool? ?? false;
        final destinationFile = p['destinationFile'] as File;
        final symlinkId = p['symlinkId'] as String?;

        if (forceRequest == false && destinationFile.existsSync()) {
          final res = _YTThumbnailDownloadResult(
            url: null,
            urlPath: null,
            itemId: id,
            file: destinationFile,
            isTempFile: isTemp,
            aborted: false,
            notfound: false,
            isTemp: isTemp,
          );
          if (isImportantInCache) updateLastAccessed(destinationFile);
          return sendPort.send(res);
        }

        requesters[id] ??= {};
        bool? notfound;
        _YTThumbnailDownloadResult? downloadedRes;
        final destinationFileTemp = File("${destinationFile.path}.temp");
        destinationFileTemp.createSync(recursive: true);
        final fileStream = destinationFileTemp.openWrite(mode: FileMode.writeOnly);

        Future<void> diposeIdRequestResources() async {
          if (requesters[id] != null) {
            for (final r in requesters[id]!.values) {
              r.close();
            }
            requesters[id] = null;
          }
          try {
            await fileStream.flush();
            await fileStream.close(); // closing file.
          } catch (_) {}
          destinationFileTemp.delete().catchError((_) => File(''));
        }

        for (final url in urls) {
          final urlPath = url.substring(url.lastIndexOf('/') + 1);
          requesters[id]?[urlPath] = HttpClientWrapper();

          downloadedRes = await httpManager.executeQueued(() async {
            final requester = requesters[id]?[urlPath];

            if (requester == null || requester.isClosed) {
              // -- client closed, return true to break the loop
              final res = _YTThumbnailDownloadResult(
                url: url,
                urlPath: urlPath,
                itemId: id,
                file: destinationFile,
                isTempFile: isTemp,
                aborted: true,
                notfound: null,
                isTemp: isTemp,
              );
              return res;
            }

            try {
              final response = await requester.getUrl(Uri.parse(url));
              notfound = response.statusCode == 404;
              if (notfound == true) throw Exception('not found'); // as if request failed.

              File? newFile;

              final downloadStream = response.asBroadcastStream();
              await fileStream.addStream(downloadStream); // this should throw if connection closed unexpectedly
              await fileStream.flush();
              await fileStream.close(); // this is already done by diposeIdRequestResources() but we do here bcz renaming can require that no processes are using the file

              newFile = destinationFileTemp.renameSync(destinationFile.path); // rename .temp
              if (symlinkId != null) {
                Link("${newFile.parent.path}$sep$symlinkId").create(newFile.path).catchError((_) => Link(''));
              }
              if (deleteOldExtracted) {
                File("${destinationFile.parent.path}${sep}EXT_${destinationFile.path.getFilename}").delete().catchError((_) => File(''));
              }

              final res = _YTThumbnailDownloadResult(
                url: url,
                urlPath: urlPath,
                itemId: id,
                file: newFile,
                isTempFile: isTemp,
                aborted: false,
                notfound: false,
                isTemp: isTemp,
              );
              return res;
            } catch (_) {
              return null;
            }
          });

          if (downloadedRes != null) break; // break loop
        }

        diposeIdRequestResources();

        downloadedRes ??= _YTThumbnailDownloadResult(
          url: null,
          urlPath: null,
          itemId: id,
          file: null,
          isTempFile: isTemp,
          aborted: true,
          notfound: notfound,
          isTemp: isTemp,
        );

        sendPort.send(downloadedRes);
      }
    }

    StreamSubscription? streamSub;
    streamSub = recievePort.listen((p) {
      if (PortsProvider.isDisposeMessage(p)) {
        for (final requestersMap in requesters.values) {
          final requestersToClose = requestersMap?.values;
          if (requestersToClose != null) {
            for (final requester in requestersToClose) {
              requester.close();
            }
          }
        }
        requesters.clear();
        httpManager.closeClients();
        recievePort.close();
        streamSub?.cancel();
        return;
      } else {
        onThumbRequest(p);
      }
    });

    sendPort.send(null); // prepared
  }

  @override
  void onResult(dynamic result) {
    if (result is _YTThumbnailDownloadResult) {
      _onFileFinish(result.itemId, result.file, result.notfound, result.aborted, result.isTemp);
    }
  }

  @override
  IsolateFunctionReturnBuild<SendPort> isolateFunction(SendPort port) {
    return IsolateFunctionReturnBuild(_prepareDownloadResources, port);
  }

  void _onFileFinish(String itemId, File? downloadedFile, bool? notfound, bool aborted, bool isTemp) {
    if (notfound != null) _notFoundThumbnails[itemId] = notfound;
    _shouldRetry[itemId] = aborted;
    final mapKey = _VideoIdAndTemp(videoId: itemId, isTemp: isTemp);
    _downloadCompleters[mapKey]?.completeIfWasnt(downloadedFile);
  }
}

class _YTThumbnailDownloadResult {
  final String? url;
  final String? urlPath;
  final String itemId;
  final File? file;
  final bool isTempFile;
  final bool aborted;
  final bool? notfound;
  final bool isTemp;

  const _YTThumbnailDownloadResult({
    required this.url,
    required this.urlPath,
    required this.itemId,
    required this.file,
    required this.isTempFile,
    required this.aborted,
    required this.notfound,
    required this.isTemp,
  });
}
