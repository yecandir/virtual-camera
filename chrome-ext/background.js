// Kısayol (Alt+Shift+V) ve rozet
async function badge() {
  const { mode = "camera", activeId } = await chrome.storage.local.get(["mode", "activeId"]);
  chrome.action.setBadgeText({ text: mode === "video" && activeId ? "VID" : "" });
  chrome.action.setBadgeBackgroundColor({ color: "#7c3aed" });
}

chrome.commands.onCommand.addListener(async (cmd) => {
  if (cmd !== "toggle-mode") return;
  const { mode = "camera", activeId, library = [] } = await chrome.storage.local.get(["mode", "activeId", "library"]);
  if (mode === "video" && activeId) {
    await chrome.storage.local.set({ mode: "camera" });
  } else if (library.length) {
    // seçili video yoksa en son eklenen videoya geç
    await chrome.storage.local.set({ mode: "video", activeId: activeId || library[0].id });
  }
});

chrome.storage.onChanged.addListener((c) => (c.mode || c.activeId) && badge());
chrome.runtime.onStartup.addListener(badge);
chrome.runtime.onInstalled.addListener(badge);
