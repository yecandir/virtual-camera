# Chrome Web Store listing

Ready-to-paste text for the Chrome Web Store Developer Dashboard.

## Store listing tab

**Category:** Tools (or: Communication)
**Language:** English (add Turkish as a second language with the Turkish texts below)

### Short description (max 132 chars, comes from `extDesc` in `_locales`)

EN: Virtual camera for Google Meet and Microsoft Teams: play a video as your webcam or use your camera with effects. Record clips.

TR: Google Meet ve Microsoft Teams için sanal kamera: videoyu kamera olarak oynat ya da kamerayı efektlerle kullan. Klip kaydet.

### Detailed description: EN

Virtual Camera adds a virtual webcam to Google Meet and Microsoft Teams (web).

• Play any video as your camera, looping seamlessly
• Or use your real camera with mirror, brightness and blur effects
• Switch sources live during a call from the popup or with Alt+Shift+V, no need to rejoin
• Record a clip with your camera and use it as your virtual camera later
• Record a meeting (screen + audio) or audio only, saved to your Downloads folder
• Appears as "Virtual Camera" in the meeting's camera list

Everything happens locally in your browser. No servers, no accounts, no tracking. Your videos and recordings never leave your computer.

Open source: https://github.com/yecandir/virtual-camera

### Detailed description: TR

Sanal Kamera, Google Meet ve Microsoft Teams'e (web) sanal bir kamera ekler.

• İstediğin videoyu kamera olarak oynat, kesintisiz döngüde
• Ya da gerçek kameranı ayna, parlaklık ve bulanıklık efektleriyle kullan
• Görüşme sırasında popup'tan veya Alt+Shift+V ile kaynağı canlı değiştir, yeniden katılmana gerek yok
• Kameranla bir klip kaydet, sonra sanal kamera olarak kullan
• Toplantıyı (ekran + ses) veya sadece sesi kaydet, İndirilenler klasörüne kaydedilir
• Toplantının kamera listesinde "Sanal Kamera" olarak görünür

Her şey tarayıcında, yerel olarak çalışır. Sunucu, hesap ya da takip yok. Videoların ve kayıtların bilgisayarından çıkmaz.

Açık kaynak: https://github.com/yecandir/virtual-camera

### Graphics (required)

| Asset | Size | File |
|---|---|---|
| Store icon | 128×128 PNG (96px art + 16px padding) | `store/store-icon-128.png` |
| Screenshots | 1280×800 | `store/screenshot-1-en.png`, `store/screenshot-2-en.png` |
| Screenshots (Turkish listing) | 1280×800 | `store/screenshot-1-tr.png`, `store/screenshot-2-tr.png` |
| Small promo tile | 440×280 PNG | `store/promo-440x280.png` |


## Privacy tab

**Single purpose:**
Provide a virtual camera for Google Meet and Microsoft Teams, so the user can show a chosen video or their own camera (with effects) as their webcam, and record clips to use as that camera.

**Permission justifications:**

- `storage`: Saves the user's settings (selected source, effects) and the video library locally.
- `unlimitedStorage`: Videos added or recorded by the user are stored locally in the extension, and they can exceed the default 10 MB quota.
- **Host permissions / content scripts** (meet.google.com, teams.microsoft.com, teams.live.com, teams.cloud.microsoft): The content script provides the virtual camera by overriding getUserMedia/enumerateDevices on these meeting sites only. It doesn't read or modify page content otherwise.

**Remote code:** No, I am not using remote code. All code is included in the package.

**Data usage:** Check none of the data categories. The extension doesn't collect or transmit user data; camera/microphone media is processed locally and handed only to the meeting page the user is in.
Tick all three certifications (no selling, no unrelated use, no creditworthiness use).

**Privacy policy URL:** https://github.com/yecandir/virtual-camera/blob/main/PRIVACY.md
