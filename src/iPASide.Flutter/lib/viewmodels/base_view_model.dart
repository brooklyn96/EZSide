import 'package:flutter/foundation.dart';
import '../engine/engine.dart';

/// Shared plumbing for the screen view models.
///
/// Loads are kicked off in constructors and can outlive the screen that
/// started them, so notification has to be disposal-safe.
abstract class BaseViewModel extends ChangeNotifier {
  bool _disposed = false;

  bool get isDisposed => _disposed;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Notifies listeners unless this model has already been torn down.
  @protected
  void notify() {
    if (!_disposed) notifyListeners();
  }

  /// Cleaned, user-presentable text for anything thrown by the engine layer.
  ///
  /// [EngineException.message] is already cleaned; anything else is run
  /// through the same scrubbing so stray prefixes never reach the UI.
  @protected
  static String errorText(Object error) => error is EngineException
      ? error.message
      : EngineException.cleanError(error.toString());

  /// Whether an error means the app is closing and should be ignored.
  @protected
  static bool isShutdown(Object error) => error is EngineShutdownException;
}
