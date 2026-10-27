#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  // Release the controller through the pointer rather than letting the member
  // destructor run it. ~unique_ptr leaves the stored pointer non-null while the
  // object is being deleted, and tearing the engine down pumps window messages,
  // so a message arriving mid-teardown passes the `if (flutter_controller_)`
  // guard in MessageHandler and calls into freed memory. reset() is specified
  // to null the pointer before invoking the deleter, which makes that guard
  // tell the truth.
  //
  // The template gets away with the default destructor because it normally
  // tears down via WM_DESTROY -> OnDestroy, which nulls the member first. This
  // app never takes that path: window_manager's destroy() posts WM_QUIT, so the
  // message loop ends with the window still alive and ~FlutterWindow is where
  // the engine actually dies. Without this, every close faulted (0xC0000005 in
  // flutter_windows.dll) and Windows Error Reporting held the window on screen
  // for ~10 seconds before the process died as 0xC000041D.
  flutter_controller_.reset();
}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
