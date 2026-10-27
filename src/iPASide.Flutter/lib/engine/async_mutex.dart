// Stands in for the C# client's SemaphoreSlim(1, 1) request gate. Written by
// hand rather than pulled from package:synchronized so the engine layer adds no
// dependency.

import 'dart:async';
import 'dart:collection';

/// A non-reentrant, FIFO async lock: at most one holder at a time.
///
/// Waiters are woken in the order they arrived, and ownership is handed straight
/// from [release] to the next waiter (the lock is never momentarily free), which
/// is what lets teardown rely on "the gate is mine, so nobody is touching the
/// engine streams".
class AsyncMutex {
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();
  bool _held = false;

  /// Whether the lock is currently held.
  bool get isHeld => _held;

  /// Number of callers parked in [acquire].
  int get waiterCount => _waiters.length;

  /// Takes the lock, waiting for it if necessary.
  Future<void> acquire() {
    if (!_held) {
      _held = true;
      return Future<void>.value();
    }
    final Completer<void> waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  /// Takes the lock only if it is free right now. Never waits.
  bool tryAcquire() {
    if (_held) {
      return false;
    }
    _held = true;
    return true;
  }

  /// Takes the lock, giving up after [timeout].
  ///
  /// Returns whether the lock is now held. A caller that gave up is removed
  /// from the queue, so a later [release] cannot hand the lock to nobody; if
  /// ownership arrives in the same turn the timer fires, it is released again
  /// immediately.
  Future<bool> acquireWithin(Duration timeout) {
    if (tryAcquire()) {
      return Future<bool>.value(true);
    }

    final Completer<void> waiter = Completer<void>();
    final Completer<bool> outcome = Completer<bool>();
    _waiters.add(waiter);

    final Timer timer = Timer(timeout, () {
      if (outcome.isCompleted) {
        return;
      }
      _waiters.remove(waiter);
      outcome.complete(false);
    });

    waiter.future.then((_) {
      if (outcome.isCompleted) {
        release();
        return;
      }
      timer.cancel();
      outcome.complete(true);
    });

    return outcome.future;
  }

  /// Releases the lock, handing it to the longest-waiting caller if any.
  ///
  /// Throws [StateError] when the lock is not held - that always means a
  /// mismatched acquire/release pair, which would otherwise corrupt the gate
  /// silently.
  void release() {
    if (!_held) {
      throw StateError('AsyncMutex.release() called while the lock was free.');
    }
    if (_waiters.isEmpty) {
      _held = false;
      return;
    }
    // Stay held: ownership transfers directly to the woken waiter.
    _waiters.removeFirst().complete();
  }

  /// Runs [action] while holding the lock, releasing it on every exit path.
  Future<T> run<T>(Future<T> Function() action) async {
    await acquire();
    try {
      return await action();
    } finally {
      release();
    }
  }
}
