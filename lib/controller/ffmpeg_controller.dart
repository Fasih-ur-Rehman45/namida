import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:namida/class/file_parts.dart';
import 'package:namida/class/media_info.dart';
import 'package:namida/class/track.dart';
import 'package:namida/controller/indexer_controller.dart';
import 'package:namida/controller/thumbnail_manager.dart';
import 'package:namida/core/constants.dart';
import 'package:namida/core/extensions.dart';
import 'package:namida/core/utils.dart';
import 'package:namida/main.dart';
import 'package:namida/youtube/controller/youtube_info_controller.dart';
import 'package:namida/youtube/widgets/yt_thumbnail.dart';

import 'platform/ffmpeg_executer/ffmpeg_executer.dart';

class NamidaFFMPEG {
  static NamidaFFMPEG get inst => _instance;
  static final NamidaFFMPEG _instance = NamidaFFMPEG._internal();
  NamidaFFMPEG._internal() {
    _executer.init();
  }

  final _executer = FFMPEGExecuter.platform();

  final currentOperations = <OperationType, Rx<OperationProgress>>{
    OperationType.imageCompress: OperationProgress().obs,
    OperationType.ytdlpThumbnailFix: OperationProgress().obs,
  };

  Future<MediaInfo?> extractMetadata(String path) async {
    final output = await _executer.ffprobeExecute(['-show_streams', '-show_format', '-show_entries', 'stream_tags:format_tags', '-of', 'json', path]);
    if (output != null && output != '') {
      try {
        final decoded = jsonDecode(output);
        decoded["PATH"] = path;
        final mi = MediaInfo.fromMap(decoded);
        final formatGood = (decoded['format'] as Map?)?.isNotEmpty ?? false;
        final tagsGood = (decoded['format']?['tags'] as Map?)?.isNotEmpty ?? false;
        if (formatGood && tagsGood) return mi;
      } catch (_) {}
    }

    final map = await _executer.getMediaInformation(path);
    if (map != null) {
      map["PATH"] = path;
      final miBackup = MediaInfo.fromMap(map);
      final format = miBackup.format;
      Map? tags = map['tags'];
      if (tags == null) {
        try {
          final mainTags = (map['streams'] as List?)?.firstWhereEff((e) {
            final t = e['tags'];
            return t is Map && t.isNotEmpty;
          });
          tags = mainTags?['tags'];
        } catch (_) {}
      }
      final mi = MediaInfo(
        path: path,
        streams: miBackup.streams,
        format: MIFormat(
          bitRate: format?.bitRate ?? map['bit_rate'] ?? map['bitrate'],
          duration: format?.duration ?? (map['duration'] as String?).getDuration(),
          filename: format?.filename ?? map['filename'],
          formatName: format?.formatName ?? map['format_name'],
          nbPrograms: format?.nbPrograms,
          nbStreams: format?.nbStreams,
          probeScore: format?.probeScore,
          size: format?.size ?? (map['size'] as String?).getIntValue(),
          startTime: format?.startTime ?? map['start_time'],
          tags: tags == null ? null : MIFormatTags.fromMap(tags),
        ),
      );
      return mi;
    }

    return null;
  }

  Future<bool> editMetadata({
    required String path,
    MIFormatTags? oldTags,
    required Map<String, String?> tagsMap,
    bool keepFileStats = true,
  }) async {
    final originalFile = File(path);
    final originalStats = keepFileStats ? await originalFile.stat() : null;
    final tempFile = await originalFile.copy(FileParts.joinPath(AppDirs.INTERNAL_STORAGE, ".temp_${path.hashCode}"));

    // if (tagsMap[FFMPEGTagField.trackNumber] != null || tagsMap[FFMPEGTagField.discNumber] != null) {
    //   oldTags ??= await extractMetadata(path).then((value) => value?.format?.tags);
    //   void plsAddDT(String valInMap, (String, String?)? trackOrDisc) {
    //     if (trackOrDisc != null) {
    //       final trackN = trackOrDisc.$1;
    //       final trackT = trackOrDisc.$2;
    //       if (trackT == null && trackN != "0") {
    //         tagsMapToEditConverted[valInMap] = trackN;
    //       } else if (trackT != null) {
    //         tagsMapToEditConverted[valInMap] = "${trackOrDisc.$1}/${trackOrDisc.$2}";
    //       }
    //     }
    //   }

    //   final trackNT = _trackAndDiscSplitter(oldTags?.track);
    //   final discNT = _trackAndDiscSplitter(oldTags?.disc);
    //   plsAddDT("track", (tagsMapToEditConverted["track"] ?? trackNT?.$1 ?? "0", trackNT?.$2));
    //   plsAddDT("disc", (tagsMapToEditConverted["disc"] ?? discNT?.$1 ?? "0", trackNT?.$2));
    // }

    final params = [
      '-i',
      tempFile.path,
    ];
    for (final e in tagsMap.entries) {
      final val = e.value;
      if (val != null) {
        final valueCleaned = val.replaceAll('"', r'\"');
        params.add('-metadata');
        params.add('${e.key}=$valueCleaned');
      }
    }
    params.addAll([
      '-id3v2_version',
      '3',
      '-write_id3v2',
      '1',
      '-c',
      'copy',
      '-y',
      path,
    ]);

    final didExecute = await _executer.ffmpegExecute(params);
    // -- restoring original stats.
    if (originalStats != null) {
      await setFileStats(originalFile, originalStats);
    }
    await tempFile.tryDeleting();
    return didExecute;
  }

