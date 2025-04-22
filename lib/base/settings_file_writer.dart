import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:namida/core/constants.dart';
import 'package:namida/core/extensions.dart';

mixin SettingsFileWriter {
  String get filePath;
  Object get jsonToWrite;
  Duration get delay => const Duration(seconds: 2);

  void applyKuruSettings();

  @protected
  dynamic prepareSettingsFile_() {
    final file = File(filePath);

    if (isKuru) applyKuruSettings();

    if (!file.existsSync()) {
      return null;
    }
    try {
      return file.readAsJsonSync();
    } catch (e) {
      printy(e, isError: true);
    }
  }

  @protected
  Future<void> writeToStorage() async {
    if (_canWriteSettings) {
      _canWriteSettings = false;
      _writeToStorageRaw();
    } else {
      _canWriteSettings = false;
      _writeTimer ??= Timer(delay, () {
        _writeToStorageRaw();
        _canWriteSettings = true;
        _writeTimer = null;
      });
    }
  }

  Future<void> _writeToStorageRaw() async {
    final path = filePath;
    try {
      await File(path).writeAsJson(jsonToWrite);
      printy("Setting file write: $path");
    } catch (e) {
      printy("Setting file write failed: ${path.getFilenameWOExt} => $e", isError: true);
    }
  }

  Timer? _writeTimer;
  bool _canWriteSettings = true;

  @protected
  Map<K, V>? getEnumMap_<K extends Enum, V extends Enum>(dynamic jsonMap, List<K> enumKeys, K defaultKey, List<V> enumValues, V defaultValue) {
    return ((jsonMap as Map?)?.map(
      (key, value) => MapEntry(enumKeys.getEnum(key) ?? defaultKey, enumValues.getEnum(value) ?? defaultValue),
    ));
  }
}
