# EZSide

EZSide is a Windows app that sideloads IPA files to an iPhone with a free Apple ID and keeps them refreshed.

Based on [iPASide](https://github.com/pwnapplehat/iPASide) by pwnapplehat (MIT) — see the iPASide README for full documentation.

## Download

Get the installer from the [latest release](https://github.com/brooklyn96/EZSide/releases/latest).

The installer lets you choose the folder (for example `D:\EZSide`). The program goes in `<folder>\app` and your data goes in `<folder>\data`.

To move an install, uninstall but keep the data, install into the new folder, then copy the old `data` folder into it.

## Requirements

- Windows 10 or 11, 64-bit.
- Apple's device service, which Windows needs to talk to the iPhone. Install iTunes from Apple's website; it provides Apple Mobile Device Service and Bonjour (Bonjour is used for Wi-Fi discovery). Apple's "Apple Devices" app also provides the service.
- An Apple ID. A free one is fine.

## Quick start

1. Install EZSide and open it.
2. Sign in with your Apple ID and enter the code Apple sends to your other device.
3. Plug in your iPhone, unlock it and tap **Trust**.
4. Go to **Sideload** and choose an `.ipa` file.
5. Press **Sideload to iPhone**. Then trust the developer profile on the phone under Settings > General > VPN & Device Management.
6. Turn on auto-refresh in Settings.

## Auto-refresh and Wi-Fi

Apple's free signatures expire after 7 days. When auto-refresh is on, Windows checks every hour and refreshes the apps that are close to expiry. If the phone cannot be reached, EZSide tries again the next hour.

Refresh also works over Wi-Fi. Plug the phone in once while EZSide is open and EZSide turns on Wi-Fi sync on the phone. After that, keep the phone on the same Wi-Fi as the PC. A cable is the most reliable.

## What EZSide changes from iPASide

- Refresh can install only a new profile, without the IPA (as AltStore does). If that is not possible, EZSide re-signs the app instead.
- Auto-refresh runs in the background every hour, over USB or Wi-Fi, and Wi-Fi sync is turned on automatically.
- Closing the window keeps EZSide in the system tray; it can also start with Windows (Settings > Background).
- If a refresh fails, EZSide shows a notice, at most once every 20 hours.
- Apple sessions, pairing records and the signing certificate are protected with Windows DPAPI, so another Windows user or another PC cannot read them.
- You choose the install folder, and the data folder sits beside the program.
- Removed: the Jailbreak tab, placing a pairing file into apps on the phone, and SideStore in LiveContainer.

EZSide installs and runs next to iPASide without sharing anything with it: its own app, its own data and its own updates. Upstream details are in [UPSTREAM.md](UPSTREAM.md).

## Your Apple ID

Your Apple ID is used only to sign in to Apple. EZSide has no server of its own, and nothing is sent anywhere else. A spare Apple ID is a good idea rather than your main one.

## More documentation

The [iPASide README](https://github.com/pwnapplehat/iPASide#readme) explains how it works, the engine command line, and the limits of a free Apple ID (7-day expiry, three apps at a time, App ID limits). Those limits are Apple's and apply to EZSide too.

## Build from source

Build steps are in the "Build it yourself" section of the [iPASide README](https://github.com/pwnapplehat/iPASide#build-it-yourself). EZSide releases are made by CI from a version tag; see [docs/releasing.md](docs/releasing.md).

## License

MIT, see [LICENSE](LICENSE). EZSide is based on iPASide by pwnapplehat, also MIT.

EZSide installs apps onto your own device with your own Apple ID. Only install software you are entitled to run. EZSide is not affiliated with Apple Inc. Apple, iPhone and iOS are trademarks of Apple Inc.
