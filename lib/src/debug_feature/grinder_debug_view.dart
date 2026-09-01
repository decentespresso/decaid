import 'dart:async';

import 'package:flutter/material.dart';
import 'package:reaprime/src/models/device/device.dart' as dev;
import 'package:reaprime/src/models/device/grinder.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

String _grinderLang = 'en';

String _t(String en, String zh) => _grinderLang == 'zh' ? zh : en;

String _devStateName(GrinderDevState state) {
  return switch (state) {
    GrinderDevState.idle => _t('Idle', '待机中'),
    GrinderDevState.grinding => _t('Grinding', '研磨中'),
    GrinderDevState.highspeedClean => _t('High-speed clean', '高转排粉'),
    GrinderDevState.setting => _t('Setting', '设置中'),
    GrinderDevState.unknown => _t('Unknown', '未知'),
  };
}

const _numSettings = [
  ('feedingRpm', 0, 65, 5),
  ('grindRpm', 500, 1500, 50),
  ('brightness', 0, 10, 1),
  ('standbySec', 0, 900, 30),
  ('grindSetting', 0, 1000, 5),
];

String _numSettingLabel(String key) {
  return switch (key) {
    'feedingRpm' => _t('Feed RPM', '下豆速度'),
    'grindRpm' => _t('Grind RPM', '刀盘转速'),
    'brightness' => _t('Brightness', '亮度'),
    'standbySec' => _t('Standby (s)', '熄屏秒'),
    'grindSetting' => _t('Grind size', '研磨度'),
    _ => key,
  };
}

const _boolSettings = [
  ('cupDetect', 'cupDetect'),
  ('autoStop', 'autoStop'),
  ('fastClean', 'fastClean'),
];

String _boolSettingLabel(String key) {
  return switch (key) {
    'cupDetect' => _t('Cup detect', '杯检'),
    'autoStop' => _t('Auto stop', '自动停止'),
    'fastClean' => _t('Fast clean', '强力清粉'),
    _ => key,
  };
}

class GrinderDebugView extends StatefulWidget {
  final Grinder grinder;

  const GrinderDebugView({super.key, required this.grinder});

  @override
  State<GrinderDebugView> createState() => _GrinderDebugViewState();
}

class _GrinderDebugViewState extends State<GrinderDebugView> {
  final List<GrinderLogEntry> _sendLog = [];
  final List<GrinderLogEntry> _respLog = [];
  final List<GrinderLogEntry> _bcLog = [];
  StreamSubscription<GrinderLogEntry>? _logSub;
  StreamSubscription<dev.ConnectionState>? _connectionSub;
  final Map<String, Timer> _debTimers = {};
  GrinderSnapshot? _last;
  bool _connected = false;

  @override
  void initState() {
    super.initState();
    widget.grinder.onConnect();
    _connectionSub = widget.grinder.connectionState.listen((state) {
      if (mounted) {
        setState(() => _connected = state == dev.ConnectionState.connected);
      }
    });
    _logSub = widget.grinder.logStream.listen((entry) {
      switch (entry.kind) {
        case GrinderLogKind.send:
          _push(_sendLog, entry, 100);
        case GrinderLogKind.response:
          _push(_respLog, entry, 60);
        case GrinderLogKind.broadcast:
          _push(_bcLog, entry, 60);
      }
    });
  }

