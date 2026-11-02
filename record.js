const v = document.getElementById("v");
const recBtn = document.getElementById("rec");
const stopBtn = document.getElementById("stop");
const msg = document.getElementById("msg");

let stream, recorder, chunks = [], startedAt;

navigator.mediaDevices.getUserMedia({ video: { width: 1280, height: 720 } })
  .then((s) => { stream = s; v.srcObject = s; })
  .catch((e) => {
    recBtn.disabled = true;
    msg.innerHTML = `Kamera açılamadı (${e.name}). Çözüm:<br>
      1) Adres çubuğundaki kamera ikonuna tıklayıp <b>İzin ver</b> de, sayfayı yenile.<br>
      2) Olmazsa <b>chrome://settings/content/camera</b> adresinde bu uzantı (<code>${location.origin}</code>) "Engellenenler" listesindeyse kaldır.<br>
      3) macOS: Sistem Ayarları → Gizlilik ve Güvenlik → Kamera → Google Chrome açık olsun, sonra Chrome'u yeniden başlat.`;
  });

recBtn.onclick = () => {
  chunks = [];
  const mime = ["video/webm;codecs=vp9", "video/webm;codecs=vp8", "video/webm"].find((m) => MediaRecorder.isTypeSupported(m));
  recorder = new MediaRecorder(stream, { mimeType: mime, videoBitsPerSecond: 2_500_000 });
  recorder.ondataavailable = (e) => e.data.size && chunks.push(e.data);
  recorder.onstop = save;
  recorder.start(1000);
  startedAt = Date.now();
  recBtn.disabled = true;
  stopBtn.disabled = false;
  const t = setInterval(() => {
    if (recorder.state !== "recording") return clearInterval(t);
    msg.textContent = "Kayıt: " + Math.round((Date.now() - startedAt) / 1000) + " sn";
  }, 500);
};

stopBtn.onclick = () => { stopBtn.disabled = true; recorder.stop(); };

function save() {
  stream.getTracks().forEach((t) => t.stop());
  const blob = new Blob(chunks, { type: "video/webm" });
  const name = "kayit-" + new Date().toISOString().slice(0, 19).replace(/[:T]/g, "-") + ".webm";
  msg.textContent = "Kaydediliyor...";
  const rd = new FileReader();
  rd.onload = async () => {
    await chrome.storage.local.set({ video: rd.result, videoName: name, mode: "video" });
    const url = URL.createObjectURL(blob);
    v.srcObject = null; v.src = url; v.muted = false; v.controls = true;
    msg.innerHTML = `Kaydedildi ve kamera olarak seçildi. Bu pencereyi kapatabilirsin. <a href="${url}" download="${name}">Dosyayı indir</a>`;
  };
  rd.readAsDataURL(blob);
}
