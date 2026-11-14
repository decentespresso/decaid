import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show FramePhase;

import 'package:flutter/scheduler.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

final _log = Logger('Perf');

class FrameProfiler {
  static bool get enabled =>
      const bool.fromEnvironment('perfFrames') ||
      const String.fromEnvironment('perfFrames').isNotEmpty;

  static const int refreshHz = int.fromEnvironment(
    'perfRefreshHz',
    defaultValue: 60,
  );

  static const int _autoDumpSeconds = 15;
  static const int _maxSamplesPerSegment = 20000;
  static const int _chunkLength = 3000;

  static final List<_Segment> _segments = [];
  static final Stopwatch _clock = Stopwatch();
  static int _processedFrames = 0;
  static int _activeSegment = 0;
  static int _lastVsyncUs = 0;
  static bool _running = false;
  static bool _dumping = false;
  static Timer? _autoDump;
  static String? _lastMarkedLabel;
  static String? _reportDirectory;

  static double get budgetMs => 1000 / refreshHz;

  static void start() {
    if (!enabled || _running) return;
    _running = true;
    _clock
      ..reset()
      ..start();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _autoDump = Timer.periodic(
      const Duration(seconds: _autoDumpSeconds),
      (_) => dump(),
    );
    _openSegment('unmarked');
    _log.info(
      'PERF_READY budget_ms=${budgetMs.toStringAsFixed(2)} refresh_hz=$refreshHz',
    );
  }

  static void attachReportDirectory(String path) {
    if (!enabled) return;
    _reportDirectory = path;
  }

  static void mark(String label) {
    if (!_running || label == _lastMarkedLabel) return;
    _openSegment(label);
  }

  static void dump() {
    if (!_running || _dumping) return;
    _dumping = true;
    try {
      final payload = snapshot();
      if (payload == null) return;
      _emit(payload);
      _writeReport(payload);
    } catch (e) {
      _log.warning('PERF_REPORT failed', e);
    } finally {
      _dumping = false;
    }
  }

  static String? snapshot() {
    if (!_running) return null;
    final nowMs = _clock.elapsedMilliseconds;
    return jsonEncode({
      'schema': 1,
      'budget_ms': _round(budgetMs),
      'refresh_hz': refreshHz,
      'uptime_ms': nowMs,
      'frames_total': _processedFrames,
      'segments': [
        for (final segment in _segments)
          if (segment.frames > 0) segment.toJson(nowMs),
      ],
    });
  }

  static void _writeReport(String payload) {
    final directory = _reportDirectory;
    if (directory == null) return;
    unawaited(() async {
      try {
        final file = File(p.join(directory, 'perf', 'latest.json'));
        await file.parent.create(recursive: true);
        await file.writeAsString(payload, flush: true);
      } catch (e) {
        _log.warning('perf report write failed', e);
      }
    }());
  }

  static void _emit(String payload) {
    final chunks = <String>[];
    for (var start = 0; start < payload.length; start += _chunkLength) {
      final end = (start + _chunkLength).clamp(0, payload.length);
      chunks.add(payload.substring(start, end));
    }
    for (var i = 0; i < chunks.length; i++) {
      _log.info('PERF_CHUNK ${i + 1} ${chunks.length} ${chunks[i]}');
    }
  }

  static void stop() {
    if (!_running) return;
    _autoDump?.cancel();
    _autoDump = null;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _running = false;
  }

  static void _openSegment(String label) {
    _lastMarkedLabel = label;
    if (_segments.isNotEmpty) {
      _segments.last.endedAtMs = _clock.elapsedMilliseconds;
    }
    _segments.add(
      _Segment(label, _processedFrames, _clock.elapsedMilliseconds),
    );
  }

