import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/machine.dart';

MachineState mapDe1ToMachineState(De1StateEnum de1State) {
  switch (de1State) {
    case De1StateEnum.sleep:
    case De1StateEnum.goingToSleep:
      return MachineState.sleeping;

    case De1StateEnum.idle:
    case De1StateEnum.noRequest:
      return MachineState.idle;

    case De1StateEnum.schedIdle:
      return MachineState.schedIdle;

    case De1StateEnum.init:
    case De1StateEnum.inBootLoader:
      return MachineState.booting;

    case De1StateEnum.busy:
      return MachineState.busy;
    case De1StateEnum.longCal:
    case De1StateEnum.shortCal:
      return MachineState.calibration;
    case De1StateEnum.selfTest:
      return MachineState.selfTest;

    case De1StateEnum.espresso:
      return MachineState.espresso;

    case De1StateEnum.hotWater:
      return MachineState.hotWater;
    case De1StateEnum.hotWaterRinse:
      return MachineState.flush;

    case De1StateEnum.steam:
      return MachineState.steam;

    case De1StateEnum.steamRinse:
      return MachineState.steamRinse;

    case De1StateEnum.airPurge:
      return MachineState.airPurge;

    case De1StateEnum.clean:
      return MachineState.cleaning;

    case De1StateEnum.descale:
      return MachineState.descaling;

    case De1StateEnum.skipToNext:
      return MachineState.skipStep;

    case De1StateEnum.refill:
      return MachineState.needsWater;

    case De1StateEnum.fatalError:
      return MachineState.error;

    case De1StateEnum.fwUpgrade:
      return MachineState.fwUpgrade;
    case De1StateEnum.unknown:
      return MachineState.error;
  }
}

MachineSubstate mapDe1SubToMachineSubstate(De1SubState de1SubState) {
  switch (de1SubState) {
    case De1SubState.noState:
    case De1SubState.userNotPresent:
    case De1SubState.refill:
      return MachineSubstate.idle;

    // Both are steam phases with nothing pouring, and both were reported as `idle`.
    // A caller could not tell a pause from a purge from a machine doing nothing, so
    // neither could be shown, and the purge in particular can last a while.
    case De1SubState.pausedSteam:
      return MachineSubstate.pausedSteam;
    case De1SubState.puffing:
      return MachineSubstate.puffing;

    case De1SubState.heatWaterTank:
    case De1SubState.heatWaterHeater:
    case De1SubState.stabilizeMixTemp:
      return MachineSubstate.preparingForShot;

    case De1SubState.preInfuse:
      return MachineSubstate.preinfusion;

    case De1SubState.pour:
    case De1SubState.steaming:
      return MachineSubstate.pouring;

    case De1SubState.end:
      return MachineSubstate.pouringDone;

    case De1SubState.cleanInit:
    case De1SubState.descaleInt:
      return MachineSubstate.cleaningStart;

    case De1SubState.cleanFillGroup:
    case De1SubState.cleanGroup:
    case De1SubState.descaleFillGroup:
    case De1SubState.descaleGroup:
    case De1SubState.descaleReturn:
      return MachineSubstate.cleaningGroup;

    case De1SubState.cleanSoak:
      return MachineSubstate.cleanSoaking;

    case De1SubState.descaleSteam:
      return MachineSubstate.cleaningSteam;

    case De1SubState.errorNaN:
      return MachineSubstate.errorNaN;
    case De1SubState.errorInf:
      return MachineSubstate.errorInf;
    case De1SubState.errorGeneric:
      return MachineSubstate.errorGeneric;
    case De1SubState.errorAcc:
      return MachineSubstate.errorAcc;
    case De1SubState.errorTSensor:
      return MachineSubstate.errorTSensor;
    case De1SubState.errorPSensor:
      return MachineSubstate.errorPSensor;
    case De1SubState.errorWLevel:
      return MachineSubstate.errorWLevel;
    case De1SubState.errorDip:
      return MachineSubstate.errorDip;
    case De1SubState.errorAssertion:
      return MachineSubstate.errorAssertion;
    case De1SubState.errorUnsafe:
      return MachineSubstate.errorUnsafe;
    case De1SubState.errorInvalidParam:
      return MachineSubstate.errorInvalidParam;
    case De1SubState.errorFlash:
      return MachineSubstate.errorFlash;
    case De1SubState.errorOOM:
      return MachineSubstate.errorOOM;
    case De1SubState.errorDeadline:
      return MachineSubstate.errorDeadline;
    case De1SubState.errorHiCurrent:
      return MachineSubstate.errorHiCurrent;
    case De1SubState.errorLoCurrent:
      return MachineSubstate.errorLoCurrent;
    case De1SubState.errorBootFill:
      return MachineSubstate.errorBootFill;
    case De1SubState.errorNoAC:
      return MachineSubstate.errorNoAC;
  }
}