  Future<File?> extractAudioThumbnail({
    required String audioPath,
    required String thumbnailSavePath,
    bool compress = false,
    bool forceReExtract = false,
  }) async {
    if (!forceReExtract && await File(thumbnailSavePath).exists()) {
      return File(thumbnailSavePath);
    }

    final codecParams = compress ? ['-filter:v', 'scale=-2:250', '-an'] : ['-c', 'copy'];
    final didSuccess = await _executer.ffmpegExecute(['-i', audioPath, '-map', '0:v', '-map', '-0:V', ...codecParams, '-y', thumbnailSavePath]);
    if (didSuccess) {
      return File(thumbnailSavePath);
    } else {
      final didSuccess = await _executer.ffmpegExecute(['-i', audioPath, '-an', '-c:v', 'copy', '-y', thumbnailSavePath]);
      return didSuccess ? File(thumbnailSavePath) : null;
    }
  }

  Future<bool> editAudioThumbnail({
    required String audioPath,
    required String thumbnailPath,
    bool keepOriginalFileStats = true,
  }) async {
    final audioFile = File(audioPath);
    final originalStats = keepOriginalFileStats ? await audioFile.stat() : null;

    String ext = 'm4a';
    try {
      ext = audioPath.getExtension;
    } catch (_) {}

    final isVideoFile = NamidaFileExtensionsWrapper.video.isExtensionValid(ext);
    final cacheFile = FileParts.join(AppDirs.APP_CACHE, "${audioPath.hashCode}.$ext");
    final didSuccess = await _executer.ffmpegExecute([
      '-i',
      audioPath,
      '-i',
      thumbnailPath,
      '-map',
      '0:a?',
      if (isVideoFile) ...[
        '-map',
        '0:v:0?',
      ],
      '-map',
      '1',
      '-codec',
      'copy',
      isVideoFile ? '-disposition:v:1' : '-disposition:v:0',
      'attached_pic',
      '-y',
      cacheFile.path,
    ]);
    bool canSafelyMoveBack = false;
    try {
      canSafelyMoveBack = didSuccess && await cacheFile.exists() && await cacheFile.length() > 0;
    } catch (_) {}
    if (canSafelyMoveBack) {
      // only move output file back in case of success.
      await cacheFile.copy(audioPath);

      if (originalStats != null) {
        await setFileStats(audioFile, originalStats);
      }
    }

    cacheFile.deleteIfExists();
    return canSafelyMoveBack;
  }

  Future<bool> setFileStats(File file, FileStat stats) async {
    try {
      await file.setLastAccessed(stats.accessed);
      await file.setLastModified(stats.modified);
      return true;
    } catch (e) {
      printy(e, isError: true);
      return false;
    }
  }

  Future<bool> compressImage({
    required String path,
    required String saveDir,
    bool keepOriginalFileStats = true,
    int percentage = 50,
  }) async {
    assert(percentage >= 0 && percentage <= 100);

    final toQSC = (percentage / 3.2).round();

    final imageFile = File(path);
    final originalStats = keepOriginalFileStats ? await imageFile.stat() : null;
    final newFilePath = FileParts.joinPath(saveDir, "${path.getFilenameWOExt}.jpg");
    final didSuccess = await _executer.ffmpegExecute(['-i', path, '-qscale:v', '$toQSC', '-y', newFilePath]);

    if (originalStats != null) {
      await setFileStats(File(newFilePath), originalStats);
    }

    return didSuccess;
  }

