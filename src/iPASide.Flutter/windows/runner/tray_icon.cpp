#include "tray_icon.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <variant>

#include "resource.h"

namespace {

// Also named in lib/platform/single_instance.dart (trayHostWindowClass).
constexpr wchar_t kHostClassName[] = L"EZSide.TrayHost";

// Clicks on the icon arrive as this message, the mouse event in lparam.
constexpr UINT kTrayCallbackMessage = WM_APP + 1;

// Posted by a second launch to have this one show its window. Also defined in
// lib/platform/single_instance.dart (_showAppMessage).
constexpr UINT kShowAppMessage = WM_APP + 2;

constexpr UINT kIconId = 1;

// While the icon is wanted but the shell refuses it (Explorer not up yet at
// sign-in, or restarting), NIM_ADD is retried every 2 s for 2 minutes; the
// next TaskbarCreated starts another round.
constexpr UINT_PTR kRetryTimerId = 1;
constexpr UINT kRetryIntervalMs = 2000;
constexpr int kRetryAttempts = 60;

enum MenuId : UINT {
  kMenuOpen = 1,
  kMenuRefresh,
  kMenuStatus,
  kMenuStartup,
  kMenuQuit,
};

// Sent to every top-level window when Explorer (re)creates the taskbar.
const UINT kTaskbarCreated = RegisterWindowMessageW(L"TaskbarCreated");

std::wstring Utf16FromUtf8(const std::string& text) {
  if (text.empty()) {
    return std::wstring();
  }
  const int length = MultiByteToWideChar(
      CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      wide.data(), length);
  return wide;
}

// Tells Dart whether the shell has the icon (contract: "iconState").
void SendIconState(flutter::MethodChannel<flutter::EncodableValue>& channel,
                   bool added) {
  channel.InvokeMethod("iconState",
                       std::make_unique<flutter::EncodableValue>(added));
}

}  // namespace

TrayIcon::TrayIcon(flutter::BinaryMessenger* messenger)
    : channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "ezside/tray",
          &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

TrayIcon::~TrayIcon() {
  channel_->SetMethodCallHandler(nullptr);
  // A process that ends with its icon still added leaves a dead icon in the
  // tray until the mouse passes over it.
  RemoveIcon();
  if (window_) {
    DestroyWindow(window_);
    window_ = nullptr;
  }
  if (icon_) {
    DestroyIcon(icon_);
    icon_ = nullptr;
  }
}

void TrayIcon::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  if (method == "init") {
    result->Success(flutter::EncodableValue(Init()));
  } else if (method == "setStatus") {
    if (const auto* text = std::get_if<std::string>(call.arguments())) {
      status_ = Utf16FromUtf8(*text);
    }
    result->Success();
  } else if (method == "setStartupChecked") {
    if (const auto* on = std::get_if<bool>(call.arguments())) {
      startup_checked_ = *on;
    }
    result->Success();
  } else if (method == "popUpMenu") {
    const std::string chosen = PopUpMenu();
    result->Success(chosen.empty() ? flutter::EncodableValue()
                                   : flutter::EncodableValue(chosen));
  } else if (method == "showNotice") {
    const auto* args = std::get_if<flutter::EncodableList>(call.arguments());
    const std::string* title =
        args && args->size() == 2 ? std::get_if<std::string>(&(*args)[0])
                                  : nullptr;
    const std::string* body =
        args && args->size() == 2 ? std::get_if<std::string>(&(*args)[1])
                                  : nullptr;
    if (!title || !body) {
      result->Error("bad-args", "showNotice takes [title, body]");
      return;
    }
    result->Success(flutter::EncodableValue(
        ShowBalloon(Utf16FromUtf8(*title), Utf16FromUtf8(*body))));
  } else if (method == "dispose") {
    RemoveIcon();
    result->Success();
  } else {
    result->NotImplemented();
  }
}

