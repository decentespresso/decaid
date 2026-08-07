enum ScalePowerMode { disabled, displayOff, disconnect }

extension ScalePowerModeExtension on ScalePowerMode {
  String get displayName {
    switch (this) {
      case ScalePowerMode.disabled:
        return 'Disabled';
      case ScalePowerMode.displayOff:
        return 'Display Off';
      case ScalePowerMode.disconnect:
        return 'Disconnect';
    }
  }

  String get description {
    switch (this) {
      case ScalePowerMode.disabled:
        return 'Manual control only, no automatic power management';
      case ScalePowerMode.displayOff:
        return 'Turn off scale display when machine sleeps';
      case ScalePowerMode.disconnect:
        return 'Disconnect scale completely when machine sleeps';
    }
  }
}

extension ScalePowerModeFromString on ScalePowerMode {
  static ScalePowerMode? fromString(String value) {
    switch (value.toLowerCase()) {
      case 'disabled':
        return ScalePowerMode.disabled;
      case 'displayoff':
      case 'display_off':
        return ScalePowerMode.displayOff;
      case 'disconnect':
        return ScalePowerMode.disconnect;
      default:
        return null;
    }
  }
}
