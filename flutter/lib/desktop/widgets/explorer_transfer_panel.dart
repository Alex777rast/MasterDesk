import 'dart:math';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../consts.dart';
import '../../models/file_model.dart';
import '../../models/platform_model.dart';

class ExplorerTransferPanel extends StatefulWidget {
  final JobController controller;
  final VoidCallback onClose;

  const ExplorerTransferPanel({
    super.key,
    required this.controller,
    required this.onClose,
  });

  @override
  State<ExplorerTransferPanel> createState() => _ExplorerTransferPanelState();
}

class _ExplorerTransferPanelState extends State<ExplorerTransferPanel> {
  late String _mode;

  @override
  void initState() {
    super.initState();
    _mode = normalizeParallelFileTransferMode(
        bind.mainGetOptionSync(key: kOptionParallelFileTransferMode));
  }

  Future<void> _setMode(String? value) async {
    if (value == null) return;
    final mode = normalizeParallelFileTransferMode(value);
    await bind.mainSetOption(key: kOptionParallelFileTransferMode, value: mode);
    if (mounted) setState(() => _mode = mode);
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      color: Theme.of(context).scaffoldBackgroundColor,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      translate('Transfer diagnostics'),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text('${translate('Parallel streams')}: '),
                  DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _mode,
                      isDense: true,
                      items: kParallelFileTransferModes
                          .map((mode) => DropdownMenuItem(
                                value: mode,
                                child:
                                    Text(parallelFileTransferModeLabel(mode)),
                              ))
                          .toList(growable: false),
                      onChanged: _setMode,
                    ),
                  ),
                  IconButton(
                    tooltip: translate('Transfer diagnostics'),
                    visualDensity: VisualDensity.compact,
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Obx(() {
                final jobs = widget.controller.jobTable
                    .where((job) => job.isExplorerClipboardTransfer)
                    .toList(growable: false)
                  ..sort((a, b) => b.startedAtMs.compareTo(a.startedAtMs));
                if (jobs.isEmpty) {
                  return Center(
                    child: Text(
                      translate('No transfers in progress'),
                      textAlign: TextAlign.center,
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: jobs.length,
                  itemBuilder: (_, index) => _ExplorerTransferCard(
                    job: jobs[index],
                    controller: widget.controller,
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}

class _ExplorerTransferCard extends StatelessWidget {
  final JobProgress job;
  final JobController controller;

  const _ExplorerTransferCard({required this.job, required this.controller});

  String _mbps(double bytesPerSecond) =>
      '${(bytesPerSecond * 8 / 1000000).toStringAsFixed(1)} Mbps';

  String _elapsed(int milliseconds) {
    final seconds = Duration(milliseconds: milliseconds).inSeconds;
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    final remainingSeconds = seconds % 60;
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${remainingSeconds.toString().padLeft(2, '0')}';
  }

  String _state(String value) {
    switch (value.toLowerCase()) {
      case 'connecting':
        return translate('Connecting');
      case 'transferring':
        return translate('Transferring');
      case 'awaiting_ack':
        return translate('Awaiting confirmation');
      case 'complete':
        return translate('Completed');
      case 'error':
        return translate('Error');
      case 'preparing':
        return translate('Preparing');
      case 'legacy fallback':
        return translate('Legacy fallback');
      default:
        return translate('Waiting');
    }
  }

  Future<void> _remove() async {
    if (job.state == JobState.inProgress) {
      await controller.cancelJob(job.id);
    }
    controller.jobTable.removeWhere((item) => item.id == job.id);
  }

  @override
  Widget build(BuildContext context) {
    final stats = job.parallelStats;
    final currentSpeed = stats?.totalSpeed ?? job.speed;
    final averageSpeed = stats?.averageSpeed ?? job.averageSpeed;
    final peakSpeed = stats?.peakSpeed ?? job.peakSpeed;
    final elapsedMs = stats?.elapsedMs ?? job.elapsedMs;
    final totalBytes =
        stats != null && stats.fileSize > 0 ? stats.fileSize : job.totalSize;
    final transferredBytes =
        min(totalBytes, max(0, stats?.bytesTransferred ?? job.finishedSize));
    final remainingBytes = max(0, totalBytes - transferredBytes);
    final etaSpeed = job.smoothedSpeed > 0
        ? job.smoothedSpeed
        : averageSpeed > 0
            ? averageSpeed
            : currentSpeed;
    final etaMs = etaSpeed > 0 ? (remainingBytes * 1000 / etaSpeed).round() : 0;
    final workers = stats?.workers ?? const <ParallelWorkerStats>[];
    final targetWorkers = stats?.targetWorkers ?? 1;
    final copiedFiles = max(1, stats?.fileCount ?? job.fileCount);
    final textStyle = TextStyle(
        fontSize: 12, color: Theme.of(context).tabBarTheme.labelColor);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Tooltip(
                    message: job.jobName,
                    child: Text(job.jobName,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
                IconButton(
                  tooltip: translate('Delete'),
                  visualDensity: VisualDensity.compact,
                  onPressed: _remove,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Text(job.getStatus(), style: textStyle),
            const SizedBox(height: 6),
            LinearProgressIndicator(value: job.percent, minHeight: 12),
            Center(child: Text(job.percentText)),
            const SizedBox(height: 8),
            Text(
              '${stats?.mode ?? translate('Legacy mode')} | '
              '${translate('Parallel streams')} '
              '${stats?.busyWorkers ?? 0}/$targetWorkers | '
              '${_state(stats?.phase ?? 'transferring')}',
              style: textStyle.copyWith(fontWeight: FontWeight.w600),
            ),
            Text(
                '${translate('Transferred')}: ${readableFileSize(transferredBytes.toDouble())} / ${readableFileSize(totalBytes.toDouble())}',
                style: textStyle),
            Text(
                '${translate('Remaining')}: ${readableFileSize(remainingBytes.toDouble())}',
                style: textStyle),
            Text('${translate('Current speed')}: ${_mbps(currentSpeed)}',
                style: textStyle),
            Text('${translate('Average speed')}: ${_mbps(averageSpeed)}',
                style: textStyle),
            Text('${translate('Peak speed')}: ${_mbps(peakSpeed)}',
                style: textStyle),
            Text('${translate('Elapsed')}: ${_elapsed(elapsedMs)}',
                style: textStyle),
            Text(
                '${translate('Estimated time remaining')}: ${remainingBytes == 0 ? '00:00:00' : etaSpeed > 0 ? _elapsed(etaMs) : '--:--:--'}',
                style: textStyle),
            if (stats != null) ...[
              Text(
                  '${translate('Configured workers')}: ${stats.maxWorkers}  ${translate('Target workers')}: ${stats.targetWorkers}',
                  style: textStyle),
              Text(
                  '${translate('Open connections')}: ${stats.openConnections}  ${translate('Active workers')}: ${stats.activeWorkers}  ${translate('Busy workers')}: ${stats.busyWorkers}',
                  style: textStyle),
              Text(
                  '${translate('Queued jobs')}: ${stats.queuedJobs}  ${translate('Completed jobs')}: ${stats.completedJobs}',
                  style: textStyle),
              if (stats.scaleHistory.isNotEmpty)
                Text(
                    '${translate('Auto scaling')}: ${stats.scaleHistory.join(' -> ')}',
                    style: textStyle),
            ],
            if (workers.isNotEmpty) const SizedBox(height: 6),
            ...workers.map((worker) {
              final rangeSize = max(1, worker.rangeEnd - worker.rangeStart);
              final progress =
                  (worker.bytesTransferred / rangeSize).clamp(0.0, 1.0);
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        '#${worker.workerId}  ${_mbps(worker.bytesPerSecond)}  ${_state(worker.state)}  ${translate('Jobs')}: ${worker.jobsCompleted}  ${translate('Chunks')}: ${worker.chunksCompleted}',
                        style: textStyle),
                    LinearProgressIndicator(value: progress, minHeight: 3),
                  ],
                ),
              );
            }),
            if (job.speedHistory.isNotEmpty)
              SizedBox(
                height: 34,
                width: double.infinity,
                child: CustomPaint(
                  painter: _ExplorerTransferSpeedSparklinePainter(
                    List<double>.from(job.speedHistory),
                    Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            if (job.state == JobState.done)
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(translate('Completed'),
                      style: textStyle.copyWith(fontWeight: FontWeight.w600)),
                  Text(
                      copiedFiles > 1
                          ? '${translate('Files copied')}: $copiedFiles / ${readableFileSize(totalBytes.toDouble())}'
                          : '${translate('Copied')}: ${readableFileSize(totalBytes.toDouble())}',
                      style: textStyle),
                  Text('${translate('Time')}: ${_elapsed(elapsedMs)}',
                      style: textStyle),
                  Text('${translate('Average speed')}: ${_mbps(averageSpeed)}',
                      style: textStyle),
                  Text('${translate('Peak speed')}: ${_mbps(peakSpeed)}',
                      style: textStyle),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _ExplorerTransferSpeedSparklinePainter extends CustomPainter {
  final List<double> samples;
  final Color color;

  _ExplorerTransferSpeedSparklinePainter(this.samples, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2 || size.width <= 0 || size.height <= 0) return;
    final peak = samples.reduce(max);
    if (peak <= 0) return;
    final path = Path();
    for (var index = 0; index < samples.length; index++) {
      final x = size.width * index / (samples.length - 1);
      final y = size.height - size.height * samples[index] / peak;
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(
          covariant _ExplorerTransferSpeedSparklinePainter oldDelegate) =>
      oldDelegate.samples != samples || oldDelegate.color != color;
}