  @override
  void dispose() {
    _logSub?.cancel();
    _connectionSub?.cancel();
    for (final timer in _debTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  void _push(List<GrinderLogEntry> list, GrinderLogEntry entry, int cap) {
    list.insert(0, entry);
    if (list.length > cap) list.removeLast();
    if (mounted) setState(() {});
  }

  Future<void> _sendNum(String key, double value) async {
    switch (key) {
      case 'feedingRpm':
        await widget.grinder.setFeedingRpm(value.round());
      case 'grindRpm':
        await widget.grinder.setGrindRpm(value.round());
      case 'brightness':
        await widget.grinder.setBrightness(value.round());
      case 'standbySec':
        await widget.grinder.setStandbySec(value.round());
      case 'grindSetting':
        await widget.grinder.setGrindSetting(value.round());
    }
  }

  void _debSend(String key, double value) {
    _debTimers[key]?.cancel();
    _debTimers[key] = Timer(const Duration(milliseconds: 250), () {
      _sendNum(key, value);
    });
  }

  Future<void> _setBool(String key, bool on) async {
    switch (key) {
      case 'cupDetect':
        await widget.grinder.setCupDetect(on);
      case 'autoStop':
        await widget.grinder.setAutoStop(on);
      case 'fastClean':
        await widget.grinder.setFastClean(on);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_t('Grinder Debug', '磨豆机调试')),
        leading: IconButton(
          icon: const Icon(LucideIcons.arrowLeft),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          ShadButton.destructive(
            size: ShadButtonSize.sm,
            child: Text(_t('Disconnect', '断开')),
            onPressed: () async {
              await widget.grinder.disconnect();
              if (!context.mounted) return;
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
      body: StreamBuilder<GrinderSnapshot>(
        stream: widget.grinder.currentSnapshot,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.active) {
            _last = snapshot.data;
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_last != null) ...[
                _buildMockDisplay(theme, _last!),
                const SizedBox(height: 16),
                _buildSettingsPanel(theme, _last!),
                const SizedBox(height: 16),
                _buildStatusTable(theme, _last!),
                const SizedBox(height: 16),
                _buildPresetPanel(theme, _last!),
                const SizedBox(height: 16),
              ],
              _buildCommands(theme),
              const SizedBox(height: 16),
              _buildLogSection(
                theme,
                _t('Send', '发送'),
                _sendLog,
                Colors.blue.shade300,
              ),
              _buildLogSection(
                theme,
                _t('Response', '响应'),
                _respLog,
                Colors.green.shade300,
              ),
              _buildLogSection(
                theme,
                _t('Broadcast', '广播'),
                _bcLog,
                Colors.purple.shade300,
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMockDisplay(ShadThemeData theme, GrinderSnapshot s) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.mutedForeground.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.border),
      ),
      child: Row(
        children: [
          Text(
            s.grindSetting?.toString() ?? '--',
            style: theme.textTheme.h1.copyWith(fontWeight: FontWeight.w700),
          ),
          Text(_t(' μm', ' μm'), style: theme.textTheme.muted),
          const SizedBox(width: 24),
          Text(
            '${_t('Feed', '下豆')} ${s.feedingRpm ?? '--'}',
            style: theme.textTheme.h4,
          ),
          Text(' RPM', style: theme.textTheme.muted),
          const SizedBox(width: 24),
          Text(
            '${_t('Grind', '转速')} ${s.grindRpm ?? '--'}',
            style: theme.textTheme.h4,
          ),
          Text(' RPM', style: theme.textTheme.muted),
          const SizedBox(width: 24),
          Text(
            '${_t('Humidity', '湿度')} ${s.humidity ?? '--'}',
            style: theme.textTheme.h4,
          ),
          Text(' %RH', style: theme.textTheme.muted),
          const Spacer(),
          Text(
            _devStateName(s.devState),
            style: theme.textTheme.h4.copyWith(color: Colors.lightBlue),
          ),
          const SizedBox(width: 12),
          _langButton('English', 'en'),
          const SizedBox(width: 4),
          _langButton('中文', 'zh'),
        ],
      ),
    );
  }

  Widget _langButton(String label, String lang) {
    final selected = _grinderLang == lang;
    return GestureDetector(
      onTap: () {
        if (_grinderLang == lang) return;
        setState(() => _grinderLang = lang);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1F6FEB) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected ? const Color(0xFF1F6FEB) : Colors.grey.shade500,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            color: selected ? Colors.white : Colors.grey.shade400,
          ),
        ),
      ),
    );
  }

