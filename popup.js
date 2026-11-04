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

function render() {
  // mod
  document.querySelectorAll("#seg button").forEach((b) => b.classList.toggle("on", b.dataset.mode === state.mode));
  $("status").classList.toggle("video", state.mode === "video");
  $("statusText").textContent = state.mode === "video" ? "Video oynuyor" : "Kamera";

  // liste
  const ul = $("list");
  ul.textContent = "";
  $("empty").hidden = state.library.length > 0;
  for (const v of state.library) {
    const li = document.createElement("li");
    li.className = v.id === state.activeId ? "active" : "";
    li.innerHTML = `<span class="dot"></span><div class="info"><div class="name"></div><div class="meta"></div></div>
      <button class="dl" title="İndir">⬇</button><button class="del" title="Sil">✕</button>`;
    li.querySelector(".name").textContent = v.name;
    li.querySelector(".meta").textContent = Lib.size(v.size) + " · " + new Date(v.created).toLocaleDateString("tr-TR");
    li.onclick = () => chrome.storage.local.set({ activeId: v.id, mode: "video" }).then(load);
    li.querySelector(".dl").onclick = (e) => { e.stopPropagation(); Lib.download(v); };
    li.querySelector(".del").onclick = async (e) => {
      e.stopPropagation();
      if (!confirm(`"${v.name}" silinsin mi?`)) return;
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

// mod seçimi
document.querySelectorAll("#seg button").forEach((b) =>
  b.addEventListener("click", () => {
    state.mode = b.dataset.mode;
    chrome.storage.local.set({ mode: state.mode });
    render();
  })
);

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
  $("empty").hidden = false;
  $("empty").textContent = "Yükleniyor...";
  await Lib.add(f, f.name);
  e.target.value = "";
  $("empty").textContent = "Henüz video yok. Bir dosya ekle ya da kamera kaydı al.";
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

load();