  static void _onTimings(List<FrameTiming> timings) {
    if (!_running) return;
    final budget = budgetMs;
    for (final timing in timings) {
      final segment = _segmentFor(_processedFrames);
      _processedFrames++;
      final buildMs = timing.buildDuration.inMicroseconds / 1000.0;
      final rasterMs = timing.rasterDuration.inMicroseconds / 1000.0;
      final vsyncUs = timing.timestampInMicroseconds(FramePhase.vsyncStart);
      if (_lastVsyncUs > 0 && vsyncUs > _lastVsyncUs) {
        segment?.addGap((vsyncUs - _lastVsyncUs) / 1000.0);
      }
      _lastVsyncUs = vsyncUs;
      if (buildMs <= 0 && rasterMs <= 0) continue;
      segment?.add(buildMs, rasterMs, budget);
    }
  }

  static _Segment? _segmentFor(int frameIndex) {
    if (_segments.isEmpty) return null;
    while (_activeSegment + 1 < _segments.length &&
        _segments[_activeSegment + 1].startFrame <= frameIndex) {
      _activeSegment++;
    }
    return _segments[_activeSegment];
  }
}

class _Segment {
  _Segment(this.label, this.startFrame, this.startedAtMs);

  String label;
  final int startFrame;
  int startedAtMs;
  int endedAtMs = -1;
  int frames = 0;
  int jankyBuild = 0;
  int jankyRaster = 0;
  double maxBuild = 0;
  double maxRaster = 0;
  double maxGap = 0;
  int longGaps = 0;
  final List<double> buildSamples = [];
  final List<double> rasterSamples = [];

  void addGap(double gapMs) {
    if (gapMs > maxGap) maxGap = gapMs;
    if (gapMs > 100) longGaps++;
  }

  void add(double buildMs, double rasterMs, double budgetMs) {
    frames++;
    if (buildMs > budgetMs) jankyBuild++;
    if (rasterMs > budgetMs) jankyRaster++;
    if (buildMs > maxBuild) maxBuild = buildMs;
    if (rasterMs > maxRaster) maxRaster = rasterMs;
    if (buildSamples.length < FrameProfiler._maxSamplesPerSegment) {
      buildSamples.add(buildMs);
    }
    if (rasterSamples.length < FrameProfiler._maxSamplesPerSegment) {
      rasterSamples.add(rasterMs);
    }
  }

  Map<String, Object?> toJson(int nowMs) {
    final wallMs = (endedAtMs < 0 ? nowMs : endedAtMs) - startedAtMs;
    return {
      'id': label,
      'frames': frames,
      'wall_ms': wallMs,
      'fps_effective': wallMs > 0 ? _round(frames * 1000 / wallMs) : 0,
      'build': _summarize(buildSamples, maxBuild),
      'raster': _summarize(rasterSamples, maxRaster),
      'janky_build': jankyBuild,
      'janky_raster': jankyRaster,
      'janky_build_pct': frames > 0 ? _round(jankyBuild * 100 / frames) : 0,
      'janky_raster_pct': frames > 0 ? _round(jankyRaster * 100 / frames) : 0,
      'max_gap_ms': _round(maxGap),
      'long_gaps': longGaps,
      'samples_truncated':
          buildSamples.length < frames || rasterSamples.length < frames,
    };
  }
}

Map<String, double> _summarize(List<double> samples, double max) {
  if (samples.isEmpty) {
    return {'avg_ms': 0, 'p50_ms': 0, 'p90_ms': 0, 'p99_ms': 0, 'max_ms': 0};
  }
  final sorted = List<double>.from(samples)..sort();
  final total = sorted.fold<double>(0, (sum, value) => sum + value);
  return {
    'avg_ms': _round(total / sorted.length),
    'p50_ms': _round(_percentile(sorted, 0.5)),
    'p90_ms': _round(_percentile(sorted, 0.9)),
    'p99_ms': _round(_percentile(sorted, 0.99)),
    'max_ms': _round(max),
  };
}

double _percentile(List<double> sorted, double p) {
  final index = ((sorted.length - 1) * p).round();
  return sorted[index];
}

double _round(double value) => (value * 100).roundToDouble() / 100;