  Widget _buildStatusTable(ShadThemeData theme, GrinderSnapshot s) {
    String boolText(bool? v) => v == null ? '—' : (v ? '开' : '关');
    final rows = <(String, String)>[
      (_t('Cup detect', '杯检'), boolText(s.cupDetect)),
      (_t('Auto stop', '自动停止'), boolText(s.autoStop)),
      (_t('Fast clean', '强力清粉'), boolText(s.fastClean)),
      ('WiFi', s.wifiName ?? '—'),
      (
        _t('Connection', '连接状态'),
        _connected ? _t('Connected', '已连接') : _t('Not connected', '未连接'),
      ),
      (_t('Total grinds', '累计研磨'), s.totalGrinds?.toString() ?? '—'),
      (_t('Brightness', '亮度'), s.brightness?.toString() ?? '—'),
      (_t('Standby (s)', '熄屏秒'), s.standbySec?.toString() ?? '—'),
      (_t('Network', '网络'), s.netState ?? '—'),
      (_t('Serial', '序列号'), s.snCode ?? '—'),
      (_t('Reset reason', '开机原因'), s.resetReason ?? '—'),
      (_t('Firmware', '固件版本'), s.releaseVer ?? '—'),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _t('Live status (~200ms/frame)', '实时状态 (约200ms/条)'),
              style: theme.textTheme.h3,
            ),
            const SizedBox(height: 8),
            ...rows.map(
              (r) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(r.$1, style: theme.textTheme.muted),
                    Text(r.$2, style: theme.textTheme.h4),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsPanel(ShadThemeData theme, GrinderSnapshot s) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _t('Live settings (drag to send)', '实时设置 (滑块拖动即发送)'),
              style: theme.textTheme.h3,
            ),
            const SizedBox(height: 8),
            ..._numSettings.map(
              (setting) => _NumericSettingRow(
                key: ValueKey('num-${setting.$1}'),
                label: _numSettingLabel(setting.$1),
                min: setting.$2,
                max: setting.$3,
                step: setting.$4,
                current: _valueFor(s, setting.$1),
                onChanged: (v) => _debSend(setting.$1, v),
                onCommit: (v) => _sendNum(setting.$1, v),
              ),
            ),
            const SizedBox(height: 8),
            ..._boolSettings.map(
              (setting) => _BoolSettingRow(
                key: ValueKey('bool-${setting.$1}'),
                label: _boolSettingLabel(setting.$1),
                current: _boolValueFor(s, setting.$1),
                onChanged: (on) => _setBool(setting.$1, on),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPresetPanel(ShadThemeData theme, GrinderSnapshot s) {
    if (s.presets.isEmpty && s.grindSections.isEmpty) {
      return const SizedBox.shrink();
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (s.presets.isNotEmpty) ...[
              Text(_t('Presets', '预设'), style: theme.textTheme.h3),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final preset in s.presets)
                    _presetChip(
                      theme,
                      preset.name,
                      selected:
                          s.selectedPresetIndex != null &&
                          preset.uid ==
                              (s.selectedPresetIndex! < s.presets.length
                                  ? s.presets[s.selectedPresetIndex!].uid
                                  : null),
                      onTap: () => widget.grinder.setPreset(uid: preset.uid),
                    ),
                ],
              ),
            ],
            if (s.grindSections.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(_t('Grind sections', '研磨段'), style: theme.textTheme.h3),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final section in s.grindSections)
                    _presetChip(
                      theme,
                      section.name,
                      selected: false,
                      onTap: () =>
                          widget.grinder.setGrindSection(index: section.index),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _presetChip(
    ShadThemeData theme,
    String name, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF1F6FEB)
              : theme.colorScheme.mutedForeground.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: theme.colorScheme.border),
        ),
        child: Text(
          name,
          style: theme.textTheme.h4.copyWith(
            color: selected ? Colors.white : theme.colorScheme.foreground,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildCommands(ShadThemeData theme) {
    final commands = <(String, Future<void> Function(), bool disabled)>[
      (_t('Handshake', '握手 appHello'), widget.grinder.onConnect, false),
      (_t('Query sections', '查询研磨段'), widget.grinder.querySections, false),
      (_t('Query presets', '查询预设'), widget.grinder.queryPresets, false),
      (
        _t('Start grinding (not enabled)', '开始研磨 (尚未启用)'),
        widget.grinder.start,
        true,
      ),
      (
        _t('Stop grinding (not enabled)', '停止研磨 (尚未启用)'),
        widget.grinder.stop,
        true,
      ),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_t('Commands', '指令'), style: theme.textTheme.h3),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final command in commands)
                  ShadButton(
                    size: ShadButtonSize.sm,
                    onPressed: command.$3 ? null : () => command.$2(),
                    child: Text(command.$1),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogSection(
    ShadThemeData theme,
    String title,
    List<GrinderLogEntry> entries,
    Color color,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.h3.copyWith(color: color)),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: SingleChildScrollView(
                reverse: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final entry in entries)
                      Text(
                        'seq=0x${entry.seq.toRadixString(16).padLeft(4, '0')} '
                        '${entry.text}',
                        style: theme.textTheme.small.copyWith(
                          fontFamily: 'Menlo',
                          fontSize: 11,
                          color: color.withValues(alpha: 0.9),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  double? _valueFor(GrinderSnapshot s, String key) {
    switch (key) {
      case 'feedingRpm':
        return s.feedingRpm?.toDouble();
      case 'grindRpm':
        return s.grindRpm?.toDouble();
      case 'brightness':
        return s.brightness?.toDouble();
      case 'standbySec':
        return s.standbySec?.toDouble();
      case 'grindSetting':
        return s.grindSetting?.toDouble();
      default:
        return null;
    }
  }

  bool? _boolValueFor(GrinderSnapshot s, String key) {
    switch (key) {
      case 'cupDetect':
        return s.cupDetect;
      case 'autoStop':
        return s.autoStop;
      case 'fastClean':
        return s.fastClean;
      default:
        return null;
    }
  }
}

class _NumericSettingRow extends StatefulWidget {
  final String label;
  final int min;
  final int max;
  final int step;
  final double? current;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onCommit;

  const _NumericSettingRow({
    super.key,
    required this.label,
    required this.min,
    required this.max,
    required this.step,
    required this.current,
    required this.onChanged,
    required this.onCommit,
  });

  @override
  State<_NumericSettingRow> createState() => _NumericSettingRowState();
}

class _NumericSettingRowState extends State<_NumericSettingRow> {
  late TextEditingController _controller;
  double? _draggingValue;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: (widget.current ?? widget.min).toString(),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final value = _draggingValue ?? widget.current ?? widget.min.toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${widget.label} (${widget.min}-${widget.max})',
            style: theme.textTheme.muted,
          ),
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: value.clamp(
                    widget.min.toDouble(),
                    widget.max.toDouble(),
                  ),
                  min: widget.min.toDouble(),
                  max: widget.max.toDouble(),
                  divisions: ((widget.max - widget.min) / widget.step).round(),
                  onChanged: (v) {
                    setState(() {
                      _draggingValue = v;
                      _controller.text = v.toStringAsFixed(0);
                    });
                    widget.onChanged(v);
                  },
                  onChangeEnd: (v) {
                    setState(() => _draggingValue = null);
                    widget.onCommit(v);
                  },
                ),
              ),
              SizedBox(
                width: 80,
                child: TextField(
                  controller: _controller,
                  keyboardType: TextInputType.number,
                  onSubmitted: (text) {
                    final v = double.tryParse(text);
                    if (v != null) widget.onCommit(v);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BoolSettingRow extends StatelessWidget {
  final String label;
  final bool? current;
  final ValueChanged<bool> onChanged;

  const _BoolSettingRow({
    super.key,
    required this.label,
    required this.current,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(label, style: theme.textTheme.muted),
          const Spacer(),
          Text(
            current == null
                ? _t('Unknown', '未知')
                : (current! ? _t('On', '开') : _t('Off', '关')),
            style: theme.textTheme.h4.copyWith(
              color: current == null
                  ? theme.colorScheme.mutedForeground
                  : current!
                  ? Colors.green
                  : Colors.orange,
            ),
          ),
          const SizedBox(width: 8),
          ShadButton(
            size: ShadButtonSize.sm,
            child: Text(_t('On', '开')),
            onPressed: () => onChanged(true),
          ),
          const SizedBox(width: 4),
          ShadButton(
            size: ShadButtonSize.sm,
            child: Text(_t('Off', '关')),
            onPressed: () => onChanged(false),
          ),
        ],
      ),
    );
  }
}
