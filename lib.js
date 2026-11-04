// Video kütüphanesi (popup + kayıt sayfası ortak)
// storage: library = [{id,name,size,type,created}], activeId, mode, settings, "vid:<id>" = dataURL
const Lib = {
  async list() {
    const { library = [] } = await chrome.storage.local.get("library");
    return library;
  },

  toDataURL(blob) {
    return new Promise((res, rej) => {
      const r = new FileReader();
      r.onload = () => res(r.result);
      r.onerror = rej;
      r.readAsDataURL(blob);
    });
  },

  async add(blob, name, { activate = true } = {}) {
    const id = Date.now().toString(36) + Math.random().toString(36).slice(2, 5);
    const meta = { id, name, size: blob.size, type: blob.type || "video/mp4", created: Date.now() };
    const library = await Lib.list();
    library.unshift(meta);
    const data = { library, ["vid:" + id]: await Lib.toDataURL(blob) };
    if (activate) { data.activeId = id; data.mode = "video"; }
    await chrome.storage.local.set(data);
    return meta;
  },

  async remove(id) {
    const { activeId } = await chrome.storage.local.get("activeId");
    const library = (await Lib.list()).filter((v) => v.id !== id);
    await chrome.storage.local.remove("vid:" + id);
    const data = { library };
    if (activeId === id) data.activeId = library[0] ? library[0].id : null;
    await chrome.storage.local.set(data);
  },

  async blob(id) {
    const k = "vid:" + id;
    const o = await chrome.storage.local.get(k);
    return o[k] ? (await fetch(o[k])).blob() : null;
  },

  ext(meta) {
    return meta.type && meta.type.includes("webm") ? "webm" : (meta.name.match(/\.(\w{2,4})$/) || [, "mp4"])[1];
  },

  async download(meta) {
    const blob = await Lib.blob(meta.id);
    if (!blob) return;
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    const base = meta.name.replace(/\.(mp4|webm|mov|m4v)$/i, "");
    a.download = base + "." + Lib.ext(meta);
    a.click();
  },

  // eski sürümden (tek video) geçiş
  async migrate() {
    const { video, videoName } = await chrome.storage.local.get(["video", "videoName"]);
    if (!video) return;
    const blob = await (await fetch(video)).blob();
    await chrome.storage.local.remove(["video", "videoName"]);
    await Lib.add(blob, videoName || "Eski video", { activate: false });
    const { activeId } = await chrome.storage.local.get("activeId");
    if (!activeId) await chrome.storage.local.set({ activeId: (await Lib.list())[0].id });
  },

  size(n) {
    return n > 1e6 ? (n / 1e6).toFixed(1) + " MB" : Math.max(1, Math.round(n / 1e3)) + " KB";
  },
};
