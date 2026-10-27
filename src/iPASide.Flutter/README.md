# iPASide — desktop shell

The Flutter front end for iPASide. It renders the UI and drives the Python
engine in `../iPASide.Engine`; it contains no sideloading logic of its own.

See the [root README](../../README.md) for what iPASide does and how to install
it, and [docs/macos-port.md](../../docs/macos-port.md) for what is Windows-only
here.

## Running it

```powershell
flutter run -d windows        # needs the engine available - see the root README
flutter analyze               # must be clean
flutter test
flutter build windows --release
```

The shell finds the engine automatically, in order: the `IPASIDE_ENGINE_EXE`
override, the portable interpreter bundled beside the executable, the repo's
`.venv`, then a bare `python` on `PATH`. So a dev run picks up the virtualenv
engine with no configuration.

## Layout

```
lib/
  engine/      transport and typed API over the engine's `serve` protocol
               (newline-delimited JSON over stdio, one request in flight)
  platform/    OS-specific pieces behind abstract interfaces - process
               reaping, single instance, scheduled refresh, reduced motion
  services/    updates, file dialogs, icon cache, settings, startup flags
  viewmodels/  screen state, exposed with ChangeNotifier via provider
  ui/
    theme/     design tokens, light and dark palettes, typography
    widgets/   the shared widget library
    shell/     window chrome, sidebar, drag-drop veil, dialogs
    views/     the sidebar screens plus sign-in
```

Two conventions worth knowing before editing:

- **Everything crossing the engine boundary is parsed into a model** in
  `lib/engine/models.dart`. Views never touch raw JSON.
- **`SideloadViewModel` is a singleton** for the app's lifetime, because a
  sideload in progress has to survive the user navigating away and back.
