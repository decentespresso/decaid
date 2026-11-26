import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

// ignore: depend_on_referenced_packages
import 'package:libserialport/libserialport.dart';

import 'utils.dart';

class SerialWriter {
  static const _maxPendingWrites = 32;
  static const _maxPendingBytes = 65536;
  static const _writeTimeoutMs = 500;

  final _messages = ReceivePort();
  final _ready = Completer<SendPort>();
  final _exited = Completer<void>();
  final _pending = <int, (Completer<void>, int)>{};
  var _nextId = 0;
  var _pendingBytes = 0;
  bool _closing = false;

  SerialWriter(SerialPort port) {
    _ready.future.ignore();
    _messages.listen(_receive);
    _start(port.address);
  }

  Future<void> _start(int address) async {
    try {
      await Isolate.spawn(
        _run,
        (address, _messages.sendPort),
        debugName: 'SerialWriter',
        onExit: _messages.sendPort,
        onError: _messages.sendPort,
      );
    } catch (error, stack) {
      _ready.completeError(error, stack);
      _failPending(error, stack);
      _messages.close();
      _exited.complete();
    }
  }

  Future<void> write(Uint8List bytes) async {
    if (_closing || _exited.isCompleted) {
      throw StateError('Serial writer is closed');
    }
    if (_pending.length >= _maxPendingWrites ||
        _pendingBytes + bytes.length > _maxPendingBytes) {
      throw StateError('Serial write queue is full');
    }
    final id = _nextId++;
    final done = Completer<void>();
    final copy = Uint8List.fromList(bytes);
    _pending[id] = (done, copy.length);
    _pendingBytes += copy.length;
    _ready.future.then(
      (commands) => commands.send((id, copy)),
      onError: (Object _, StackTrace _) {},
    );
    return done.future;
  }

  Future<void> close() {
    if (!_closing) {
      _closing = true;
      _ready.future.then(
        (commands) => commands.send(null),
        onError: (Object _, StackTrace _) {},
      );
    }
    return _exited.future;
  }

  void _receive(dynamic message) {
    if (message is SendPort) {
      _ready.complete(message);
    } else if (message is (int, Object?, StackTrace?)) {
      final pending = _pending.remove(message.$1);
      if (pending == null) return;
      _pendingBytes -= pending.$2;
      if (message.$2 == null) {
        pending.$1.complete();
      } else {
        pending.$1.completeError(message.$2!, message.$3);
      }
    } else if (message is List) {
      _failPending(
        StateError('${message[0]}'),
        StackTrace.fromString('${message[1]}'),
      );
    } else if (message == null) {
      final error = StateError('Serial writer stopped');
      if (!_ready.isCompleted) _ready.completeError(error);
      _failPending(error, StackTrace.current);
      _messages.close();
      _exited.complete();
    }
  }

  void _failPending(Object error, StackTrace stack) {
    for (final (done, _) in _pending.values) {
      done.completeError(error, stack);
    }
    _pending.clear();
    _pendingBytes = 0;
  }

  static Future<void> _run((int, SendPort) args) async {
    final port = SerialPort.fromAddress(args.$1);
    final commands = ReceivePort();
    args.$2.send(commands.sendPort);
    try {
      await for (final message in commands) {
        if (message == null) break;
        final (id, bytes) = message as (int, Uint8List);
        try {
          await _write(port, bytes);
          args.$2.send((id, null, null));
        } catch (error, stack) {
          args.$2.send((id, error, stack));
          break;
        }
      }
    } finally {
      commands.close();
    }
  }

  static Future<void> _write(SerialPort port, Uint8List command) async {
    var offset = 0;
    while (offset < command.length) {
      final chunk = offset == 0
          ? command
          : Uint8List.sublistView(command, offset);
      final written = await port.write(chunk, timeout: _writeTimeoutMs);
      if (written < 0) {
        throw StateError('Serial write failed: ${SerialPort.lastError}');
      }
      if (written == 0) {
        throw StateError(
          'Serial write stalled (0 bytes in ${_writeTimeoutMs}ms)',
        );
      }
      offset += written;
    }
    await drainWithTimeout(bytesToWrite: () => port.bytesToWrite);
    if (Platform.isLinux || Platform.isMacOS) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}
