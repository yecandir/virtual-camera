# Virtual Camera

A Chrome extension that works as a virtual camera in **Google Meet** and **Microsoft Teams** (web). Play a video in place of your webcam, or use your real camera with effects, and switch between them live during a call.

> The extension UI is currently in Turkish.

## Features

- **Video as camera:** play any video from your library as your webcam, looping seamlessly
- **Real camera:** use your webcam through the extension, with mirror, brightness and blur effects
- **Live switching:** change the source from the popup or with `Alt+Shift+V` without rejoining the call
- **Recording:** record a clip with your camera and use it as your virtual camera later; record screen + audio or audio only
- **Works in Meet and Teams:** shows up as a "Sanal Kamera" device in the camera list

## Installation

1. Download the code: `git clone https://github.com/yecandir/virtual-camera.git` (or **Code → Download ZIP** and unzip it)
2. Open `chrome://extensions` in Chrome
3. Turn on **Developer mode** (top right)
4. Click **Load unpacked** and select the project folder
5. Reload any open Meet / Teams tabs

## Usage

1. Click the extension icon to open the popup
2. Add a video (or record one) and select it, or pick the camera
3. In Meet / Teams, choose **Sanal Kamera** (or your regular camera) in the video settings

The source can be changed at any time during a call. Switching back to the real camera is one click away.

## How it works

The extension overrides `getUserMedia` / `enumerateDevices` on the page and returns a synthetic video track. Frames are drawn on a canvas and, where supported, written to a `MediaStreamTrackGenerator` as I420 (YUV) frames, which Teams' video pipeline requires. Video playback and the frame timer run in the extension's isolated world, so they aren't blocked by the site's CSP / Trusted Types.

For debugging, run `localStorage.vcamDebug = "1"` in the page console and reload the page.

## Contributing

PRs are welcome :D Bug reports and ideas are welcome too. Just open an issue.

## License

[MIT](LICENSE)
