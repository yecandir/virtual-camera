const info = document.getElementById("info");
const file = document.getElementById("file");

chrome.storage.local.get(["mode", "video", "videoName"]).then(({ mode = "camera", video, videoName }) => {
  document.querySelector(`input[value=${mode}]`).checked = true;
  if (video) info.textContent = "Kayıtlı video: " + (videoName || "var");
});

document.querySelectorAll("input[name=mode]").forEach((r) =>
  r.addEventListener("change", () => chrome.storage.local.set({ mode: r.value }))
);

document.getElementById("download").addEventListener("click", async () => {
  const { video, videoName } = await chrome.storage.local.get(["video", "videoName"]);
  if (!video) { info.textContent = "Kayıtlı video yok."; return; }
  const blob = await (await fetch(video)).blob();
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = videoName || "kayit.webm";
  a.click();
  info.textContent = "İndirilenler klasörüne indirildi: " + a.download;
});

document.getElementById("record").addEventListener("click", () => {
  // popup odak kaybedince kapanır; kayıt ayrı bir pencerede yapılır
  chrome.tabs.create({ url: "record.html" });
  window.close();
});

file.addEventListener("change", () => {
  const f = file.files[0];
  if (!f) return;
  info.textContent = "Yükleniyor...";
  const rd = new FileReader();
  rd.onload = async () => {
    await chrome.storage.local.set({ video: rd.result, videoName: f.name, mode: "video" });
    document.querySelector("input[value=video]").checked = true;
    info.textContent = "Kayıtlı video: " + f.name;
  };
  rd.readAsDataURL(f);
});
