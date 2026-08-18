// Host-side driver for `flutter drive --target integration_test/app_perf_test.dart`.
//
// app_perf_test.dart stores its raw timeline under reportData['dashboard_scroll']
// via `binding.traceAction(..., reportKey: 'dashboard_scroll')`. Only a driver
// can read reportData (over `driver.requestData`) — which is the whole reason
// the frame timeline cannot be produced by `flutter test`.
//
// Writes build/qa/dashboard_scroll.timeline.json (raw, large, keep for triage)
// and build/qa/dashboard_scroll.timeline_summary.json (parsed by tool/qa_metrics.py).

import 'package:flutter_driver/flutter_driver.dart';
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() async {
  await integrationDriver(
    responseDataCallback: (data) async {
      if (data == null) return;
      final timeline = Timeline.fromJson(
        data['dashboard_scroll']! as Map<String, dynamic>,
      );
      await TimelineSummary.summarize(timeline).writeTimelineToFile(
        'dashboard_scroll',
        destinationDirectory: 'build/qa',
        pretty: true,
      );
    },
  );
}