  Future<void> compressImageDirectories({
    required Iterable<String> dirs,
    required int compressionPerc,
    required bool keepOriginalFileStats,
    bool recursive = true,
  }) async {
    if (!await requestManageStoragePermission()) return;

    final dir = await Directory(AppDirs.COMPRESSED_IMAGES).create();

    final dirFiles = <FileSystemEntity>[];

    for (final d in dirs) {
      dirFiles.addAll(await Directory(d).listAllIsolate(recursive: recursive));
    }

    dirFiles.retainWhere((element) => element is File);
    currentOperations[OperationType.imageCompress]!.value = OperationProgress(); // resetting

    final totalFiles = dirFiles.length;
    int currentProgress = 0;
    int currentFailed = 0;

    for (int i = 0; i < totalFiles; i++) {
      var f = dirFiles[i];
      final didUpdate = await compressImage(
        path: f.path,
        saveDir: dir.path,
        percentage: compressionPerc,
        keepOriginalFileStats: keepOriginalFileStats,
      );
      if (!didUpdate) currentFailed++;
      currentProgress++;
      currentOperations[OperationType.imageCompress]!.value = OperationProgress(
        totalFiles: totalFiles,
        progress: currentProgress,
        currentFilePath: f.path,
        totalFailed: currentFailed,
      );
    }
    currentOperations[OperationType.imageCompress]!.value.currentFilePath = null;
  }

  Future<void> fixYTDLPBigThumbnailSize({required List<String> directoriesPaths, bool recursive = true}) async {
    if (!await requestManageStoragePermission()) return;

    final allFiles = <FileSystemEntity>[];
    int remainingDirsLength = directoriesPaths.length;
    final completer = Completer<void>();
    directoriesPaths.loop((e) {
      Directory(e).listAllIsolate(recursive: recursive).then(
        (value) {
          allFiles.addAll(value);
          remainingDirsLength--;
          if (remainingDirsLength == 0) completer.complete();
        },
      );
    });
    await completer.future;
    final totalFilesLength = allFiles.length;

    int currentProgress = 0;
    int currentFailed = 0;

    currentOperations[OperationType.ytdlpThumbnailFix]!.value = OperationProgress(); // resetting

    for (int i = 0; i < totalFilesLength; i++) {
      var filee = allFiles[i];
      currentProgress++;
      if (filee is File) {
        final tr = Indexer.inst.allTracksMappedByPath[filee.path] ??
            await Indexer.inst.getTrackInfo(
              trackPath: filee.path,
              onMinDurTrigger: () => null,
              onMinSizeTrigger: () => null,
            );
        if (tr == null) continue;
        final videoId = tr.youtubeID;
        if (videoId.isEmpty) continue;

        File? thumbnailFile;
        bool isTempThumbnail = false;
        try {
          // -- try getting cropped version if required
          final channelName = await YoutubeInfoController.utils.getVideoChannelName(videoId);
          const topic = '- Topic';
          if (channelName != null && channelName.endsWith(topic)) {
            final thumbFilePath = FileParts.joinPath(Directory.systemTemp.path, '$videoId.png');
            final thumbFile = await YoutubeInfoController.video.fetchMusicVideoThumbnailToFile(videoId, thumbFilePath);
            if (thumbFile != null) {
              thumbnailFile = thumbFile;
              isTempThumbnail = true;
            }
          }
        } catch (_) {}

        thumbnailFile ??= await ThumbnailManager.inst.getYoutubeThumbnailAndCache(
          id: videoId,
          isImportantInCache: true,
          type: ThumbnailType.video,
        );

        if (thumbnailFile == null) {
          currentFailed++;
        } else {
          final didUpdate = await editAudioThumbnail(
            audioPath: filee.path,
            thumbnailPath: thumbnailFile.path,
          );
          if (!didUpdate) currentFailed++;

          if (isTempThumbnail) {
            thumbnailFile.tryDeleting();
          }
        }

        currentOperations[OperationType.ytdlpThumbnailFix]!.value = OperationProgress(
          totalFiles: totalFilesLength,
          progress: currentProgress,
          currentFilePath: filee.path,
          totalFailed: currentFailed,
        );
      }
    }
    currentOperations[OperationType.ytdlpThumbnailFix]!.value.currentFilePath = null;
  }

