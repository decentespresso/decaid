import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:reaprime/src/controllers/shot_sequencer.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/shot_snapshot.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/settings/gateway_mode.dart';
import 'package:reaprime/src/settings/settings_service.dart';
import 'package:reaprime/src/util/shot_chart.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class RealtimeShotFeature extends StatefulWidget {
  static const routeName = '/shot';

  final ShotSequencer shotSequencer;
  final WorkflowController workflowController;

  const RealtimeShotFeature({
    super.key,
    required this.shotSequencer,
    required this.workflowController,
  });

  @override
  State<StatefulWidget> createState() => _RealtimeShotFeatureState();
}

class _RealtimeShotFeatureState extends State<RealtimeShotFeature> {
  Future<void> _skipStep() async {
    try {
      await widget.shotSequencer.de1controller.requestMachineState(
        MachineState.skipStep,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Unable to skip step: $error')));
    }
  }

  late ShotSequencer _shotSequencer;
  final List<ShotSnapshot> _shotSnapshots = [];
  late StreamSubscription<ShotSnapshot> _shotSubscription;
  late StreamSubscription<bool> _resetCommandSubscription;
  late StreamSubscription<ShotState> _stateSubscription;
  late bool _gatewayMode;
  bool backEnabled = false;
  @override
  initState() {
    super.initState();
    SharedPreferencesSettingsService().gatewayMode().then(
      (b) => _gatewayMode = b == GatewayMode.full,
    );
    _shotSequencer = widget.shotSequencer;
    _resetCommandSubscription = _shotSequencer.resetCommand.listen((event) {
      setState(() {
        _shotSnapshots.clear();
      });
    });
    _shotSubscription = _shotSequencer.shotData.listen((event) {
      setState(() {
        _shotSnapshots.add(event);
      });
    });
    _stateSubscription = _shotSequencer.state.listen((state) {
      setState(() {
        if (state == ShotState.pouring || state == ShotState.preheating) {
          backEnabled = false;
        } else {
          backEnabled = true;
        }
      });
    });
  }

  @override
  void dispose() {
    _shotSubscription.cancel();
    _resetCommandSubscription.cancel();
    _stateSubscription.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.start,
            children: <Widget>[
              _shotStats(context),
              Flexible(
                child: ShotChart(
                  shotSnapshots: _shotSnapshots,
                  shotStartTime: _shotSequencer.shotStartTime,
                ),
              ),
              _buttons(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _shotStats(BuildContext context) {
    return DefaultTextStyle(
      style: Theme.of(context).textTheme.headlineSmall!,
      child: Row(
        children: [
          Spacer(),
          SizedBox(
            width: 200,
            child: Text(
              "Time: ${_shotSnapshots.lastWhereOrNull((sn) => sn.machine.state.substate == MachineSubstate.pouring)?.machine.timestamp.difference(_shotSequencer.shotStartTime).inSeconds}s",
            ),
          ),
          Spacer(),
          SizedBox(
            width: 150,
            child: Text(
              "${_shotSnapshots.lastOrNull?.machine.flow.toStringAsFixed(1)}ml/s",
              style: TextStyle(color: Colors.blue),
            ),
          ),
          Spacer(),
          SizedBox(
            width: 150,
            child: Text(
              "${_shotSnapshots.lastOrNull?.machine.pressure.toStringAsFixed(1)}bar",
              style: TextStyle(color: Colors.green),
            ),
          ),
          Spacer(),
          SizedBox(
            width: 150,
            child: Text(
              "GT: ${_shotSnapshots.lastOrNull?.machine.groupTemperature.toStringAsFixed(1)}℃",
              style: TextStyle(color: Colors.red),
            ),
          ),
          Spacer(),
          if (_shotSnapshots.lastOrNull?.scale != null)
            SizedBox(
              width: 150,
              child: Text(
                "W: ${_shotSnapshots.lastOrNull?.scale?.weight.toStringAsFixed(1)}g",
                style: TextStyle(color: Colors.purpleAccent),
              ),
            ),
          if (_shotSnapshots.lastOrNull?.scale != null) Spacer(),
          if (_shotSnapshots.lastOrNull?.scale != null)
            SizedBox(
              width: 150,
              child: Text(
                "WF: ${_shotSnapshots.lastOrNull?.scale?.weightFlow.toStringAsFixed(1)}g/s",
                style: TextStyle(color: Colors.purple),
              ),
            ),
          Spacer(),
        ],
      ),
    );
  }

  String _currentStep() {
    if (_shotSnapshots.isEmpty ||
        _shotSnapshots.last.machine.state.substate ==
            MachineSubstate.preparingForShot) {
      return "Preheat";
    }
    Profile profile = widget.workflowController.currentWorkflow.profile;
    var lastFrame = _shotSnapshots.lastOrNull?.machine.profileFrame;
    if (lastFrame == null) {
      return "Unknown";
    }
    if (_gatewayMode || profile.steps.length <= lastFrame) {
      return "Step ${lastFrame + 1}";
    }
    return profile.steps[lastFrame].name;
  }

  DateTime lastSnapshot = DateTime.now();
  Widget _buttons(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 50),
        ShadButton(
          enabled: backEnabled,
          child: Icon(LucideIcons.arrowLeft),
          onPressed: () {
            Navigator.pop(context);
          },
        ),
        SizedBox(width: 50),
        SizedBox(
          width: 100,
          child: StreamBuilder(
            stream: _shotSequencer.shotData,
            builder: (context, snapshot) {
              if (snapshot.hasData) {
                var difference = lastSnapshot
                    .difference(snapshot.data!.machine.timestamp)
                    .inMilliseconds;
                lastSnapshot = snapshot.data!.machine.timestamp;
                return Text("Freq: ${difference}ms");
              }
              return Container();
            },
          ),
        ),
        Spacer(),
        ShotDataView(
          firstLine: "Profile: ${_shotSequencer.targetProfile.title}",
          secondLine:
              "Target weight: ${_shotSequencer.targetYield.toStringAsFixed(1)}g",
        ),
        Spacer(),
        ShadButton.destructive(
          enabled: !backEnabled,
          onPressed: () {
            widget.shotSequencer.de1controller.recordStopIntent(
              ShotDecisionReason.appStop,
            );
            widget.shotSequencer.de1controller.requestMachineState(
              MachineState.idle,
            );
          },
          child: Text('Stop Shot'),
        ),
        ShadButton.secondary(
          enabled: !backEnabled,
          onPressed: _skipStep,
          trailing: Icon(LucideIcons.fastForward),
          child: Text('Skip Step'),
        ),
        Spacer(),
        ShotStateView(
          status: _shotSnapshots.lastOrNull?.machine.state.substate.name,
          step: _currentStep(),
        ),
        Spacer(),
      ],
    );
  }
}

class ShotStateView extends StatelessWidget {
  final String? status;
  final String step;

  const ShotStateView({super.key, required this.status, required this.step});

  @override
  Widget build(BuildContext context) {
    return Column(children: [Text("Status: $status"), Text("Step: $step")]);
  }
}

class ShotDataView extends StatelessWidget {
  final String? firstLine;
  final String secondLine;

  const ShotDataView({
    super.key,
    required this.firstLine,
    required this.secondLine,
  });

  @override
  Widget build(BuildContext context) {
    return Column(children: [Text("$firstLine"), Text(secondLine)]);
  }
}
