// The shell's file dialog, reached the way lib/platform reaches the rest of
// Win32: package:win32 plus dart:ffi, with no plugin in between.

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

/// One entry in a file dialog's file-type dropdown.
@immutable
class FileDialogFilter {
  /// Creates a filter listed as [label] that matches [spec].
  const FileDialogFilter({required this.label, required this.spec});

  /// Friendly name shown in the dropdown, e.g. `iOS app (*.ipa)`.
  final String label;

  /// Semicolon-separated patterns, e.g. `*.deb;*.dylib`.
  final String spec;

  /// The unrestricted entry Windows apps conventionally offer last, so a file
  /// carrying the wrong extension is still reachable.
  static const FileDialogFilter allFiles = FileDialogFilter(
    label: 'All files (*.*)',
    spec: '*.*',
  );

  @override
  bool operator ==(Object other) =>
      other is FileDialogFilter && other.label == label && other.spec == spec;

  @override
  int get hashCode => Object.hash(label, spec);

  @override
  String toString() => 'FileDialogFilter($label, $spec)';
}

/// The Windows "open" dialog, driven through COM, for both files and folders.
///
/// `IFileOpenDialog` is the dialog every modern Windows app shows, and unlike
/// `package:file_selector` it takes a title. Driving it here also keeps the app
/// on one `win32`: `package:file_picker`, the other package that can set a
/// title, pins `win32 ^5.9.0` against the `^6.3.0` the Job Object and mutex
/// code is built on.
abstract final class WindowsFileDialog {
  /// `HRESULT_FROM_WIN32(ERROR_CANCELLED)`, which is how the shell reports that
  /// the user closed the dialog instead of choosing something.
  static final HRESULT _cancelled = ERROR_CANCELLED.toHRESULT();

  /// Shows an open dialog headed [title] and returns what the user chose.
  ///
  /// [filters] fills the file-type dropdown, most specific first, and the first
  /// entry starts selected. Only an [allowMultiple] dialog returns more than one
  /// path.
  ///
  /// Returns an empty list when the user cancels: that is the ordinary way out
  /// of a file dialog, not an error.
  ///
  /// Windows only, and blocks the calling thread until the dialog closes —
  /// which is what being modal means.
  static List<String> open({
    required String title,
    required List<FileDialogFilter> filters,
    bool allowMultiple = false,
  }) {
    assert(filters.isNotEmpty, 'The shell needs at least one file type.');

    return _show<List<String>>(
      title: title,
      noSelection: const <String>[],
      configure: (IFileOpenDialog dialog, Arena arena) {
        dialog.setFileTypes(filters.length, filterSpecs(filters, arena));
        // One-based; the caller ordered the filters deliberately.
        dialog.setFileTypeIndex(1);
        dialog.setOptions(
          fileOptions(dialog.getOptions(), allowMultiple: allowMultiple),
        );
      },
      selection: (IFileOpenDialog dialog) =>
          allowMultiple ? _everyResult(dialog) : _oneResult(dialog),
    );
  }

  /// Shows the same dialog in folder-picking mode and returns the folder the
  /// user chose, or null when they cancelled.
  ///
  /// This is `IFileOpenDialog` with `FOS_PICKFOLDERS`, which is what every
  /// modern Windows app shows for a folder — not the cramped
  /// `SHBrowseForFolder` tree, and not a second dialog implementation: it takes
  /// the same title, the same apartment handling and the same
  /// `SIGDN_FILESYSPATH` extraction as [open].
  ///
  /// Windows only, and modal, exactly like [open].
  static String? openFolder({required String title}) => _show<String?>(
        title: title,
        noSelection: null,
        configure: (IFileOpenDialog dialog, Arena _) =>
            dialog.setOptions(folderOptions(dialog.getOptions())),
        selection: (IFileOpenDialog dialog) {
          final List<String> chosen = _oneResult(dialog);
          return chosen.isEmpty ? null : chosen.first;
        },
      );

  /// Shows a save dialog headed [title] and returns the path the user chose.
  ///
  /// [filters] fills the file-type dropdown the same way [open] does.
  /// [fileName] is the name the box starts with; [defaultExtension] is appended
  /// when the user types a name with no suffix. Returns null when they cancel.
  ///
  /// Windows only, and modal, exactly like [open].
  static String? save({
    required String title,
    required List<FileDialogFilter> filters,
    String? fileName,
    String? defaultExtension,
  }) {
    assert(filters.isNotEmpty, 'The shell needs at least one file type.');

    return _showSave(
      title: title,
      configure: (IFileSaveDialog dialog, Arena arena) {
        dialog.setFileTypes(filters.length, filterSpecs(filters, arena));
        dialog.setFileTypeIndex(1);
        dialog.setOptions(saveOptions(dialog.getOptions()));
        if (fileName != null && fileName.isNotEmpty) {
          dialog.setFileName(fileName.toPcwstr(allocator: arena));
        }
        if (defaultExtension != null && defaultExtension.isNotEmpty) {
          dialog.setDefaultExtension(
            defaultExtension.toPcwstr(allocator: arena),
          );
        }
      },
    );
  }

