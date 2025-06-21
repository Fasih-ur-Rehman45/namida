import 'dart:io';

import 'package:flutter/material.dart';

import 'package:namida/controller/current_color.dart';
import 'package:namida/controller/thumbnail_manager.dart';
import 'package:namida/core/constants.dart';
import 'package:namida/ui/dialogs/track_listens_dialog.dart';
import 'package:namida/youtube/controller/youtube_history_controller.dart';
import 'package:namida/youtube/widgets/yt_thumbnail.dart';
import 'package:namida/youtube/yt_utils.dart';

void showVideoListensDialog(String videoId, {List<int> datesOfListen = const [], Color? colorScheme}) async {
  showListensDialog(
    datesOfListen: datesOfListen.isNotEmpty ? datesOfListen : YoutubeHistoryController.inst.topTracksMapListens.value[videoId] ?? [],
    colorScheme: colorScheme,
    colorSchemeFunction: () async {
      final image = await ThumbnailManager.inst.getYoutubeThumbnailFromCache(id: videoId, type: ThumbnailType.video);
      if (image != null) {
        final color = await CurrentColor.inst.extractPaletteFromImage(image.path, paletteSaveDirectory: Directory(AppDirs.YT_PALETTES), useIsolate: true);
        return color?.color;
      }
      return null;
    },
    colorSchemeFunctionSync: null,
    onListenTap: (listen) => YTUtils.onYoutubeHistoryPlaylistTap(initialListen: listen),
  );
}
