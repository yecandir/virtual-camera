// Isolated world: storage -> sayfa (MAIN world) köprüsü
// Video burada (isolated world) oynatılır: sayfanın CSP'si (ör. Teams media-src) blob:
// yüklemeyi engelleyebiliyor, isolated world ise uzantının CSP'sine tabi.
// Video elementi DOM'a gizli eklenir; MAIN world aynı elementi id ile bulup canvas'a çizer.
const VID_EL = "__vcam_video";
let lastKey = null;
let vid = null, vidUrl = null;

function clearVideo() {
  if (vid) { vid.pause(); vid.removeAttribute("src"); vid.load(); vid.remove(); }
  if (vidUrl) URL.revokeObjectURL(vidUrl);
  vid = vidUrl = null;
}

// play(): AbortError (yeni src yüklenince) zararsız; NotAllowedError (autoplay engeli)
// olursa ilk kullanıcı etkileşiminde tekrar dene
let gestureHooked = false;
function tryPlay(v) {
  v.play().then(() => console.info("[sanal-kamera] video oynuyor")).catch((e) => {
    if (e.name === "AbortError") return;
    console.warn("[sanal-kamera] play hatası:", e.name, e.message);
    if (e.name === "NotAllowedError" && !gestureHooked) {
      gestureHooked = true;
      const retry = () => {
        gestureHooked = false;
        ["pointerdown", "keydown"].forEach((t) => removeEventListener(t, retry, true));
        if (vid) tryPlay(vid);
      };
      ["pointerdown", "keydown"].forEach((t) => addEventListener(t, retry, true));
    }
  });
}

function loadVideo(dataUrl, blob) {
  clearVideo();
  const v = document.createElement("video");
  v.id = VID_EL;
  v.muted = true; v.playsInline = true; v.loop = true;
  v.setAttribute("aria-hidden", "true");
  v.style.cssText = "position:fixed;left:0;top:0;width:1px;height:1px;opacity:0;pointer-events:none;z-index:-1";
  let triedData = false;
  v.onerror = () => {
    // blob: başarısızsa data: URL dene
    if (!triedData && dataUrl) {
      console.warn("[sanal-kamera] blob: yüklenemedi, data: deneniyor", v.error && v.error.code, v.error && v.error.message);
      triedData = true; v.src = dataUrl; tryPlay(v); return;
    }
    const e = v.error;
    console.warn("[sanal-kamera] video oynatılamadı", e && e.code, e && e.message);
  };
  vidUrl = blob ? URL.createObjectURL(blob) : null;
  v.src = vidUrl || dataUrl;
  (document.documentElement || document).appendChild(v);
  vid = v;
  tryPlay(v);
}

async function push(force) {
  const d = await chrome.storage.local.get(["mode", "activeId", "settings"]);
  // seçili video yoksa varsayılan: kamera
  const mode = d.mode === "video" && d.activeId ? "video" : "camera";
  const key = mode === "video" ? d.activeId : "";
  const msg = { __vcam: true, mode, settings: d.settings };
  // video yalnızca kaynak değiştiğinde yeniden yüklenir (efekt değişince başa sarmasın)
  if (force || key !== lastKey) {
    lastKey = key;
    msg.reload = true;
    msg.hasVideo = false;
    clearVideo();
    if (key) {
      const o = await chrome.storage.local.get("vid:" + key);
      const url = o["vid:" + key];
      if (url) {
        let blob = null;
        try { blob = await (await fetch(url)).blob(); } catch (e) {}
        loadVideo(url, blob);
        msg.hasVideo = true;
      }
    }
  } else if (vid && !vid.isConnected) {
    // sayfa DOM'u temizlediyse geri ekle
    (document.documentElement || document).appendChild(vid);
  }
  window.postMessage(msg, "*");
}

let ticker = null;
function startTicker() {
  if (ticker) return;
  try {
    ticker = new Worker(URL.createObjectURL(new Blob(["setInterval(()=>postMessage(0),33)"])));
    ticker.onmessage = () => window.postMessage({ __vcamTick: true }, "*");
    ticker.onerror = () => console.warn("[sanal-kamera] zamanlayıcı worker açılamadı; sekme arka plandayken kare hızı düşebilir");
  } catch (e) {
    console.warn("[sanal-kamera] zamanlayıcı worker açılamadı", e && e.message);
  }
}

window.addEventListener("message", (e) => {
  if (e.source !== window || !e.data) return;
  if (e.data.__vcamReady) push(true);
  if (e.data.__vcamTicker) startTicker();
});
chrome.storage.onChanged.addListener(() => push(false));
push(true);