  /// Opens a dialog headed [title], hands it to [configure], shows it, and
  /// returns what [selection] reads back.
  ///
  /// Everything that is the same for every kind of dialog lives here: the
  /// apartment, the COM object's lifetime, the arena backing the strings the
  /// shell is given, and the decision that a cancel is not an error.
  ///
  /// [noSelection] is returned both when the user cancels and when the shell
  /// cannot open a dialog at all, which is logged: nothing the user could do
  /// would help, and a missing window is not worth taking the app down for.
  static R _show<R>({
    required String title,
    required R noSelection,
    required void Function(IFileOpenDialog dialog, Arena arena) configure,
    required R Function(IFileOpenDialog dialog) selection,
  }) {
    final bool ownsApartment = _enterApartment();
    try {
      final IFileOpenDialog dialog = createInstance<IFileOpenDialog>(
        FileOpenDialog,
      );
      try {
        return using<R>((Arena arena) {
          dialog.setTitle(title.toPcwstr(allocator: arena));
          configure(dialog, arena);
          dialog.show(_ownerWindow());

          return selection(dialog);
        });
      } finally {
        dialog.release();
      }
    } on WindowsException catch (error) {
      if (error.hr != _cancelled) debugPrint('[file dialog] $title: $error');
      return noSelection;
    } finally {
      if (ownsApartment) CoUninitialize();
    }
  }

  /// The save-dialog counterpart of [_show]: same apartment, same cancel
  /// handling, a different COM class because `IFileSaveDialog` is what the
  /// shell uses when the file does not have to exist yet.
  static String? _showSave({
    required String title,
    required void Function(IFileSaveDialog dialog, Arena arena) configure,
  }) {
    final bool ownsApartment = _enterApartment();
    try {
      final IFileSaveDialog dialog = createInstance<IFileSaveDialog>(
        FileSaveDialog,
      );
      try {
        return using<String?>((Arena arena) {
          dialog.setTitle(title.toPcwstr(allocator: arena));
          configure(dialog, arena);
          dialog.show(_ownerWindow());

          final IShellItem? item = dialog.getResult();
          if (item == null) return null;
          try {
            return _pathOf(item);
          } finally {
            item.release();
          }
        });
      } finally {
        dialog.release();
      }
    } on WindowsException catch (error) {
      if (error.hr != _cancelled) debugPrint('[file dialog] $title: $error');
      return null;
    } finally {
      if (ownsApartment) CoUninitialize();
    }
  }

  /// Joins a single-threaded apartment when this thread has none.
  ///
  /// `windows/runner/main.cpp` already calls `CoInitializeEx` with
  /// `COINIT_APARTMENTTHREADED`, but on the thread running the message loop;
  /// whether that is the thread Dart executes on depends on the embedder's
  /// task-runner setup, and a `flutter test` isolate has no apartment at all.
  ///
  /// Returns whether the caller now owns the matching [CoUninitialize]. An
  /// apartment somebody else entered is left for them to leave.
  static bool _enterApartment() {
    if (isComInitialized) return false;
    return CoInitializeEx(COINIT_APARTMENTTHREADED).isOk;
  }

  /// The file-dialog flags: whatever the shell defaults to in [current], plus
  /// the ones that make the result usable.
  ///
  /// `FOS_FORCEFILESYSTEM` is the reason [_pathOf] can rely on
  /// `SIGDN_FILESYSPATH`: without it the user can pick a library entry or a
  /// phone browsed over MTP, neither of which has a path on this machine.
  ///
  /// OR-ed into what the dialog already reports rather than set absolutely, so
  /// the shell keeps its own defaults for everything not named here.
  @visibleForTesting
  static FILEOPENDIALOGOPTIONS fileOptions(
    FILEOPENDIALOGOPTIONS current, {
    required bool allowMultiple,
  }) {
    FILEOPENDIALOGOPTIONS options =
        current | FOS_FILEMUSTEXIST | FOS_PATHMUSTEXIST | FOS_FORCEFILESYSTEM;
    if (allowMultiple) options |= FOS_ALLOWMULTISELECT;
    return options;
  }

