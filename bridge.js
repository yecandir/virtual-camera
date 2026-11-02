// Isolated world: storage -> sayfa (MAIN world) köprüsü
async function push() {
  const { mode = "camera", video } = await chrome.storage.local.get(["mode", "video"]);
  let blob = null;
  if (mode === "video" && video) {
    try { blob = await (await fetch(video)).blob(); } catch (e) {}
  }
  window.postMessage({ __vcam: true, mode, blob }, "*");
}
window.addEventListener("message", (e) => {
  if (e.source === window && e.data && e.data.__vcamReady) push();
});
chrome.storage.onChanged.addListener(push);
push();
