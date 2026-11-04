// Kısayol (Alt+Shift+V) ve rozet
async function badge() {
  const { mode = "camera" } = await chrome.storage.local.get("mode");
  chrome.action.setBadgeText({ text: mode === "video" ? "VID" : "" });
  chrome.action.setBadgeBackgroundColor({ color: "#7c3aed" });
}

chrome.commands.onCommand.addListener(async (cmd) => {
  if (cmd !== "toggle-mode") return;
  const { mode = "camera" } = await chrome.storage.local.get("mode");
  await chrome.storage.local.set({ mode: mode === "video" ? "camera" : "video" });
});

chrome.storage.onChanged.addListener((c) => c.mode && badge());
chrome.runtime.onStartup.addListener(badge);
chrome.runtime.onInstalled.addListener(badge);
