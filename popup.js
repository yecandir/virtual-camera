const $ = (id) => document.getElementById(id);
const DEFAULTS = { mirror: false, brightness: 1, blur: 0 };
let state = { mode: "camera", activeId: null, library: [], settings: { ...DEFAULTS } };

async function load() {
  await Lib.migrate();
  const d = await chrome.storage.local.get(["mode", "activeId", "library", "settings"]);
  state = {
    mode: d.mode || "camera",
    activeId: d.activeId || null,
    library: d.library || [],
    settings: { ...DEFAULTS, ...(d.settings || {}) },
  };
  render();
}

// seçili video yoksa (ya da silindiyse) her zaman kamera
const playing = () => state.mode === "video" && state.library.some((v) => v.id === state.activeId);

function render() {
  const onVideo = playing();
  $("status").classList.toggle("video", onVideo);
  $("statusText").textContent = t(onVideo ? "statusVideo" : "statusCamera");

  const ul = $("list");
  ul.textContent = "";

  // varsayılan kaynak: kamera
  const cam = document.createElement("li");
  cam.className = "cam" + (onVideo ? "" : " active");
  cam.innerHTML = `<span class="dot"></span><span class="ico">📷</span><div class="info"><div class="name">${t("realCamera")}</div><div class="meta">${t("realCameraMeta")}</div></div>`;
  cam.onclick = () => chrome.storage.local.set({ mode: "camera", activeId: null }).then(load);
  ul.append(cam);

  for (const v of state.library) {
    const li = document.createElement("li");
    const selected = onVideo && v.id === state.activeId;
    li.className = selected ? "active" : "";
    li.innerHTML = `<span class="dot"></span><span class="ico">🎞</span><div class="info"><div class="name"></div><div class="meta"></div></div>
      <button class="dl" title="${t("download")}">⬇</button><button class="del" title="${t("delete")}">✕</button>`;
    li.querySelector(".name").textContent = v.name;
    li.querySelector(".meta").textContent = Lib.size(v.size) + " · " + new Date(v.created).toLocaleDateString(chrome.i18n.getUILanguage());
    // seçili videoya tekrar tıklayınca seçim kalkar -> kamera
    li.onclick = () =>
      chrome.storage.local
        .set(selected ? { mode: "camera", activeId: null } : { activeId: v.id, mode: "video" })
        .then(load);
    li.querySelector(".dl").onclick = (e) => { e.stopPropagation(); Lib.download(v); };
    li.querySelector(".del").onclick = async (e) => {
      e.stopPropagation();
      if (!confirm(t("confirmDelete", v.name))) return;
      await Lib.remove(v.id);
      load();
    };
    ul.append(li);
  }

  // efektler
  const s = state.settings;
  $("mirror").checked = s.mirror;
  $("brightness").value = s.brightness;
  $("brightnessOut").textContent = Math.round(s.brightness * 100) + "%";
  $("blur").value = s.blur;
  $("blurOut").textContent = s.blur + " px";
}

// efektler
function saveSettings() {
  chrome.storage.local.set({ settings: state.settings });
  render();
}
$("mirror").onchange = (e) => { state.settings.mirror = e.target.checked; saveSettings(); };
$("brightness").oninput = (e) => { state.settings.brightness = +e.target.value; saveSettings(); };
$("blur").oninput = (e) => { state.settings.blur = +e.target.value; saveSettings(); };
$("reset").onclick = () => { state.settings = { ...DEFAULTS }; saveSettings(); };

// video ekle
$("file").onchange = async (e) => {
  const f = e.target.files[0];
  if (!f) return;
  const label = $("addLabel");
  label.textContent = t("loading");
  await Lib.add(f, f.name);
  e.target.value = "";
  label.textContent = t("add");
  load();
};

// kayıt: popup odak kaybedince kapanır, kayıt ayrı sekmede yapılır
document.querySelectorAll("[data-rec]").forEach((b) =>
  b.addEventListener("click", () => {
    chrome.tabs.create({ url: "record.html?src=" + b.dataset.rec });
    window.close();
  })
);

$("shortcuts").onclick = (e) => {
  e.preventDefault();
  chrome.tabs.create({ url: "chrome://extensions/shortcuts" });
};

Lib.localize();
load();
