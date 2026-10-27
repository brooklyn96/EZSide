import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/async_mutex.dart';

void main() {
  group('AsyncMutex', () {
    test('acquire on a free lock does not wait', () async {
      final AsyncMutex mutex = AsyncMutex();
      expect(mutex.isHeld, isFalse);
      await mutex.acquire();
      expect(mutex.isHeld, isTrue);
      mutex.release();
      expect(mutex.isHeld, isFalse);
    });

    test('never lets two bodies overlap', () async {
      final AsyncMutex mutex = AsyncMutex();
      int active = 0;
      int peak = 0;

      Future<void> task() => mutex.run(() async {
            active++;
            if (active > peak) {
              peak = active;
            }
            await Future<void>.delayed(Duration.zero);
            active--;
          });

      await Future.wait<void>(<Future<void>>[task(), task(), task()]);

      expect(peak, 1);
      expect(mutex.isHeld, isFalse);
    });

    test('wakes waiters in arrival order', () async {
      final AsyncMutex mutex = AsyncMutex();
      final List<int> order = <int>[];
      await mutex.acquire();

      final List<Future<void>> waiters = <Future<void>>[
        for (int i = 0; i < 3; i++)
          mutex.acquire().then((_) {
            order.add(i);
            mutex.release();
          }),
      ];

      expect(mutex.waiterCount, 3);
      mutex.release();
      await Future.wait<void>(waiters);

      expect(order, <int>[0, 1, 2]);
      expect(mutex.isHeld, isFalse);
    });

    test('run releases the lock even when the body throws', () async {
      final AsyncMutex mutex = AsyncMutex();

      await expectLater(
        mutex.run<void>(() async => throw StateError('boom')),
        throwsStateError,
      );

      expect(mutex.isHeld, isFalse);
      expect(mutex.tryAcquire(), isTrue);
    });

    test('tryAcquire only succeeds on a free lock', () async {
      final AsyncMutex mutex = AsyncMutex();
      expect(mutex.tryAcquire(), isTrue);
      expect(mutex.tryAcquire(), isFalse);
      mutex.release();
      expect(mutex.tryAcquire(), isTrue);
    });

    test('releasing a free lock is a programming error', () {
      expect(AsyncMutex().release, throwsStateError);
    });

    test('acquireWithin takes a free lock immediately', () async {
      final AsyncMutex mutex = AsyncMutex();
      expect(
        await mutex.acquireWithin(const Duration(milliseconds: 5)),
        isTrue,
      );
      expect(mutex.isHeld, isTrue);
    });

    test('acquireWithin gives up and leaves no phantom waiter', () async {
      final AsyncMutex mutex = AsyncMutex();
      await mutex.acquire();

      expect(
        await mutex.acquireWithin(const Duration(milliseconds: 10)),
        isFalse,
      );
      expect(mutex.waiterCount, 0);

      // The abandoned waiter must not receive ownership nobody will release.
      mutex.release();
      expect(mutex.isHeld, isFalse);
    });

    test('acquireWithin succeeds when the lock frees up in time', () async {
      final AsyncMutex mutex = AsyncMutex();
      await mutex.acquire();
      Future<void>.delayed(const Duration(milliseconds: 5), mutex.release);

      expect(
        await mutex.acquireWithin(const Duration(seconds: 5)),
        isTrue,
      );
      expect(mutex.isHeld, isTrue);
      mutex.release();
    });

    test('a queued acquire still wins after a neighbour timed out', () async {
      final AsyncMutex mutex = AsyncMutex();
      await mutex.acquire();

      final Future<bool> abandoned =
          mutex.acquireWithin(const Duration(milliseconds: 10));
      final Future<void> patient = mutex.acquire();

      expect(await abandoned, isFalse);
      mutex.release();
      await patient;

      expect(mutex.isHeld, isTrue);
      mutex.release();
    });
  });
}