  /// The folder-dialog flags, from the same starting point as [fileOptions].
  ///
  /// `FOS_PICKFOLDERS` is what turns this dialog into a folder picker.
  /// `FOS_FILEMUSTEXIST` is deliberately absent: it constrains a file name that
  /// a folder dialog never collects, and `FOS_PATHMUSTEXIST` is the equivalent
  /// promise for what is actually being chosen — which is what lets the caller
  /// treat a returned folder as one that exists.
  @visibleForTesting
  static FILEOPENDIALOGOPTIONS folderOptions(FILEOPENDIALOGOPTIONS current) =>
      current | FOS_PICKFOLDERS | FOS_PATHMUSTEXIST | FOS_FORCEFILESYSTEM;

  /// The save-dialog flags: a real folder, a prompt before overwrite, no
  /// demand that the file already exist.
  ///
  /// `FOS_FILEMUSTEXIST` is the open-dialog constraint and would make Save
  /// refuse a name the user is trying to create. `FOS_OVERWRITEPROMPT` is what
  /// every Windows save dialog shows instead.
  @visibleForTesting
  static FILEOPENDIALOGOPTIONS saveOptions(FILEOPENDIALOGOPTIONS current) =>
      current |
      FOS_PATHMUSTEXIST |
      FOS_OVERWRITEPROMPT |
      FOS_FORCEFILESYSTEM;

  /// [filters] marshalled into the contiguous `COMDLG_FILTERSPEC` array
  /// `SetFileTypes` expects, with the array and every string it points at owned
  /// by [allocator].
  @visibleForTesting
  static Pointer<COMDLG_FILTERSPEC> filterSpecs(
    List<FileDialogFilter> filters,
    Allocator allocator,
  ) {
    final Pointer<COMDLG_FILTERSPEC> specs = allocator<COMDLG_FILTERSPEC>(
      filters.length,
    );
    for (int i = 0; i < filters.length; i++) {
      specs[i].pszName = filters[i].label.toPwstr(allocator: allocator);
      specs[i].pszSpec = filters[i].spec.toPwstr(allocator: allocator);
    }
    return specs;
  }

  /// The usable path inside a display name the shell handed back, or null when
  /// there is none.
  ///
  /// Split out from [_pathOf] so the decoding can be exercised without a dialog;
  /// ownership of [name] stays with the caller.
  @visibleForTesting
  static String? decodeDisplayName(PWSTR name) {
    if (name.isNull) return null;
    final String path = name.toDartString();
    return path.isEmpty ? null : path;
  }

  /// The window to be modal to, or null when this thread owns none.
  ///
  /// `Show` runs its modal loop on the calling thread, and only a window from
  /// that thread's queue can be disabled safely for the duration; a cross-thread
  /// owner invites focus and input-queue trouble. Unowned is the honest
  /// fallback — the shell places the dialog itself.
  static HWND? _ownerWindow() {
    final HWND active = GetActiveWindow();
    return active.isNull ? null : active;
  }

  /// The single selection of a dialog opened without `FOS_ALLOWMULTISELECT`.
  static List<String> _oneResult(IFileOpenDialog dialog) {
    final IShellItem? item = dialog.getResult();
    if (item == null) return const <String>[];
    try {
      final String? path = _pathOf(item);
      return path == null ? const <String>[] : <String>[path];
    } finally {
      item.release();
    }
  }

  /// Every selection of a dialog opened with `FOS_ALLOWMULTISELECT`.
  static List<String> _everyResult(IFileOpenDialog dialog) {
    final IShellItemArray? items = dialog.getResults();
    if (items == null) return const <String>[];
    try {
      final List<String> paths = <String>[];
      final int count = items.getCount();
      for (int i = 0; i < count; i++) {
        final IShellItem? item = items.getItemAt(i);
        if (item == null) continue;
        try {
          final String? path = _pathOf(item);
          if (path != null) paths.add(path);
        } finally {
          item.release();
        }
      }
      return paths;
    } finally {
      items.release();
    }
  }

  /// [item]'s path on this machine, or null for anything the shell will not name
  /// as a file — dropped per item so one odd selection cannot lose the rest.
  static String? _pathOf(IShellItem item) {
    final PWSTR name;
    try {
      name = item.getDisplayName(SIGDN_FILESYSPATH);
    } on WindowsException catch (error) {
      debugPrint('[file dialog] item has no path: $error');
      return null;
    }
    try {
      return decodeDisplayName(name);
    } finally {
      // GetDisplayName hands back a shell allocation, not one of ours, and
      // CoTaskMemFree tolerates the null a refusing shell can hand over.
      CoTaskMemFree(name);
    }
  }
}
