const $ = (id) => document.getElementById(id);
const v = $("v"), msg = $("msg");

let src = "camera";
let camStream, dispStream, micStream, actx;
let recorder, chunks = [], ext = "webm", t0, ticker, cancelled = false, recording = false;
let savedBlob, savedName;

const VIDEO_MIMES = ["video/mp4;codecs=avc1,mp4a.40.2", "video/mp4", "video/webm;codecs=vp9,opus", "video/webm;codecs=vp8,opus", "video/webm"];
const AUDIO_MIMES = ["audio/mp4;codecs=mp4a.40.2", "audio/mp4", "audio/webm;codecs=opus", "audio/webm"];

const HINTS = {
  camera: "",
  screen: "Başlatınca Chrome'un paylaşım penceresi açılır: <b>Chrome Sekmesi</b> → Meet sekmesini seç → <b>“Sekme sesini de paylaş”</b> kutusunu işaretle. Mikrofonun da kayda karıştırılır. Katılımcılara kaydı haber vermeyi unutma.",
  audio: "Ekran + ses ile aynı: Meet sekmesini seç ve <b>“Sekme sesini de paylaş”</b>'ı işaretle. Sadece ses (sekme + mikrofon) kaydedilir, görüntü kaydedilmez. Katılımcılara kaydı haber vermeyi unutma.",
};

function say(text, cls = "") { msg.textContent = text; msg.className = "msg " + cls; }
const stopStream = (s) => s && s.getTracks().forEach((t) => t.stop());

function stopAll() {
  stopStream(camStream); stopStream(dispStream); stopStream(micStream);
  camStream = dispStream = micStream = null;
  if (actx) { actx.close().catch(() => {}); actx = null; }
}

// ---- kaynak seçimi ----
function setSource(next) {
  if (recording) return;
  src = next;
  stopAll();
  v.srcObject = null;
  document.querySelectorAll("#tabs button").forEach((b) => b.classList.toggle("on", b.dataset.src === src));
  const h = $("hint");
  h.hidden = !HINTS[src];
  h.innerHTML = HINTS[src];
  $("placeholder").hidden = src === "camera";
  $("placeholder").textContent =
    src === "screen" ? "Başlatınca paylaşılacak sekme burada görünür." : "Sadece ses kaydedilecek.";
  $("rec").disabled = false;
  $("rec").textContent = src === "camera" ? "⏺ Kaydı başlat" : "⏺ Paylaşımı seç ve kaydet";
  if (src === "camera") initCamera();
  else say("Hazır.");
}

function initCamera() {
  navigator.mediaDevices.getUserMedia({ video: { width: 1280, height: 720 } })
    .then((s) => {
      if (src !== "camera") return s.getTracks().forEach((t) => t.stop());
      camStream = s; v.srcObject = s;
      say("Hazır. İstersen kayda bir ad ver, sonra başlat.");
    })
    .catch((e) => {
      $("rec").disabled = true;
      say(`Kamera açılamadı (${e.name}). Adres çubuğundaki kamera ikonundan izin ver ya da macOS Sistem Ayarları → Gizlilik → Kamera'da Chrome'u aç.`, "err");
    });
}

document.querySelectorAll("#tabs button").forEach((b) => (b.onclick = () => setSource(b.dataset.src)));

// ---- kayıt ----
async function countdown() {
  const c = $("count");
  c.hidden = false;
  for (let i = 3; i > 0 && !cancelled; i--) {
    c.textContent = i;
    await new Promise((r) => setTimeout(r, 700));
  }
  c.hidden = true;
}

// ekran/sekme + mikrofon -> tek akış
async function captureMeeting() {
  dispStream = await navigator.mediaDevices.getDisplayMedia({
    video: { frameRate: 15 }, audio: true, systemAudio: "include",
  });
  const tabAudio = dispStream.getAudioTracks();
  try { micStream = await navigator.mediaDevices.getUserMedia({ audio: { echoCancellation: true } }); } catch (e) {}

  actx = new AudioContext();
  const dest = actx.createMediaStreamDestination();
  if (tabAudio.length) actx.createMediaStreamSource(new MediaStream(tabAudio)).connect(dest);
  if (micStream) actx.createMediaStreamSource(micStream).connect(dest);

  const vt = dispStream.getVideoTracks()[0];
  vt.onended = () => recording && $("stop").click(); // Chrome'un "Paylaşımı durdur" butonu

  const tracks = [...dest.stream.getAudioTracks()];
  if (src === "screen") tracks.unshift(vt);
  if (src === "screen") v.srcObject = new MediaStream([vt]);

  const warn = [];
  if (!tabAudio.length) warn.push("sekme sesi paylaşılmadı, diğer katılımcılar kayda girmez");
  if (!micStream) warn.push("mikrofon izni yok, senin sesin kayda girmez");
  return { stream: new MediaStream(tracks), warn };
}

