import 'package:flutter/widgets.dart';

import 'package:namida/controller/navigator_controller.dart';
import 'package:namida/core/utils.dart';

class BenchmarkExecutionTime {
  final currentOperation = ''.obs;

  final timesLookup = <String, int>{};
  // final _sw = Stopwatch();

  static int _getTime() => DateTime.now().microsecondsSinceEpoch;

  late int _initial;
  late int _previous;
  late int _end;

  void start() {
    _initial = _getTime();
    _previous = _initial;
    // _sw.start();
  }

  void mark(String key) {
    final next = _getTime();
    timesLookup[key] = next - _previous;
    _previous = next;
    currentOperation.value = key;
    // _sw.reset();
  }

  void finish() {
    _end = _getTime();
    currentOperation.value = '';
    // _sw.stop();
  }

  String getResults() {
    final total = timesLookup.values.reduce((value, element) => value + element);
    final total2 = _end - _initial;
    final entriesText = timesLookup.entries
        .where((e) => e.value / 1000 > 5)
        .map(
          // (e) => "${e.value ~/ 1000}ms | ${e.value / total}% | ${e.key}",
          (e) => "${e.value ~/ 1000}ms | ${e.key}",
        )
        .join('\n');
    final totalText = 'TOTAL: ${total / 1000}ms | ${total / 1000 / 1000} seconds';
    final totalText2 = 'TOTAL2: ${total2 / 1000}ms | ${total2 / 1000 / 1000} seconds';
    final totalTextAll = totalText2 == totalText ? totalText : '$totalText\n$totalText2';
    return '$entriesText\n$totalTextAll';
  }

  void showResultsSheet() {
    NamidaNavigator.inst.showSheet(
      builder: (context, bottomPadding, maxWidth, maxHeight) => Padding(
        padding: EdgeInsetsGeometry.all(32.0),
        child: Text(getResults()),
      ),
    );
  }
}
