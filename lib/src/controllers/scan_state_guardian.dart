import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:reaprime/src/models/adapter_state.dart';
import 'package:reaprime/src/services/ble/ble_discovery_service.dart';
import 'package:rxdart/rxdart.dart';
import 'package:logging/logging.dart';

enum ScanStateEvent { adapterTurnedOff, adapterTurnedOn, scanStateStale }

class ScanStateGuardian with WidgetsBindingObserver {
  final BleDiscoveryService? bleService;
  final _log = Logger('ScanStateGuardian');
  final _eventSubject = PublishSubject<ScanStateEvent>();
  StreamSubscription<AdapterState>? _adapterSub;
  AdapterState _lastAdapterState = AdapterState.unknown;

  Stream<ScanStateEvent> get events => _eventSubject.stream;

  AdapterState get currentAdapterState => _lastAdapterState;

  ScanStateGuardian({this.bleService}) {
    final svc = bleService;
    if (svc != null) {
      _adapterSub = svc.adapterStateStream.listen(_onAdapterStateChanged);
    }
    WidgetsBinding.instance.addObserver(this);
  }

  void _onAdapterStateChanged(AdapterState state) {
    final previous = _lastAdapterState;
    _lastAdapterState = state;

    if (previous == AdapterState.poweredOn &&
        state == AdapterState.poweredOff) {
      _log.info('BLE adapter turned off');
      _eventSubject.add(ScanStateEvent.adapterTurnedOff);
    } else if (previous == AdapterState.poweredOff &&
        state == AdapterState.poweredOn) {
      _log.info('BLE adapter turned on');
      _eventSubject.add(ScanStateEvent.adapterTurnedOn);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      onAppResumed();
    }
  }

  void onAppResumed() {
    _log.fine('App resumed, checking scan state');
    _eventSubject.add(ScanStateEvent.scanStateStale);
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _adapterSub?.cancel();
    _eventSubject.close();
  }
}
