import 'dart:async';

/// A [StreamSubscription] whose [cancel] completes immediately while event
/// delivery is delegated to an underlying subscription.
///
/// Standard stream `cancel()` futures never complete under `fakeAsync`
/// (plain `StreamController`, broadcast, single-sub, and rxdart alike).
/// Production code should keep `await subscription.cancel()`; test doubles
/// whose streams are cancelled under fake time can expose them through
/// [CompletingCancelStream] instead.
class CompletingCancelSubscription<T> implements StreamSubscription<T> {
  CompletingCancelSubscription(this._inner);

  final StreamSubscription<T> _inner;

  @override
  Future<void> cancel() {
    unawaited(_inner.cancel());
    return Future<void>.value();
  }

  @override
  void onData(void Function(T event)? handle) => _inner.onData(handle);

  @override
  void onError(Function? handle) => _inner.onError(handle);

  @override
  void onDone(void Function()? handle) => _inner.onDone(handle);

  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);

  @override
  void resume() => _inner.resume();

  @override
  bool get isPaused => _inner.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _inner.asFuture<E>(futureValue);
}

/// Stream wrapper whose subscription cancels complete immediately, even
/// under `fakeAsync`. Event delivery is delegated to the wrapped controller.
class CompletingCancelStream<T> extends Stream<T> {
  CompletingCancelStream(this._controller);

  final StreamController<T> _controller;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return CompletingCancelSubscription(
      _controller.stream.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      ),
    );
  }
}
