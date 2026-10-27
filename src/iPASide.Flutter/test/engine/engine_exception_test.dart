import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/engine/engine_exception.dart';

void main() {
  group('EngineException.cleanError', () {
    test('null becomes the literal "error"', () {
      expect(EngineException.cleanError(null), 'error');
    });

    test('passes an ordinary message through, trimmed', () {
      expect(
        EngineException.cleanError('  Apple rejected the request.  '),
        'Apple rejected the request.',
      );
    });

    test('strips the exit-code banner', () {
      expect(
        EngineException.cleanError(
          'Engine exited with code 1. Invalid credentials',
        ),
        'Invalid credentials',
      );
    });

    test('strips a multi-digit exit code and following newlines', () {
      expect(
        EngineException.cleanError('Engine exited with code 137.\n\tkilled'),
        'killed',
      );
    });

    test('strips each phase prefix', () {
      expect(
        EngineException.cleanError('Login failed: bad password'),
        'bad password',
      );
      expect(
        EngineException.cleanError('Sideload failed: no device'),
        'no device',
      );
      expect(
        EngineException.cleanError('Signing failed: zsign missing'),
        'zsign missing',
      );
      expect(
        EngineException.cleanError('Provisioning failed: no slots'),
        'no slots',
      );
    });

    test('matches phase prefixes case-insensitively', () {
      expect(
        EngineException.cleanError('SIGNING failed:   entitlements'),
        'entitlements',
      );
    });

    test('strips the exit-code banner and the phase prefix together', () {
      expect(
        EngineException.cleanError(
          'Engine exited with code 1. Sideload failed: device is locked',
        ),
        'device is locked',
      );
    });

    test('only strips a leading prefix, never one in the middle', () {
      expect(
        EngineException.cleanError('retry after Login failed: nope'),
        'retry after Login failed: nope',
      );
    });

    test('leaves a similar-but-different banner alone', () {
      expect(
        EngineException.cleanError('Engine exited with code X. boom'),
        'Engine exited with code X. boom',
      );
    });

    test('an empty message stays empty', () {
      expect(EngineException.cleanError(''), '');
      expect(EngineException.cleanError('   '), '');
    });
  });

  group('EngineException.fromResult', () {
    test('prefers the structured error on the data object', () {
      final EngineException error = EngineException.fromResult(
        <String, dynamic>{'status': 'error', 'error': 'Login failed: 2FA'},
        'Engine exited with code 1. noise',
      );
      expect(error.message, '2FA');
    });

    test('falls back to the frame error when data carries none', () {
      final EngineException error = EngineException.fromResult(
        <String, dynamic>{'status': 'error'},
        'Signing failed: bad cert',
      );
      expect(error.message, 'bad cert');
    });

    test('falls back to the frame error when data is not an object', () {
      final EngineException error =
          EngineException.fromResult(<Object?>[1, 2], 'boom');
      expect(error.message, 'boom');
    });

    test('ignores a blank structured error', () {
      final EngineException error = EngineException.fromResult(
        <String, dynamic>{'error': '   '},
        'real cause',
      );
      expect(error.message, 'real cause');
    });

    test('ignores a non-string structured error', () {
      final EngineException error = EngineException.fromResult(
        <String, dynamic>{'error': 42},
        'real cause',
      );
      expect(error.message, 'real cause');
    });

    test('uses the generic fallback when nothing is usable', () {
      expect(EngineException.fromResult(null, null).message, 'engine error');
      expect(EngineException.fromResult(null, '  ').message, 'engine error');
    });
  });

  group('exception hierarchy', () {
    test('shutdown and disposed are catchable as EngineException', () {
      expect(EngineShutdownException(), isA<EngineException>());
      expect(EngineDisposedException(), isA<EngineException>());
    });

    test('shutdown carries the documented default message', () {
      expect(
        EngineShutdownException().message,
        'The engine was shut down while a request was in flight.',
      );
    });

    test('toString names the concrete failure', () {
      expect(EngineException('boom').toString(), 'EngineException: boom');
      expect(
        EngineDisposedException().toString(),
        'EngineDisposedException: The engine client has been disposed.',
      );
    });
  });
}
