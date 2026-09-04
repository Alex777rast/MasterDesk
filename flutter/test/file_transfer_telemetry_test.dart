import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:uuid/uuid.dart';

void main() {
  test('legacy average uses transferred bytes and exact elapsed milliseconds',
      () {
    final job = JobProgress()
      ..startedAtMs = 1000
      ..completedAtMs = 9000
      ..finishedSize = 1000000000
      ..totalSize = 1000000000;

    expect(job.elapsedMs, 8000);
    expect(job.averageSpeed * 8 / 1000000, 1000);
    expect(job.percent, 1);
  });

  test('progress is capped and ETA speed is smoothed', () {
    final job = JobProgress()
      ..finishedSize = 120
      ..totalSize = 100;

    job.recordSpeedSample(100);
    job.recordSpeedSample(200);

    expect(job.percent, 1);
    expect(job.smoothedSpeed, 125);
  });

  test('Explorer clipboard telemetry creates and completes a visible job',
      () async {
    final controller = JobController(
      () => UuidValue('00000000-0000-4000-8000-000000000001'),
      () => null,
    );
    final stats = <String, dynamic>{
      'transfer_id': 'explorer-test',
      'mode': 'FIXED 8x',
      'phase': 'transferring',
      'active_workers': 8,
      'busy_workers': 8,
      'open_connections': 8,
      'target_workers': 8,
      'max_workers': 8,
      'total_speed': 1000000,
      'file_name': 'large.bin',
      'file_size': 1048576,
      'file_count': 1,
      'bytes_transferred': 524288,
      'workers': <dynamic>[],
    };

    controller.tryUpdateJobProgress({
      'id': '-1000001',
      'file_num': '0',
      'speed': '1000000',
      'finished_size': '524288',
      'parallel_stats': jsonEncode(stats),
    });

    expect(controller.jobTable, hasLength(1));
    final job = controller.jobTable.single;
    expect(job.isExplorerClipboardTransfer, isTrue);
    expect(job.jobName, 'large.bin');
    expect(job.showDiagnostics, isTrue);
    expect(job.parallelStats?.targetWorkers, 8);

    await controller.jobDone({
      'id': '-1000001',
      'file_num': '0',
      'speed': '0',
    });
    expect(job.state, JobState.done);
    expect(job.percent, 1);
  });
}
