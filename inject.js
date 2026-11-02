// MAIN world: getUserMedia override — sabit canvas akışı, kaynak canlı değişir
(() => {
  if (window.__vcamInstalled || !navigator.mediaDevices) return;
  window.__vcamInstalled = true;

  const md = navigator.mediaDevices;
  const orig = md.getUserMedia.bind(md);
  let cfg = { mode: "camera", blob: null };
  let cfgSeen = false;
  let waiters = [];

  let fileVid = null, fileUrl = null;
  let camVid = null, camStream = null, camPending = false;
  const sessions = new Set();
  let ticking = false;

  function mkVideo() {
    const v = document.createElement("video");
    v.muted = true; v.playsInline = true;
    return v;
  }

  function setFile() {
    if (fileVid) { fileVid.pause(); fileVid.removeAttribute("src"); fileVid.load(); }
    if (fileUrl) URL.revokeObjectURL(fileUrl);
    fileVid = fileUrl = null;
    if (cfg.blob) {
      fileUrl = URL.createObjectURL(cfg.blob);
      fileVid = mkVideo();
      fileVid.loop = true;
      fileVid.src = fileUrl;
      fileVid.play().catch(() => {});
    }
  }

  function setCamera(on) {
    if (on && !camStream && !camPending) {
      camPending = true;
      orig({ video: true }).then((s) => {
        if (cfg.mode !== "camera" || !sessions.size) { s.getTracks().forEach((t) => t.stop()); return; }
        camStream = s;
        camVid = mkVideo();
        camVid.srcObject = s;
        camVid.play().catch(() => {});
      }).catch(() => {}).finally(() => { camPending = false; });
    } else if (!on && camStream) {
      camStream.getTracks().forEach((t) => t.stop());
      camStream = camVid = null;
    }
  }

  function applyCfg() {
    setCamera(cfg.mode === "camera" && sessions.size > 0);
  }

  window.addEventListener("message", (e) => {
    if (e.source === window && e.data && e.data.__vcam) {
      cfg = { mode: e.data.mode, blob: e.data.blob };
      cfgSeen = true;
      setFile();
      applyCfg();
      waiters.forEach((w) => w());
      waiters = [];
    }
  });
  window.postMessage({ __vcamReady: true }, "*");
  const ready = () =>
    cfgSeen ? Promise.resolve() : new Promise((r) => { waiters.push(r); setTimeout(r, 1500); });

  function drawTo(s) {
    const { canvas: c, ctx: g } = s;
    const src = cfg.mode === "video" ? fileVid : camVid;
    if (src && src.readyState >= 2 && src.videoWidth) {
      // cover-fit
      const sr = src.videoWidth / src.videoHeight, cr = c.width / c.height;
      let sw = src.videoWidth, sh = src.videoHeight, sx = 0, sy = 0;
      if (sr > cr) { sw = sh * cr; sx = (src.videoWidth - sw) / 2; }
      else { sh = sw / cr; sy = (src.videoHeight - sh) / 2; }
      g.drawImage(src, sx, sy, sw, sh, 0, 0, c.width, c.height);
    } else if (cfg.mode === "video" && !cfg.blob) {
      const t = Date.now() / 1000;
      g.fillStyle = `hsl(${(t * 30) % 360},60%,35%)`;
      g.fillRect(0, 0, c.width, c.height);
      g.fillStyle = "#fff";
      g.font = `${c.height / 12}px sans-serif`;
      g.textAlign = "center";
      g.fillText("Video seçilmedi", c.width / 2, c.height / 2);
      g.fillText(new Date().toLocaleTimeString(), c.width / 2, c.height / 2 + c.height / 8);
    } else {
      g.fillStyle = "#000";
      g.fillRect(0, 0, c.width, c.height);
    }
  }

  function tick() {
    for (const s of sessions) {
      if (s.track.readyState === "ended") { sessions.delete(s); continue; }
      drawTo(s);
    }
    if (!sessions.size) applyCfg();
  }

  function startTicker() {
    if (ticking) return;
    ticking = true;
    try {
      // worker zamanlayıcı: sekme arka plandayken throttle olmaz
      const w = new Worker(URL.createObjectURL(new Blob(["setInterval(()=>postMessage(0),33)"])));
      w.onmessage = tick;
    } catch (e) {
      setInterval(tick, 33);
    }
  }

  const num = (v) => (typeof v === "number" ? v : v && (v.ideal || v.exact || v.max)) || 0;

  md.getUserMedia = async function (constraints) {
    await ready();
    if (!constraints || !constraints.video) return orig(constraints);

    const vc = typeof constraints.video === "object" ? constraints.video : {};
    const canvas = document.createElement("canvas");
    canvas.width = num(vc.width) || 1280;
    canvas.height = num(vc.height) || 720;
    const ctx = canvas.getContext("2d");
    const out = canvas.captureStream(30);
    const s = { canvas, ctx, track: out.getVideoTracks()[0] };
    sessions.add(s);
    applyCfg();
    drawTo(s);
    startTicker();

    if (constraints.audio) {
      try {
        (await orig({ audio: constraints.audio })).getAudioTracks().forEach((t) => out.addTrack(t));
      } catch (e) {}
    }
    return out;
  };
})();
