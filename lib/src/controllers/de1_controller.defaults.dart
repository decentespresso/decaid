part of 'de1_controller.dart';

extension Defaults on De1Controller {
  Future<void> _setDe1DefaultsFor(
    De1Interface device,
    bool Function() stillCurrent,
  ) async {
    await device.setFanThreshhold(55);
    if (!stillCurrent()) return;

    if (defaultWorkflow == null) {
      return;
    }
    SteamSettings steamSettings = defaultWorkflow!.steamSettings;
    await _updateSteamSettingsFor(
      device,
      SteamFormSettings(
        steamEnabled: steamSettings.targetTemperature >= 135,
        targetTemp: steamSettings.targetTemperature,
        targetDuration: steamSettings.duration,
        targetFlow: steamSettings.flow,
      ),
      stillCurrent,
    );
    if (!stillCurrent()) return;

    HotWaterData hotWaterData = defaultWorkflow!.hotWaterData;
    await _updateHotWaterSettingsFor(
      device,
      HotWaterFormSettings(
        targetTemperature: hotWaterData.targetTemperature,
        flow: hotWaterData.flow,
        volume: hotWaterData.volume,
        duration: hotWaterData.duration,
      ),
      stillCurrent,
    );
    if (!stillCurrent()) return;

    RinseData rinseData = defaultWorkflow!.rinseData;
    await _updateFlushSettingsFor(device, rinseData, stillCurrent);
  }

  Future<void> _updateSteamSettingsFor(
    De1Interface device,
    SteamFormSettings settings,
    bool Function() stillCurrent,
  ) async {
    De1ShotSettings shotSettings = await device.shotSettings.first;
    if (!stillCurrent()) return;
    await device.setSteamFlow(settings.targetFlow);
    if (!stillCurrent()) return;
    await device.updateShotSettings(
      shotSettings.copyWith(
        targetSteamTemp: settings.steamEnabled ? settings.targetTemp : 0,
        targetSteamDuration: settings.targetDuration,
      ),
    );
    if (!stillCurrent()) return;
    _steamDataController.add(
      SteamSettings(
        targetTemperature: settings.steamEnabled ? settings.targetTemp : 0,
        duration: settings.targetDuration,
        flow: settings.targetFlow,
      ),
    );
  }

  Future<void> _updateHotWaterSettingsFor(
    De1Interface device,
    HotWaterFormSettings settings,
    bool Function() stillCurrent,
  ) async {
    await device.setHotWaterFlow(settings.flow);
    if (!stillCurrent()) return;
    De1ShotSettings shotSettings = await device.shotSettings.first;
    if (!stillCurrent()) return;
    await device.updateShotSettings(
      shotSettings.copyWith(
        targetHotWaterTemp: settings.targetTemperature,
        targetHotWaterVolume: settings.volume,
        targetHotWaterDuration: settings.duration,
      ),
    );
    if (!stillCurrent()) return;
    _hotWaterDataController.add(
      HotWaterData(
        targetTemperature: settings.targetTemperature,
        duration: settings.duration,
        volume: settings.volume,
        flow: settings.flow,
      ),
    );
  }

  Future<void> _updateFlushSettingsFor(
    De1Interface device,
    RinseData settings,
    bool Function() stillCurrent,
  ) async {
    await device.setFlushTimeout(settings.duration.toDouble());
    if (!stillCurrent()) return;
    await device.setFlushFlow(settings.flow);
    if (!stillCurrent()) return;
    await device.setFlushTemperature(settings.targetTemperature.toDouble());
    if (!stillCurrent()) return;
    _rinseStream.add(settings);
  }

  Future<void> applySettingsDefaults(De1Interface device) async {
    await device.setFanThreshhold(55);

    await device.setHeaterIdleTemp(95);
    await device.setHeaterPhase1Flow(2.0);
    await device.setHeaterPhase2Flow(4.0);
    await device.setHeaterPhase2Timeout(4.0);

    await device.setRefillKitSettings(.auto);

    await device.setFlowEstimation(1.0);
    await device.setSteamPurgeMode(0);
  }
}
