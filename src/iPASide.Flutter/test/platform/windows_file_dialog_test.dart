import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ipaside/platform/windows_file_dialog.dart';
import 'package:win32/win32.dart';

/// A `PWSTR` holding [value], released when the running test ends.
PWSTR _pwstr(String value) {
  final PWSTR pointer = value.toPwstr(allocator: calloc);
  addTearDown(() => calloc.free(pointer));
  return pointer;
}

void main() {
  group('FileDialogFilter', () {
    test('is a value type, so const filter lists can be compared', () {
      const FileDialogFilter ipa = FileDialogFilter(
        label: 'iOS app (*.ipa)',
        spec: '*.ipa',
      );

      expect(
        ipa,
        const FileDialogFilter(label: 'iOS app (*.ipa)', spec: '*.ipa'),
      );
      expect(
        ipa.hashCode,
        const FileDialogFilter(
          label: 'iOS app (*.ipa)',
          spec: '*.ipa',
        ).hashCode,
      );
      expect(
        ipa,
        isNot(const FileDialogFilter(label: 'iOS app (*.ipa)', spec: '*.*')),
      );
      expect(
        ipa,
        isNot(const FileDialogFilter(label: 'Anything', spec: '*.ipa')),
      );
    });

    test('carries both halves in toString, for the failure log', () {
      expect(
        const FileDialogFilter(
          label: 'Tweaks',
          spec: '*.deb;*.dylib',
        ).toString(),
        'FileDialogFilter(Tweaks, *.deb;*.dylib)',
      );
    });

    test('the shared all-files entry is the shell wildcard', () {
      expect(FileDialogFilter.allFiles.label, 'All files (*.*)');
      expect(FileDialogFilter.allFiles.spec, '*.*');
    });
  });

  group('filterSpecs', () {
    test('marshals every filter into one contiguous array, in order', () {
      const List<FileDialogFilter> filters = <FileDialogFilter>[
        FileDialogFilter(
          label: 'Tweaks (*.deb;*.dylib)',
          spec: '*.deb;*.dylib',
        ),
        FileDialogFilter.allFiles,
      ];

      using((Arena arena) {
        final Pointer<COMDLG_FILTERSPEC> specs = WindowsFileDialog.filterSpecs(
          filters,
          arena,
        );

        // Reading back through the same pointer arithmetic SetFileTypes uses is
        // what proves this is one array rather than two lone structs.
        expect(specs[0].pszName.toDartString(), 'Tweaks (*.deb;*.dylib)');
        expect(specs[0].pszSpec.toDartString(), '*.deb;*.dylib');
        expect(specs[1].pszName.toDartString(), 'All files (*.*)');
        expect(specs[1].pszSpec.toDartString(), '*.*');
      });
    });

    test('a single filter still produces a usable array', () {
      using((Arena arena) {
        final Pointer<COMDLG_FILTERSPEC> specs = WindowsFileDialog.filterSpecs(
          const <FileDialogFilter>[
            FileDialogFilter(label: 'iOS app (*.ipa)', spec: '*.ipa'),
          ],
          arena,
        );

        expect(specs[0].pszName.toDartString(), 'iOS app (*.ipa)');
        expect(specs[0].pszSpec.toDartString(), '*.ipa');
      });
    });

    test('non-ASCII labels survive the round trip as UTF-16', () {
      using((Arena arena) {
        final Pointer<COMDLG_FILTERSPEC> specs = WindowsFileDialog.filterSpecs(
          const <FileDialogFilter>[
            FileDialogFilter(
              label: 'Vorlage \u2014 \u00fcber (*.ipa)',
              spec: '*.ipa',
            ),
          ],
          arena,
        );

        expect(
          specs[0].pszName.toDartString(),
          'Vorlage \u2014 \u00fcber (*.ipa)',
        );
      });
    });
  });

  group('dialog options', () {
    /// What a dialog reports before anything is set: the shell's own defaults.
    const FILEOPENDIALOGOPTIONS shellDefaults = FILEOPENDIALOGOPTIONS(
      FOS_NOCHANGEDIR,
    );

    test('a file dialog demands a real file at a real path', () {
      final FILEOPENDIALOGOPTIONS options = WindowsFileDialog.fileOptions(
        shellDefaults,
        allowMultiple: false,
      );

      expect(options.has(FOS_FILEMUSTEXIST), isTrue);
      expect(options.has(FOS_PATHMUSTEXIST), isTrue);
      expect(options.has(FOS_FORCEFILESYSTEM), isTrue);
      expect(options.has(FOS_ALLOWMULTISELECT), isFalse);
      expect(options.has(FOS_PICKFOLDERS), isFalse);
    });

    test('multi-select is the only difference the flag makes', () {
      expect(
        WindowsFileDialog.fileOptions(shellDefaults, allowMultiple: true),
        WindowsFileDialog.fileOptions(shellDefaults, allowMultiple: false) |
            FOS_ALLOWMULTISELECT,
      );
    });

    test('a folder dialog picks folders, and asks for no file name', () {
      final FILEOPENDIALOGOPTIONS options = WindowsFileDialog.folderOptions(
        shellDefaults,
      );

      expect(options.has(FOS_PICKFOLDERS), isTrue);
      expect(options.has(FOS_PATHMUSTEXIST), isTrue);
      expect(options.has(FOS_FORCEFILESYSTEM), isTrue);
      expect(
        options.has(FOS_FILEMUSTEXIST),
        isFalse,
        reason: 'a folder dialog collects no file name to constrain',
      );
      expect(options.has(FOS_ALLOWMULTISELECT), isFalse);
    });

    test('the shell keeps every default neither of them names', () {
      // OR-ed in, never set absolutely: whatever the shell already wanted for
      // this dialog survives.
      expect(
        WindowsFileDialog.fileOptions(
          shellDefaults,
          allowMultiple: false,
        ).has(FOS_NOCHANGEDIR),
        isTrue,
      );
      expect(
        WindowsFileDialog.folderOptions(shellDefaults).has(FOS_NOCHANGEDIR),
        isTrue,
      );
    });

    test('applying them twice changes nothing', () {
      final FILEOPENDIALOGOPTIONS once = WindowsFileDialog.folderOptions(
        shellDefaults,
      );

      expect(WindowsFileDialog.folderOptions(once), once);
    });

    test('a save dialog asks the folder to exist, and the file not to', () {
      final FILEOPENDIALOGOPTIONS options = WindowsFileDialog.saveOptions(
        shellDefaults,
      );

      expect(options.has(FOS_PATHMUSTEXIST), isTrue);
      expect(options.has(FOS_FORCEFILESYSTEM), isTrue);
      expect(options.has(FOS_OVERWRITEPROMPT), isTrue);
      expect(
        options.has(FOS_FILEMUSTEXIST),
        isFalse,
        reason: 'Save is how a file that does not exist yet is created',
      );
      expect(options.has(FOS_PICKFOLDERS), isFalse);
    });
  });

  group('decodeDisplayName', () {
    test('reads back the path the shell wrote', () {
      expect(
        WindowsFileDialog.decodeDisplayName(
          _pwstr(r'C:\Users\me\Downloads\app.ipa'),
        ),
        r'C:\Users\me\Downloads\app.ipa',
      );
    });

    test('keeps spaces and non-ASCII characters intact', () {
      const String path = 'C:\\Users\\me\\My Apps\\caf\u00e9 \u2014 v2.ipa';

      expect(WindowsFileDialog.decodeDisplayName(_pwstr(path)), path);
    });

    test('a UNC path is returned unchanged', () {
      expect(
        WindowsFileDialog.decodeDisplayName(_pwstr(r'\\nas\share\app.ipa')),
        r'\\nas\share\app.ipa',
      );
    });

    test('an item outside the filesystem yields null, not an empty path', () {
      expect(WindowsFileDialog.decodeDisplayName(_pwstr('')), isNull);
    });

    test('a null pointer yields null rather than dereferencing it', () {
      expect(WindowsFileDialog.decodeDisplayName(PWSTR(nullptr)), isNull);
    });
  });
}
