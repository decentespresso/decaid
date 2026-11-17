part of 'unified_de1.dart';

class _FirmwareMmrGate {
  var _activeMmrOperations = 0;
  var _firmwareActive = false;
  final _mmrWaiters = Queue<Completer<void>>();
  final _firmwareWaiters = Queue<Completer<void>>();

  Future<T> runMmr<T>(Future<T> Function() operation) async {
    await _acquireMmr();
    try {
      return await operation();
    } finally {
      _releaseMmr();
    }
  }

  Future<T> runFirmwareExclusive<T>(Future<T> Function() operation) async {
    await _acquireFirmware();
    try {
      return await operation();
    } finally {
      _releaseFirmware();
    }
  }

  Future<void> _acquireMmr() {
    if (!_firmwareActive &&
        _activeMmrOperations == 0 &&
        _firmwareWaiters.isEmpty) {
      _activeMmrOperations++;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _mmrWaiters.add(waiter);
    return waiter.future;
  }

  void _releaseMmr() {
    _activeMmrOperations--;
    if (_firmwareWaiters.isNotEmpty) {
      _grantNextFirmware();
    } else {
      _grantNextMmr();
    }
  }

  Future<void> _acquireFirmware() {
    if (!_firmwareActive &&
        _activeMmrOperations == 0 &&
        _firmwareWaiters.isEmpty) {
      _firmwareActive = true;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _firmwareWaiters.add(waiter);
    return waiter.future;
  }

  void _releaseFirmware() {
    _firmwareActive = false;
    if (_firmwareWaiters.isNotEmpty) {
      _grantNextFirmware();
      return;
    }
    _grantNextMmr();
  }

  void _grantNextMmr() {
    if (_mmrWaiters.isNotEmpty) {
      _activeMmrOperations++;
      _mmrWaiters.removeFirst().complete();
    }
  }

  void _grantNextFirmware() {
    _firmwareActive = true;
    _firmwareWaiters.removeFirst().complete();
  }
}