$("rec").onclick = async () => {
  $("rec").hidden = true;
  $("name").disabled = true;
  $("tabs").querySelectorAll("button").forEach((b) => (b.disabled = true));

  let stream = camStream, warn = [];
  if (src !== "camera") {
    try {
      ({ stream, warn } = await captureMeeting());
    } catch (e) {
      stopAll();
      $("rec").hidden = false; $("name").disabled = false;
      $("tabs").querySelectorAll("button").forEach((b) => (b.disabled = false));
      say(e.name === "NotAllowedError" ? "Paylaşım iptal edildi." : "Başlatılamadı: " + e.message, "err");
      return;
    }
    $("placeholder").hidden = src === "screen";
  }

  say("Hazırlan...");
  await countdown();
  if (cancelled) return;

  chunks = [];
  const mime = (src === "audio" ? AUDIO_MIMES : VIDEO_MIMES).find((m) => MediaRecorder.isTypeSupported(m));
  ext = mime.startsWith("video/mp4") ? "mp4" : mime.startsWith("audio/mp4") ? "m4a" : "webm";
  const opts = { mimeType: mime, audioBitsPerSecond: 128000 };
  if (src !== "audio") opts.videoBitsPerSecond = src === "camera" ? 2_500_000 : 1_500_000;
  recorder = new MediaRecorder(stream, opts);
  recorder.ondataavailable = (e) => e.data.size && chunks.push(e.data);
  recorder.onstop = save;
  recorder.start(1000);
  recording = true;

  t0 = Date.now();
  $("timer").hidden = false;
  $("stop").hidden = false;
  say(warn.length ? "Kayıt alınıyor. Uyarı: " + warn.join("; ") + "." : "Kayıt alınıyor...", warn.length ? "err" : "");
  ticker = setInterval(() => {
    const s = Math.floor((Date.now() - t0) / 1000);
    $("time").textContent = String(Math.floor(s / 60)).padStart(2, "0") + ":" + String(s % 60).padStart(2, "0");
  }, 250);
};

$("stop").onclick = () => {
  if (!recording) return;
  recording = false;
  $("stop").disabled = true;
  recorder.stop();
};

function downloadBlob(blob, name) {
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = name.replace(/[\/\\:*?"<>|]/g, "-");
  a.click();
}

async function save() {
  recording = false;
  clearInterval(ticker);
  stopAll();
  $("timer").hidden = true;
  $("controls").hidden = true;
  say("Kaydediliyor...");

  const kind = src === "audio" ? "audio" : "video";
  const blob = new Blob(chunks, { type: kind + "/" + (ext === "m4a" ? "mp4" : ext) });
  const stamp = new Date().toLocaleString("tr-TR", { dateStyle: "short", timeStyle: "short" });
  const label = src === "camera" ? "Kayıt" : src === "screen" ? "Toplantı" : "Ses";
  savedName = ($("name").value.trim() || label + " " + stamp) + "." + ext;
  savedBlob = blob;

  v.srcObject = null;
  v.src = URL.createObjectURL(blob);
  v.muted = false; v.controls = true; v.loop = src === "camera";
  $("placeholder").hidden = true;
  $("done").hidden = false;

  if (src === "camera") {
    await Lib.add(blob, savedName);
    say(`✓ "${savedName}" kaydedildi ve kamera olarak seçildi.`, "ok");
  } else {
    downloadBlob(blob, savedName);
    say(`✓ "${savedName}" İndirilenler klasörüne indirildi (${Lib.size(blob.size)}).`, "ok");
  }
}

async function closeTab() {
  cancelled = true;
  recording = false;
  if (recorder) recorder.onstop = null;
  stopAll();
  const tab = await chrome.tabs.getCurrent();
  if (tab) chrome.tabs.remove(tab.id); else window.close();
}
$("close").onclick = closeTab;
$("close2").onclick = closeTab;
$("again").onclick = () => location.reload();
$("dl").onclick = () => savedBlob && downloadBlob(savedBlob, savedName);

setSource("camera");