  /// * Extracts thumbnail from a given video, usually this tries to get embed thumbnail,
  ///   if failed then it will extract a frame at a given duration.
  /// * [quality] & [atDuration] will not be used in case an embed thumbnail was found
  /// * [quality] ranges on a scale of 1-31, where 1 is the best & 31 is the worst.
  /// * if [atDuration] is not specified, it will try to calculate based on video duration
  ///   (typically thumbnail at duration of 10% of the original duration),
  ///   if failed then a thumbnail at Duration.zero will be extracted.
  Future<bool> extractVideoThumbnail({
    required String videoPath,
    required String thumbnailSavePath,
    int quality = 1,
    Duration? atDuration,
  }) async {
    assert(quality >= 1 && quality <= 31, 'quality ranges only between 1 & 31');

    final didExecute = await _executer.ffmpegExecute(['-i', videoPath, '-map', '0:v', '-map', '-0:V', '-c', 'copy', '-y', thumbnailSavePath]);
    if (didExecute) return true;

    int? atMillisecond = atDuration?.inMilliseconds;
    if (atMillisecond == null) {
      final duration = await getMediaDuration(videoPath);
      if (duration != null) atMillisecond = duration.inMilliseconds;
    }

    final totalSeconds = (atMillisecond ?? 0) / 1000; // converting to decimal seconds.
    final extractFromSecond = totalSeconds * 0.1; // thumbnail at 10% of duration.
    return await _executer.ffmpegExecute(['-ss', '$extractFromSecond', '-i', videoPath, '-frames:v', '1', '-q:v', '$quality', '-y', thumbnailSavePath]);
  }

  Future<Duration?> getMediaDuration(String path) async {
    final output = await _executer.ffprobeExecute(['-show_entries', 'format=duration', '-of', 'default=noprint_wrappers=1:nokey=1', path]);
    final duration = output == null ? null : double.tryParse(output);
    return duration == null ? null : Duration(microseconds: (duration * 1000 * 1000).floor());
  }

  // Future<List<String>> getTrackAndDiscField(String path) async {
  //   await _ffprobeExecute('-v quiet -loglevel error -show_entries format_tags=track,disc -of default=noprint_wrappers=1:nokey=1 "$path"');
  //   final output = await _ffmpegConfig.getLastCommandOutput();
  //   return output.split('\n');
  // }

  Future<bool> mergeAudioAndVideo({
    required String videoPath,
    required String audioPath,
    required String outputPath,
    bool override = true,
  }) async {
    return await _executer.ffmpegExecute([
      '-i',
      videoPath,
      '-i',
      audioPath,
      '-map',
      '0:v:0',
      '-map',
      '1:a:0', // map to ensure audio only is merged (in case file extension was mp4 etc)
      '-c',
      'copy',
      if (override) '-y',
      outputPath,
    ]);
  }

  /// First field is track/disc number, can be 0 or more.
  ///
  /// Second is track/disc total, can exist or can be null.
  ///
  /// Returns null if splitting failed or [discOrTrack] == null.
  // (String, String?)? _trackAndDiscSplitter(String? discOrTrack) {
  //   if (discOrTrack != null) {
  //     final discNT = discOrTrack.split('/');
  //     if (discNT.length == 2) {
  //       // -- track/disc total exist
  //       final discN = discNT.first; // might be 0 or more
  //       final discT = discNT.last; // always more than 0
  //       return (discN, discT);
  //     } else if (discNT.length == 1) {
  //       // -- only track/disc number is provided
  //       final discN = discNT.first;
  //       return (discN, null);
  //     }
  //   }
  //   return null;
  // }
}

class FFMPEGTagField {
  static const String title = 'title';
  static const String artist = 'artist';
  static const String album = 'album';
  static const String albumArtist = 'album_artist';
  static const String composer = 'composer';
  static const String synopsis = 'synopsis';
  static const String description = 'description';
  static const String genre = 'genre';
  static const String year = 'date';
  static const String trackNumber = 'track';
  static const String discNumber = 'disc';
  static const String trackTotal = 'TRACKTOTAL';
  static const String discTotal = 'DISCTOTAL';
  static const String comment = 'comment';
  static const String lyrics = 'lyrics';
  static const String remixer = 'REMIXER';
  static const String lyricist = 'LYRICIST';
  static const String language = 'LANGUAGE';
  static const String recordLabel = 'LABEL';
  static const String country = 'Country';

  // -- NOT WORKING
  static const String mood = 'mood';
  static const String rating = 'rating';
  static const String tags = 'tags';

  static const List<String> values = <String>[
    title,
    artist,
    album,
    albumArtist,
    composer,
    synopsis,
    description,
    genre,
    mood,
    year,
    trackNumber,
    discNumber,
    trackTotal,
    discTotal,
    comment,
    lyrics,
    remixer,
    lyricist,
    language,
    recordLabel,
    country,
    rating,
    tags,
  ];
}

class OperationProgress {
  final int totalFiles;
  final int progress;
  String? currentFilePath;
  final int totalFailed;

  OperationProgress({
    this.totalFiles = 0,
    this.progress = 0,
    this.currentFilePath,
    this.totalFailed = 0,
  });
}

enum OperationType {
  imageCompress,
  ytdlpThumbnailFix,
}
