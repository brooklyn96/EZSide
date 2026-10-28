#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "tray_icon.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  // With |start_hidden| (a `--tray` launch) the first frame does not show the
  // window; Dart shows it later from the tray.
  FlutterWindow(const flutter::DartProject& project, bool start_hidden);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  bool start_hidden_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // The notification-area icon; talks over the controller's messenger, so it
  // must go before the controller does.
  std::unique_ptr<TrayIcon> tray_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
