#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <string>

// The notification-area icon, its menu and its failure balloon, driven from
// Dart over the "ezside/tray" channel (lib/platform/tray_service.dart).
//
// Native rather than a package: the tray packages that still build on this
// Flutter either cannot show a balloon or need a newer SDK, and a balloon
// (NIF_INFO) is the one notice that works without an AUMID or an MSIX.
//
// The icon is owned by a hidden top-level window of its own class, created
// only when Dart calls "init" - i.e. only in the instance that won the
// single-instance mutex - so a second launch finds exactly that window and
// posts it kShowAppMessage (lib/platform/single_instance.dart). Top-level, not
// message-only, because only top-level windows hear "TaskbarCreated", the
// broadcast that says Explorer restarted and every icon must be added again.
class TrayIcon {
 public:
  explicit TrayIcon(flutter::BinaryMessenger* messenger);
  ~TrayIcon();

  TrayIcon(const TrayIcon&) = delete;
  TrayIcon& operator=(const TrayIcon&) = delete;

 private:
  static LRESULT CALLBACK WndProc(HWND window, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Handles a message for the host window; false lets DefWindowProc have it.
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

  bool Init();
  // One NIM_ADD; tells Dart the result ("iconState").
  bool AddIcon();
  // AddIcon, and on failure keeps retrying on a timer for a while.
  bool AddOrRetry();
  void StopRetry();
  void RemoveIcon();
  bool ShowBalloon(const std::wstring& title, const std::wstring& body);
  // The chosen item's name (TrayMenuItem in Dart), or "" when dismissed.
  std::string PopUpMenu();
  void Notify(const std::string& method);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_ = nullptr;
  HICON icon_ = nullptr;
  // Dart wants an icon: from "init" until "dispose".
  bool wanted_ = false;
  // The shell has the icon now.
  bool icon_added_ = false;
  int retries_left_ = 0;
  std::wstring status_;
  bool startup_checked_ = false;
};

#endif  // RUNNER_TRAY_ICON_H_
