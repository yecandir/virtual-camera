// Isolated world: storage -> sayfa (MAIN world) köprüsü
let lastKey = null;

async function push(force) {
  const d = await chrome.storage.local.get(["mode", "activeId", "settings"]);
  // seçili video yoksa varsayılan: kamera
  const mode = d.mode === "video" && d.activeId ? "video" : "camera";
  const key = mode === "video" ? d.activeId : "";
  const msg = { __vcam: true, mode, settings: d.settings };
  // video blob'u yalnızca kaynak değiştiğinde gönder (efekt değişince video başa sarmasın)
  if (force || key !== lastKey) {
    lastKey = key;
    msg.reload = true;
    msg.blob = null;
    if (key) {
      const o = await chrome.storage.local.get("vid:" + key);
      const url = o["vid:" + key];
      if (url) try { msg.blob = await (await fetch(url)).blob(); } catch (e) {}
    }
  }
  window.postMessage(msg, "*");
}

window.addEventListener("message", (e) => {
  if (e.source === window && e.data && e.data.__vcamReady) push(true);
});
chrome.storage.onChanged.addListener(() => push(false));
push(true);
