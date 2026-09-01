import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/shot_annotations.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/util/shot_chart.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class HistoryFeature extends StatefulWidget {
  static const routeName = '/history';

  const HistoryFeature({
    super.key,
    required this.persistenceController,
    required this.workflowController,
    this.selectedShot,
  });

  final PersistenceController persistenceController;
  final WorkflowController workflowController;
  final String? selectedShot;

  @override
  State<StatefulWidget> createState() => _HistoryFeatureState();
}

class _HistoryFeatureState extends State<HistoryFeature> {
  final Logger _log = Logger("HistoryFeature");
  final TextEditingController _searchController = TextEditingController();

  List<ShotRecord> _shots = [];
  late StreamSubscription<void> _shotsSubscription;
  Timer? _searchDebounce;

  ShotRecord? _selectedShot;

  @override
  void initState() {
    super.initState();
    _shotsSubscription = widget.persistenceController.shotsChanged.listen((_) {
      _loadShots();
    });
    _searchController.addListener(_onSearchChanged);
    _loadShots();
    if (widget.selectedShot != null) {
      setSelectedShot("");
    }
  }

  Future<void> _loadShots() async {
    final search = _searchController.text.isEmpty
        ? null
        : _searchController.text;
    final shots = await widget.persistenceController.storageService
        .getShotsPaginated(limit: 200, search: search);
    if (mounted) {
      setState(() {
        _shots = shots;
      });
    }
  }

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      _loadShots();
    });
  }

  void setSelectedShot(String id) {
    final Map<String, dynamic> json =
        jsonDecode(widget.selectedShot!) as Map<String, dynamic>;
    final shot = ShotRecord.fromJson(json);
    _selectedShot = shot;
  }

  Future<void> _selectShot(ShotRecord shotMeta) async {
    final fullShot = await widget.persistenceController.storageService.getShot(
      shotMeta.id,
    );
    if (mounted && fullShot != null) {
      setState(() {
        _selectedShot = fullShot;
      });
    }
  }

  String _shotListItemLabel(ShotRecord record, int durationSeconds) {
    final parts = <String>[record.shotTime()];
    if (record.workflow.context?.coffeeName != null) {
      parts.add(record.workflow.context!.coffeeName!);
    }
    if (record.workflow.context?.coffeeRoaster != null) {
      parts.add('by ${record.workflow.context!.coffeeRoaster!}');
    }
    parts.add(record.workflow.profile.title);
    if (record.workflow.context?.targetDoseWeight != null) {
      parts.add('${record.workflow.context!.targetDoseWeight!}g in');
    }
    if (record.workflow.context?.targetYield != null) {
      parts.add('${record.workflow.context!.targetYield!}g out');
    }
    if (record.workflow.context?.grinderModel != null) {
      final grinder = record.workflow.context!.grinderModel!;
      final setting = record.workflow.context?.grinderSetting;
      parts.add(setting != null ? '$grinder at $setting' : grinder);
    }
    parts.add('${durationSeconds}s');
    if (record.annotations?.espressoNotes != null &&
        record.annotations!.espressoNotes!.isNotEmpty) {
      parts.add('has notes');
    }
    return parts.join(', ');
  }

  String _chartSummaryLabel(ShotRecord record) {
    final duration = record.measurements.isNotEmpty
        ? record.measurements.last.machine.timestamp.difference(
            record.timestamp,
          )
        : Duration.zero;
    final parts = <String>['Shot profile chart'];
    parts.add('duration ${duration.inSeconds} seconds');
    if (record.measurements.isNotEmpty) {
      final maxPressure = record.measurements
          .map((m) => m.machine.pressure)
          .reduce((a, b) => a > b ? a : b);
      parts.add('peak pressure ${maxPressure.toStringAsFixed(1)} bar');
      final maxFlow = record.measurements
          .map((m) => m.machine.flow)
          .reduce((a, b) => a > b ? a : b);
      parts.add(
        'peak flow ${maxFlow.toStringAsFixed(1)} millilitres per second',
      );
    }
    return parts.join(', ');
  }

  @override
  void dispose() {
    _shotsSubscription.cancel();
    _searchDebounce?.cancel();
    _searchController.removeListener(_onSearchChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("History")),
      body: body(context),
    );
  }

  Widget body(BuildContext context) {
    return SafeArea(
      child: Row(
        mainAxisSize: MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [leftColumn(context), rightColumn(context)],
      ),
    );
  }

  Widget leftColumn(BuildContext context) {
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SearchBar(
                  controller: _searchController,
                  hintText:
                      "Search by coffee, roaster, profile, grinder, or notes...",
                ),
                if (_searchController.text.isNotEmpty)
                  Semantics(
                    liveRegion: true,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4.0, left: 8.0),
                      child: Text(
                        "Found ${_shots.length} shot${_shots.length == 1 ? '' : 's'}",
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _shots.length,
              itemBuilder: (context, index) {
                final ShotRecord record = _shots[index];
                final isSelected = _selectedShot?.id == record.id;
                final duration = record.measurements.isNotEmpty
                    ? record.measurements.last.machine.timestamp.difference(
                        record.timestamp,
                      )
                    : Duration.zero;
                final durationSeconds = duration.inSeconds;

                return Semantics(
                  button: true,
                  selected: isSelected,
                  label: _shotListItemLabel(record, durationSeconds),
                  child: ExcludeSemantics(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8.0,
                        vertical: 4.0,
                      ),
                      child: InkWell(
                        onTap: () {
                          _selectShot(record);
                        },
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          decoration: BoxDecoration(
                            color: isSelected
                                ? Theme.of(context).colorScheme.primaryContainer
                                      .withValues(alpha: 0.3)
                                : null,
                            border: isSelected
                                ? Border.all(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                    width: 2,
                                  )
                                : null,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ShadCard(
                            backgroundColor: Colors.transparent,
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      record.shotTime(),
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.bold,
                                          ),
                                    ),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.secondaryContainer,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        "${durationSeconds}s",
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w600,
                                            ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),

                                if (record.workflow.context?.coffeeName !=
                                    null) ...[
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.coffee,
                                        size: 14,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.6),
                                      ),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(
                                          record.workflow.context!.coffeeName!,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodyMedium
                                              ?.copyWith(
                                                fontWeight: FontWeight.w500,
                                              ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (record.workflow.context?.coffeeRoaster !=
                                      null)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        left: 18,
                                        top: 2,
                                      ),
                                      child: Text(
                                        record.workflow.context!.coffeeRoaster!,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurface
                                                  .withValues(alpha: 0.6),
                                            ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  const SizedBox(height: 6),
                                ],

                                Row(
                                  children: [
                                    Icon(
                                      Icons.dashboard_customize,
                                      size: 14,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurface
                                          .withValues(alpha: 0.6),
                                    ),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        record.workflow.profile.title,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),

                                if (record.workflow.context?.targetDoseWeight !=
                                    null) ...[
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.scale,
                                        size: 14,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.6),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        "${record.workflow.context!.targetDoseWeight!}g → ${record.workflow.context?.targetYield ?? 0}g",
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w500,
                                            ),
                                      ),
                                      if (record.workflow.context?.ratio !=
                                          null) ...[
                                        const SizedBox(width: 8),
                                        Text(
                                          "(1:${record.workflow.context!.ratio!.toStringAsFixed(1)})",
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onSurface
                                                    .withValues(alpha: 0.6),
                                              ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ],

                                if (record.workflow.context?.grinderModel !=
                                        null ||
                                    record.workflow.context?.grinderSetting !=
                                        null) ...[
                                  const SizedBox(height: 6),
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.settings,
                                        size: 14,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface
                                            .withValues(alpha: 0.6),
                                      ),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(
                                          "${record.workflow.context?.grinderModel ?? 'Grinder'}: ${record.workflow.context?.grinderSetting ?? ''}",
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodySmall,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],

                                if (record.annotations?.espressoNotes != null &&
                                    record
                                        .annotations!
                                        .espressoNotes!
                                        .isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.surfaceContainerHighest,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Icon(
                                          Icons.note,
                                          size: 12,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                              .withValues(alpha: 0.6),
                                        ),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Text(
                                            record.annotations!.espressoNotes!,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                  fontStyle: FontStyle.italic,
                                                ),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],

                                if (record.annotations?.extras != null &&
                                    record.annotations!.extras!['tags'] !=
                                        null) ...[
                                  const SizedBox(height: 6),
                                  Wrap(
                                    spacing: 4,
                                    runSpacing: 4,
                                    children: [
                                      for (var tag
                                          in (record
                                                      .annotations!
                                                      .extras!['tags']
                                                  as List)
                                              .take(3))
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.tertiaryContainer,
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                          ),
                                          child: Text(
                                            tag.toString(),
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(fontSize: 10),
                                          ),
                                        ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget rightColumn(BuildContext context) {
    return Expanded(
      flex: 2,
      child: _selectedShot != null
          ? shotDetail(context, _selectedShot!)
          : Center(
              child: Semantics(
                label: 'No shot selected, select a shot from the list',
                child: ExcludeSemantics(child: Text("No shot selected")),
              ),
            ),
    );
  }

  Widget shotDetail(BuildContext context, ShotRecord record) {
    final duration = record.measurements.isNotEmpty
        ? record.measurements.last.machine.timestamp.difference(
            record.timestamp,
          )
        : Duration.zero;
    final ratio = record.workflow.context?.ratio;

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        record.workflow.context?.coffeeName ?? "Shot Details",
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 4),
                      Text(
                        record.shotTime(),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Semantics(
                      button: true,
                      label: 'Edit shot notes',
                      child: ExcludeSemantics(
                        child: ShadButton.outline(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.edit, size: 16),
                              SizedBox(width: 4),
                              Text("Edit"),
                            ],
                          ),
                          onPressed: () => _showEditDialog(context, record),
                        ),
                      ),
                    ),
                    Semantics(
                      button: true,
                      label: 'Repeat this shot',
                      child: ExcludeSemantics(
                        child: ShadButton(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.replay, size: 16),
                              SizedBox(width: 4),
                              Text("Repeat"),
                            ],
                          ),
                          onPressed: () {
                            widget.workflowController.setWorkflow(
                              record.workflow.copyWith(),
                            );
                          },
                        ),
                      ),
                    ),
                    Semantics(
                      button: true,
                      label: 'Delete this shot',
                      child: ExcludeSemantics(
                        child: ShadButton.destructive(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.delete, size: 16),
                              SizedBox(width: 4),
                              Text("Delete"),
                            ],
                          ),
                          onPressed: () => _confirmDelete(context, record),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            SizedBox(height: 24),

            Row(
              children: [
                Expanded(
                  child: _StatCard(
                    icon: Icons.timer,
                    label: "Duration",
                    value: "${duration.inSeconds}s",
                    context: context,
                  ),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: _StatCard(
                    icon: Icons.scale,
                    label: "Ratio",
                    value: ratio != null
                        ? "1:${ratio.toStringAsFixed(1)}"
                        : "–",
                    context: context,
                  ),
                ),
                SizedBox(width: 12),
                Expanded(
                  child: _StatCard(
                    icon: Icons.arrow_forward,
                    label: "Yield",
                    value: record.workflow.context?.targetYield != null
                        ? "${record.workflow.context!.targetYield!}g"
                        : "–",
                    context: context,
                  ),
                ),
              ],
            ),
            SizedBox(height: 20),

            Semantics(
              explicitChildNodes: true,
              child: ShadCard(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        ExcludeSemantics(child: Icon(Icons.coffee, size: 20)),
                        SizedBox(width: 8),
                        Semantics(
                          header: true,
                          child: Text(
                            "Coffee Details",
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 12),
                    _DetailRow(
                      label: "Bean",
                      value:
                          record.workflow.context?.coffeeName ??
                          "Not specified",
                      context: context,
                    ),
                    if (record.workflow.context?.coffeeRoaster != null)
                      _DetailRow(
                        label: "Roaster",
                        value: record.workflow.context!.coffeeRoaster!,
                        context: context,
                      ),
                    if (record.workflow.context?.targetDoseWeight != null)
                      _DetailRow(
                        label: "Dose In",
                        value: "${record.workflow.context!.targetDoseWeight!}g",
                        context: context,
                      ),
                    if (record.workflow.context?.targetYield != null)
                      _DetailRow(
                        label: "Dose Out",
                        value: "${record.workflow.context!.targetYield!}g",
                        context: context,
                      ),
                  ],
                ),
              ),
            ),
            SizedBox(height: 16),

            Semantics(
              explicitChildNodes: true,
              child: ShadCard(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        ExcludeSemantics(child: Icon(Icons.settings, size: 20)),
                        SizedBox(width: 8),
                        Semantics(
                          header: true,
                          child: Text(
                            "Equipment",
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 12),
                    _DetailRow(
                      label: "Profile",
                      value: record.workflow.profile.title,
                      context: context,
                    ),
                    if (record.workflow.context?.grinderModel != null ||
                        record.workflow.context?.grinderSetting != null) ...[
                      _DetailRow(
                        label: "Grinder",
                        value:
                            record.workflow.context?.grinderModel ?? "Unknown",
                        context: context,
                      ),
                      if (record.workflow.context?.grinderSetting != null)
                        _DetailRow(
                          label: "Setting",
                          value: record.workflow.context!.grinderSetting!,
                          context: context,
                        ),
                    ],
                  ],
                ),
              ),
            ),

            if (record.annotations?.espressoNotes != null &&
                record.annotations!.espressoNotes!.isNotEmpty) ...[
              SizedBox(height: 16),
              Semantics(
                explicitChildNodes: true,
                child: ShadCard(
                  padding: EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          ExcludeSemantics(child: Icon(Icons.note, size: 20)),
                          SizedBox(width: 8),
                          Semantics(
                            header: true,
                            child: Text(
                              "Notes",
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 12),
                      Text(
                        record.annotations!.espressoNotes!,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ),
            ],

            if (record.annotations?.extras != null &&
                record.annotations!.extras!.isNotEmpty) ...[
              SizedBox(height: 16),
              Semantics(
                explicitChildNodes: true,
                child: ShadCard(
                  padding: EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          ExcludeSemantics(child: Icon(Icons.label, size: 20)),
                          SizedBox(width: 8),
                          Semantics(
                            header: true,
                            child: Text(
                              "Additional Info",
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 12),
                      ...record.annotations!.extras!.entries.map((entry) {
                        if (entry.key == 'tags' && entry.value is List) {
                          return Padding(
                            padding: EdgeInsets.only(bottom: 8),
                            child: Semantics(
                              label:
                                  'Tags: ${(entry.value as List).join(", ")}',
                              child: ExcludeSemantics(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      "Tags:",
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurface
                                                .withValues(alpha: 0.7),
                                          ),
                                    ),
                                    SizedBox(height: 4),
                                    Wrap(
                                      spacing: 6,
                                      runSpacing: 6,
                                      children: [
                                        for (var tag in (entry.value as List))
                                          Container(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.tertiaryContainer,
                                              borderRadius:
                                                  BorderRadius.circular(16),
                                            ),
                                            child: Text(
                                              tag.toString(),
                                              style: Theme.of(
                                                context,
                                              ).textTheme.bodySmall,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }
                        return _DetailRow(
                          label: entry.key,
                          value: entry.value.toString(),
                          context: context,
                        );
                      }),
                    ],
                  ),
                ),
              ),
            ],

            SizedBox(height: 20),

            Semantics(
              header: true,
              child: Text(
                "Shot Profile",
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            SizedBox(height: 12),
            Semantics(
              label: _chartSummaryLabel(record),
              child: ExcludeSemantics(
                child: SizedBox(
                  height: 500,
                  child: ShotChart(
                    key: ValueKey(record.id),
                    shotSnapshots: record.measurements,
                    shotStartTime: record.timestamp,
                  ),
                ),
              ),
            ),

            SizedBox(height: 16),
            Center(
              child: Text(
                "Shot ID: ${record.id}",
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditDialog(BuildContext context, ShotRecord record) {
    final notesController = TextEditingController(
      text: record.annotations?.espressoNotes ?? '',
    );

    showShadDialog(
      context: context,
      builder: (context) => ShadDialog(
        title: Text('Edit Shot'),
        description: Text('Update shot notes'),
        actions: [
          ShadButton.outline(
            child: const Text('Cancel'),
            onPressed: () => Navigator.of(context).pop(),
          ),
          ShadButton(
            child: const Text('Save'),
            onPressed: () async {
              try {
                final newNotes = notesController.text.isEmpty
                    ? null
                    : notesController.text;
                final updatedAnnotations =
                    (record.annotations ?? const ShotAnnotations()).copyWith(
                      espressoNotes: newNotes ?? '',
                    );
                final updatedShot = record.copyWith(
                  annotations: updatedAnnotations,
                  updatedAt: DateTime.now().toUtc(),
                );
                await widget.persistenceController.updateShot(updatedShot);
                if (!context.mounted) return;
                Navigator.of(context).pop();
                if (!mounted) return;
                setState(() {
                  _selectedShot = updatedShot;
                });
              } catch (e) {
                _log.severe("Failed to update shot", e);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Failed to update shot: $e')),
                );
              }
            },
          ),
        ],
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ShadInput(
                controller: notesController,
                placeholder: const Text('Add notes about this shot...'),
                maxLines: 5,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmDelete(BuildContext context, ShotRecord record) {
    showShadDialog(
      context: context,
      builder: (context) => ShadDialog.alert(
        title: const Text('Delete Shot'),
        description: Text(
          'Are you sure you want to delete this shot? This action cannot be undone.',
        ),
        actions: [
          ShadButton.outline(
            child: const Text('Cancel'),
            onPressed: () => Navigator.of(context).pop(),
          ),
          ShadButton.destructive(
            child: const Text('Delete'),
            onPressed: () async {
              try {
                await widget.persistenceController.deleteShot(record.id);
                if (!context.mounted) return;
                Navigator.of(context).pop();
                if (!mounted) return;
                setState(() {
                  _selectedShot = null;
                });
              } catch (e) {
                _log.severe("Failed to delete shot", e);
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Failed to delete shot: $e')),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final BuildContext context;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.context,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label: $value',
      child: ExcludeSemantics(
        child: ShadCard(
          padding: EdgeInsets.all(12),
          child: Column(
            children: [
              Icon(
                icon,
                size: 24,
                color: Theme.of(context).colorScheme.primary,
              ),
              SizedBox(height: 8),
              Text(
                value,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 4),
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final BuildContext context;

  const _DetailRow({
    required this.label,
    required this.value,
    required this.context,
  });

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 100,
              child: Text(
                "$label:",
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ),
            Expanded(
              child: Text(value, style: Theme.of(context).textTheme.bodyMedium),
            ),
          ],
        ),
      ),
    );
  }
}