bool TrayIcon::Init() {
  if (wanted_ && icon_added_) {
    return true;
  }
  if (!window_) {
    WNDCLASSW window_class{};
    window_class.lpfnWndProc = TrayIcon::WndProc;
    window_class.hInstance = GetModuleHandle(nullptr);
    window_class.lpszClassName = kHostClassName;
    // Fails harmlessly when a previous Init already registered it.
    RegisterClassW(&window_class);
    // No WS_VISIBLE: the window is never shown, so it is in neither the
    // taskbar nor Alt+Tab.
    window_ = CreateWindowExW(0, kHostClassName, L"EZSide", WS_OVERLAPPED, 0,
                              0, 0, 0, nullptr, nullptr,
                              GetModuleHandle(nullptr), this);
    if (!window_) {
      return false;
    }
    // An elevated EZSide would otherwise never hear these from the
    // non-elevated Explorer or a non-elevated second launch (UIPI).
    for (const UINT message :
         {kTaskbarCreated, kShowAppMessage, kTrayCallbackMessage}) {
      ChangeWindowMessageFilterEx(window_, message, MSGFLT_ALLOW, nullptr);
    }
  }
  if (!icon_) {
    icon_ = static_cast<HICON>(LoadImageW(
        GetModuleHandle(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
        GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON),
        LR_DEFAULTCOLOR));
  }
  wanted_ = true;
  const bool was_added = icon_added_;
  const bool added = AddOrRetry();
  if (added == was_added) {
    // AddIcon reports only changes; Dart still needs a first state.
    SendIconState(*channel_, added);
  }
  return added;
}

bool TrayIcon::AddIcon() {
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kIconId;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  data.uCallbackMessage = kTrayCallbackMessage;
  data.hIcon = icon_;
  wcsncpy_s(data.szTip, L"EZSide", _TRUNCATE);
  // NIM_ADD also fails when the shell already has the icon: a TaskbarCreated
  // sent for a DPI change, or an earlier add that timed out but went through.
  // NIM_MODIFY succeeds exactly when the icon is there.
  const bool added = Shell_NotifyIconW(NIM_ADD, &data) != FALSE ||
                     Shell_NotifyIconW(NIM_MODIFY, &data) != FALSE;
  if (added != icon_added_) {
    icon_added_ = added;
    SendIconState(*channel_, added);
  }
  return added;
}

bool TrayIcon::AddOrRetry() {
  if (AddIcon()) {
    StopRetry();
    return true;
  }
  retries_left_ = kRetryAttempts;
  // Replaces a timer that is already running, so a round never doubles up.
  SetTimer(window_, kRetryTimerId, kRetryIntervalMs, nullptr);
  return false;
}

void TrayIcon::StopRetry() {
  retries_left_ = 0;
  if (window_) {
    KillTimer(window_, kRetryTimerId);
  }
}

void TrayIcon::RemoveIcon() {
  wanted_ = false;
  StopRetry();
  if (!window_) {
    return;
  }
  // Even when icon_added_ is false: an add that reported a timeout may still
  // have gone through. Deleting an icon the shell does not have is harmless.
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kIconId;
  Shell_NotifyIconW(NIM_DELETE, &data);
  icon_added_ = false;
}

bool TrayIcon::ShowBalloon(const std::wstring& title,
                           const std::wstring& body) {
  if (!icon_added_) {
    return false;
  }
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window_;
  data.uID = kIconId;
  data.uFlags = NIF_INFO;
  data.dwInfoFlags = NIIF_WARNING;
  // The shell caps these at 63 and 255 characters; longer text is cut.
  wcsncpy_s(data.szInfoTitle, title.c_str(), _TRUNCATE);
  wcsncpy_s(data.szInfo, body.c_str(), _TRUNCATE);
  if (Shell_NotifyIconW(NIM_MODIFY, &data) != FALSE) {
    return true;
  }
  // The shell probably lost the icon (Explorer died and is not back yet).
  // AddIcon finds out and reports a loss; Dart shows this notice in a
  // message box instead.
  AddOrRetry();
  return false;
}

