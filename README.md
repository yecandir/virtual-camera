# Virtual Camera

[![Chrome Web Store](https://img.shields.io/chrome-web-store/v/dbcjpbaaghjopnbeinpjdhangilehlce?label=Chrome%20Web%20Store)](https://chromewebstore.google.com/detail/virtual-camera/dbcjpbaaghjopnbeinpjdhangilehlce)
[![Users](https://img.shields.io/chrome-web-store/users/dbcjpbaaghjopnbeinpjdhangilehlce)](https://chromewebstore.google.com/detail/virtual-camera/dbcjpbaaghjopnbeinpjdhangilehlce)

A Chrome extension that works as a virtual camera in **Google Meet** and **Microsoft Teams** (web). Play a video in place of your webcam, or use your real camera with effects, and switch between them live during a call.

> **New: macOS app.** A native Mac version adds a system-wide **Virtual Camera (Mac)** device that works in every app: Slack, Zoom, Teams, FaceTime, Meet in any browser. See [macOS app](#macos-app).

> The UI is available in English and Turkish, following Chrome's language.

## Features

- **Video as camera:** play any video from your library as your webcam, looping seamlessly
- **Real camera:** use your webcam through the extension, with mirror, brightness and blur effects
- **Live switching:** change the source from the popup or with `Alt+Shift+V` without rejoining the call
- **Recording:** record a clip with your camera and use it as your virtual camera later; record screen + audio or audio only
- **Works in Meet and Teams:** shows up as a "Virtual Camera" device in the camera list

## Supported sites

Google Meet (`meet.google.com`) and Microsoft Teams web (`teams.microsoft.com`, `teams.live.com`, `teams.cloud.microsoft`).

## Installation

**[Install from the Chrome Web Store](https://chromewebstore.google.com/detail/virtual-camera/dbcjpbaaghjopnbeinpjdhangilehlce)**, then reload any open Meet / Teams tabs.

### From source (development)

1. Download the code: `git clone https://github.com/yecandir/virtual-camera.git` (or **Code → Download ZIP** and unzip it)
2. Open `chrome://extensions` in Chrome
3. Turn on **Developer mode** (top right)
4. Click **Load unpacked** and select the **`chrome-ext`** folder (if you loaded the repo root before this folder existed, remove it and load `chrome-ext` instead)
5. Reload any open Meet / Teams tabs

To build the Chrome Web Store package: `./chrome-ext/scripts/package.sh` (outputs `dist/virtual-camera-<version>.zip`).

## Usage

1. Click the extension icon to open the popup
2. Add a video (or record one) and select it, or pick the camera
3. In Meet / Teams, choose **Virtual Camera** (or your regular camera) in the video settings

The source can be changed at any time during a call. Switching back to the real camera is one click away.

## How it works

The extension overrides `getUserMedia` / `enumerateDevices` on the page and returns a synthetic video track. Frames are drawn on a canvas and, where supported, written to a `MediaStreamTrackGenerator` as I420 (YUV) frames, which Teams' video pipeline requires. Video playback and the frame timer run in the extension's isolated world, so they aren't blocked by the site's CSP / Trusted Types.

For debugging, run `localStorage.vcamDebug = "1"` in the page console and reload the page.

## macOS app

The `macos/` folder contains a native Mac app (macOS 14+) with the same features, available in **every** app that uses a camera, not just Meet/Teams in Chrome.

- **System-wide camera:** adds a **Virtual Camera (Mac)** device through a CoreMediaIO camera extension; pick it in Slack, Zoom, Teams, FaceTime, Photo Booth or any browser
- **Video or real camera:** play a looping video, or pass your real camera through with mirror, brightness and blur
- **⌥⇧V** switches between camera and video from anywhere
- **Recording:** camera clips go to the app's video library, while screen + audio and audio-only recordings go to Downloads (MP4 / M4A)
- **Light-friendly:** the real camera only turns on while an app is actually using the virtual camera

### Install

1. Download `VirtualCamera-<version>.dmg` from [Releases](https://github.com/yecandir/virtual-camera/releases) and drag **Virtual Camera** into **Applications**
2. Open it and approve the camera extension in **System Settings → General → Login Items & Extensions → Camera Extensions**
3. In your meeting app, choose **Virtual Camera (Mac)** as the camera

Videos must be MP4 or MOV (macOS can't play WebM).

### Build from source

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). Set your own `DEVELOPMENT_TEAM` and bundle IDs in `macos/project.yml`.

- `macos/install.sh` builds a development version and installs it to `/Applications` (system extensions only load from there)
- `macos/release.sh` builds the notarized DMG (Developer ID, needs a `notarytool` keychain profile)

How it works: the app renders frames (video or camera + effects) and pushes them into the extension's sink stream; the extension republishes them as a regular camera and reports how many apps are watching, so the pipeline idles when nobody is.

## Repository layout

| Folder | What |
|---|---|
| `chrome-ext/` | Chrome extension (Manifest V3), store assets, packaging script |
| `macos/` | Native Mac app + CoreMediaIO camera extension |
| `dist/` | Build outputs (not committed) |

## Contributing

PRs are welcome :D Bug reports and ideas are welcome too. Just open an issue.

Translations live in `chrome-ext/_locales/<lang>/messages.json` (extension) and `macos/App/<lang>.lproj/Localizable.strings` (Mac app).

## Privacy

Everything runs locally; nothing is collected or sent anywhere. See [PRIVACY.md](PRIVACY.md).

## License

[MIT](LICENSE)
