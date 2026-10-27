// Ported from iPASide.App/Engine/EngineException.cs and
// EngineShutdownException.cs.

/// Surfaces a failed engine command.
///
/// The message prefers the engine's own structured error
/// (`{"status":"error","error":...}`) over raw stderr and is cleaned with
/// [EngineException.cleanError], so the UI can bind [message] directly.
///
/// Every failure the engine layer raises derives from this type. The C# client
/// used unrelated exception types for teardown races
/// (`EngineShutdownException`, `ObjectDisposedException`); here they are
/// subclasses so a UI-level `on EngineException` handler cannot be bypassed by
/// an app-close race, while `on EngineShutdownException` still distinguishes
/// them.
class EngineException implements Exception {
  /// Creates a failure carrying an already-cleaned [message].
  EngineException(this.message);

  /// Builds a failure from a result frame's [data] payload and [error] text.
  ///
  /// A `{"error": "..."}` field on the data object (the engine's structured
  /// message) wins over the frame's error text, which in turn wins over a
  /// generic fallback. The winner is then run through [cleanError].
  factory EngineException.fromResult(Object? data, String? error) {
    String? apiError;
    if (data is Map<String, dynamic>) {
      final Object? value = data['error'];
      if (value is String) {
        apiError = value;
      }
    }

    final String detail;
    if (apiError != null && apiError.trim().isNotEmpty) {
      detail = apiError;
    } else if (error != null && error.trim().isNotEmpty) {
      detail = error;
    } else {
      detail = 'engine error';
    }

    return EngineException(cleanError(detail));
  }

  /// The cleaned, user-presentable failure text.
  final String message;

  // Drops the generic "Engine exited with code N." banner and the
  // "<Phase> failed:" prefixes so the user sees only the cause.
  static final RegExp _exitCodePrefix =
      RegExp(r'^Engine exited with code \d+\.\s*');

  static final RegExp _phaseFailedPrefix = RegExp(
    r'^(Login|Sideload|Signing|Provisioning) failed:\s*',
    caseSensitive: false,
  );

  /// Strips the legacy noise prefixes and trims.
  ///
  /// A null [message] becomes the literal `error`, matching the C# client.
  static String cleanError(String? message) {
    String text = message ?? 'error';
    text = text.replaceFirst(_exitCodePrefix, '');
    text = text.replaceFirst(_phaseFailedPrefix, '');
    return text.trim();
  }

  @override
  String toString() => 'EngineException: $message';
}

/// Faults an in-flight request whose frame stream was broken by teardown.
///
/// Distinct from [EngineDisposedException] - which signals a call that arrived
/// *after* teardown - so the UI can swallow this one silently during app close
/// while still surfacing genuine misuse.
class EngineShutdownException extends EngineException {
  /// Creates a shutdown fault, defaulting to the standard message.
  EngineShutdownException([
    super.message = 'The engine was shut down while a request was in flight.',
  ]);

  @override
  String toString() => 'EngineShutdownException: $message';
}

/// Rejects a call made after the client was disposed.
///
/// Stands in for C#'s `ObjectDisposedException`, which Dart has no equivalent
/// of.
class EngineDisposedException extends EngineException {
  /// Creates a disposed-client fault, defaulting to the standard message.
  EngineDisposedException([
    super.message = 'The engine client has been disposed.',
  ]);

  @override
  String toString() => 'EngineDisposedException: $message';
}