std::string TrayIcon::PopUpMenu() {
  HMENU menu = CreatePopupMenu();
  if (!menu) {
    return "";
  }
  AppendMenuW(menu, MF_STRING, kMenuOpen, L"Open EZSide");
  AppendMenuW(menu, MF_STRING, kMenuRefresh, L"Refresh due apps now");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING | MF_GRAYED, kMenuStatus, status_.c_str());
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu,
              MF_STRING | (startup_checked_ ? MF_CHECKED : MF_UNCHECKED),
              kMenuStartup, L"Start with Windows");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kMenuQuit, L"Quit EZSide");
  SetMenuDefaultItem(menu, kMenuOpen, FALSE);

  POINT cursor{};
  GetCursorPos(&cursor);
  // Without the foreground switch the menu stays open when the user clicks
  // elsewhere; the WM_NULL afterwards is its documented companion.
  SetForegroundWindow(window_);
  const UINT chosen = static_cast<UINT>(TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, cursor.x, cursor.y,
      0, window_, nullptr));
  PostMessageW(window_, WM_NULL, 0, 0);
  DestroyMenu(menu);

  switch (chosen) {
    case kMenuOpen:
      return "open";
    case kMenuRefresh:
      return "refreshNow";
    case kMenuStartup:
      return "startWithWindows";
    case kMenuQuit:
      return "quit";
    default:
      return "";
  }
}

void TrayIcon::Notify(const std::string& method) {
  channel_->InvokeMethod(method, nullptr);
}

bool TrayIcon::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == kTaskbarCreated) {
    // Explorer restarted and forgot every icon. icon_added_ is kept as Dart
    // last heard it, so AddIcon reports only a real change.
    if (wanted_) {
      AddOrRetry();
    }
    return true;
  }
  if (message == WM_TIMER && wparam == kRetryTimerId) {
    if (!wanted_ || AddIcon() || --retries_left_ <= 0) {
      StopRetry();
    }
    return true;
  }
  if (message == WM_SYSCOMMAND &&
      (wparam & 0xFFF0) == static_cast<WPARAM>(SC_CLOSE)) {
    // Alt+F4 while this window holds the foreground (after a dismissed menu)
    // must not quit the app; only a real WM_CLOSE from outside does.
    return true;
  }
  if (message == WM_CLOSE) {
    // `taskkill` without /F, or a logoff tool, closes every top-level window.
    // Destroying this one would leave a process with no icon and no target
    // for a second launch, so quit the whole app the graceful way instead.
    Notify("quit");
    return true;
  }
  if (message == kShowAppMessage) {
    Notify("open");
    return true;
  }
  if (message == kTrayCallbackMessage) {
    switch (LOWORD(lparam)) {
      case WM_LBUTTONUP:
      case WM_LBUTTONDBLCLK:
      case NIN_BALLOONUSERCLICK:
        Notify("open");
        break;
      case WM_RBUTTONUP:
        // Take the foreground while the click still grants it; after the
        // round trip to Dart it may be refused, and then the menu would not
        // close on a click elsewhere.
        SetForegroundWindow(window_);
        // Dart reads the real "Start with Windows" state, then asks for
        // popUpMenu.
        Notify("menu");
        break;
    }
    return true;
  }
  return false;
}

// static
LRESULT CALLBACK TrayIcon::WndProc(HWND window, UINT message, WPARAM wparam,
                                   LPARAM lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto create = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  } else if (auto that = reinterpret_cast<TrayIcon*>(
                 GetWindowLongPtr(window, GWLP_USERDATA))) {
    if (that->HandleMessage(message, wparam, lparam)) {
      return 0;
    }
  }
  return DefWindowProc(window, message, wparam, lparam);
}
