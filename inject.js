// MAIN world: getUserMedia override — sabit canvas akışı, kaynak canlı değişir
(() => {
  if (window.__vcamInstalled || !navigator.mediaDevices) return;
  window.__vcamInstalled = true;

  // tanı modu: sayfada localStorage.vcamDebug = "1" ise medya akışıyla ilgili her şeyi logla
  let DEBUG = false;
  try { DEBUG = localStorage.getItem("vcamDebug") === "1"; } catch (e) {}
  const dlog = (...a) => { if (DEBUG) console.info("[sanal-kamera:debug]", ...a); };
  if (DEBUG) {
    const desc = (x) => {
      if (!x) return String(x);
      if (x instanceof MediaStream) return "MediaStream(" + x.getTracks().map((t) => t.kind + ":" + t.label + ":" + t.readyState).join(",") + ")";
      if (x instanceof MediaStreamTrack) return "Track(" + x.kind + ":" + x.label + ":" + x.readyState + ")";
      if (x instanceof Event) return "Event(" + x.type + " target=" + (x.target && (x.target.tagName || x.target.constructor.name)) + ")";
      if (x instanceof Error) return x.name + ": " + x.message;
      return typeof x === "object" ? x.constructor && x.constructor.name : String(x);
    };
    addEventListener("error", (e) => dlog("window error", e.message || desc(e), e.target && e.target !== window ? (e.target.tagName + " " + (e.target.src || "")) : ""), true);
    addEventListener("unhandledrejection", (e) => dlog("unhandledrejection", desc(e.reason), e.reason && e.reason.stack ? e.reason.stack.split("\n").slice(0, 3).join(" | ") : ""));
    const so = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, "srcObject");
    if (so) Object.defineProperty(HTMLMediaElement.prototype, "srcObject", {
      configurable: true, get: so.get,
      set(v) { dlog("srcObject =", desc(v), "on", this.tagName, this.isConnected ? "(DOM)" : "(detached)"); return so.set.call(this, v); },
    });
    const hookCtor = (name) => {
      const O = window[name];
      if (!O) return;
      window[name] = new Proxy(O, { construct(T, args) {
        const a0 = args[0];
        dlog("new " + name, desc(a0 && a0.track ? a0.track : a0));
        return Reflect.construct(T, args, T);
      } });
    };
    ["MediaStreamTrackProcessor", "ImageCapture", "VideoFrame", "MediaRecorder", "Worker", "SharedWorker"].forEach(hookCtor);
    if (window.RTCPeerConnection) {
      const R = RTCPeerConnection.prototype;
      const oat = R.addTrack, oatr = R.addTransceiver;
      R.addTrack = function (t, ...r) { dlog("pc.addTrack", desc(t)); return oat.call(this, t, ...r); };
      R.addTransceiver = function (t, ...r) { dlog("pc.addTransceiver", desc(t)); return oatr.call(this, t, ...r); };
    }
    const ostop = MediaStreamTrack.prototype.stop;
    MediaStreamTrack.prototype.stop = function () { dlog("track.stop", desc(this)); return ostop.call(this); };
  }

  const md = navigator.mediaDevices;
  const MDP = MediaDevices.prototype;
  // prototipten al: sayfa prototipi .call ile çağırsa da bizim override'a düşsün
  const origGUM = MDP.getUserMedia;
  const origEnum = MDP.enumerateDevices;
  const orig = (c) => origGUM.call(md, c);
  const VID = "sanal-kamera-virtual";
  const VLABEL = "Sanal Kamera";
  let camDeviceId = null; // sayfa gerçek bir kamera seçtiyse onu kullan
  let cfg = { mode: "camera", blob: null, s: { mirror: false, brightness: 1, blur: 0 } };
  let cfgSeen = false;
  let waiters = [];

  let fileVid = null, fileErr = null;
  let camVid = null, camStream = null, camPending = false;
  const sessions = new Set();
  let ticking = false;

  function mkVideo() {
    const v = document.createElement("video");
    v.muted = true; v.playsInline = true;
    return v;
  }

  // video elementi bridge.js (isolated world) tarafından oluşturulup DOM'a eklenir;
  // böylece sayfa CSP'si (media-src) blob: yüklemeyi engelleyemez
  function setFile() {
    fileVid = cfg.blob ? document.getElementById("__vcam_video") : null;
    fileErr = null;
  }
  function videoState() {
    if (cfg.blob && (!fileVid || !fileVid.isConnected)) fileVid = document.getElementById("__vcam_video") || fileVid;
    if (fileVid && fileVid.error && fileVid.error.code !== 1)
      fileErr = "Video oynatılamadı (codec desteklenmiyor olabilir)";
    else fileErr = null;
    if (fileVid && fileVid.paused && !fileVid.error) fileVid.play().catch(() => {});
  }

  let camOpenedId = null;
  function setCamera(on) {
    if (on && camStream && camOpenedId !== camDeviceId) {
      // sayfa farklı bir gerçek kamera seçti: yeniden aç
      camStream.getTracks().forEach((t) => t.stop());
      camStream = camVid = null;
    }
    if (on && !camStream && !camPending) {
      camPending = true;
      const want = camDeviceId;
      orig({ video: want ? { deviceId: { exact: want } } : true })
        .catch((e) => (want ? orig({ video: true }) : Promise.reject(e)))
        .then((s) => {
        if (cfg.mode !== "camera" || !sessions.size) { s.getTracks().forEach((t) => t.stop()); return; }
        camStream = s;
        camOpenedId = want;
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
      cfg.mode = e.data.mode;
      if (e.data.settings) cfg.s = { mirror: false, brightness: 1, blur: 0, ...e.data.settings };
      if (e.data.reload) { cfg.blob = !!e.data.hasVideo; setFile(); }
      cfgSeen = true;
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
      g.save();
      const f = [];
      if (cfg.s.brightness !== 1) f.push(`brightness(${cfg.s.brightness})`);
      if (cfg.s.blur > 0) f.push(`blur(${cfg.s.blur}px)`);
      g.filter = f.length ? f.join(" ") : "none";
      if (cfg.s.mirror) { g.translate(c.width, 0); g.scale(-1, 1); }
      g.drawImage(src, sx, sy, sw, sh, 0, 0, c.width, c.height);
      g.restore();
    } else if (cfg.mode === "video" && fileErr) {
      g.fillStyle = "#400";
      g.fillRect(0, 0, c.width, c.height);
      g.fillStyle = "#fff";
      g.font = `${c.height / 18}px sans-serif`;
      g.textAlign = "center";
      g.fillText(fileErr, c.width / 2, c.height / 2);
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

  const alive = (s) => {
    for (const t of s.tracks) if (t.readyState !== "ended") return true;
    return false;
  };

  let lastTick = 0;
  function tick() {
    const now = performance.now();
    if (now - lastTick < 25) return; // worker + setInterval aynı anda çalışabilir
    lastTick = now;
    if (cfg.mode === "video") videoState();
    for (const s of sessions) {
      if (!alive(s)) { sessions.delete(s); continue; }
      drawTo(s);
      if (s.writer) pushFrame(s);
      else for (const t of s.tracks) if (t.requestFrame) try { t.requestFrame(); } catch (e) {}
    }
    if (!sessions.size) applyCfg();
  }

  // canvas (BGRA) -> I420 VideoFrame -> generator
  function pushFrame(s) {
    if (s.busy) return; // tüketici yetişemiyorsa kare atla
    const W = s.canvas.width & ~1, H = s.canvas.height & ~1;
    if (!W || !H) return;
    let d;
    try { d = s.ctx.getImageData(0, 0, W, H).data; } catch (e) { return; }
    const ySize = W * H, cSize = (W >> 1) * (H >> 1);
    if (!s.yuv || s.yuv.length !== ySize + 2 * cSize) s.yuv = new Uint8Array(ySize + 2 * cSize);
    const buf = s.yuv, uOff = ySize, vOff = ySize + cSize, hw = W >> 1;
    for (let j = 0; j < H; j++) {
      let p = j * W * 4, yi = j * W;
      const even = (j & 1) === 0;
      let ci = (j >> 1) * hw;
      for (let i = 0; i < W; i++, p += 4, yi++) {
        const r = d[p], g = d[p + 1], b = d[p + 2];
        buf[yi] = (66 * r + 129 * g + 25 * b + 4224) >> 8;
        if (even && (i & 1) === 0) {
          buf[uOff + ci] = (-38 * r - 74 * g + 112 * b + 32896) >> 8;
          buf[vOff + ci] = (112 * r - 94 * g - 18 * b + 32896) >> 8;
          ci++;
        }
      }
    }
    let f;
    try {
      f = new VideoFrame(buf, { format: "I420", codedWidth: W, codedHeight: H, timestamp: Math.round(performance.now() * 1000) });
    } catch (e) { dlog("VideoFrame hatası", e && e.message); return; }
    s.busy = true;
    s.writer.write(f).catch((e) => { dlog("generator write hatası", e && e.message); try { f.close(); } catch (x) {} })
      .finally(() => { s.busy = false; });
  }

  function startTicker() {
    if (ticking) return;
    ticking = true;
    // ana thread yedeği (sekme önplandayken)
    setInterval(tick, 33);
    // worker zamanlayıcı bridge.js'te (isolated world): Teams'in Trusted Types / CSP
    // kuralları MAIN world'de new Worker(blob:) çağrısını engelliyor.
    // Worker arka planda throttle olmaz; her tick'i postMessage ile buraya iletir.
    window.postMessage({ __vcamTicker: true }, "*");
  }
  window.addEventListener("message", (e) => {
    if (e.source === window && e.data && e.data.__vcamTick) tick();
  });

  const num = (v) => (typeof v === "number" ? v : v && (v.ideal || v.exact || v.max || v.min)) || 0;
  const wantedId = (vc) => {
    const d = vc && vc.deviceId;
    if (!d) return null;
    if (typeof d === "string") return d;
    const x = d.exact || d.ideal;
    return Array.isArray(x) ? x[0] : x || null;
  };

  // canvas track'ini gerçek bir kamera gibi gösterir
  function dress(track, s) {
    const def = (k, v) => {
      const f = DEBUG ? (...a) => {
        const r = v(...a);
        dlog("track." + k, JSON.stringify(a).slice(0, 200), "=>", r && r.then ? "promise" : JSON.stringify(r));
        return r;
      } : v;
      try { Object.defineProperty(track, k, { value: f, configurable: true }); } catch (e) {}
    };
    // sayfa belirli bir kamerayı istediyse track o cihazmış gibi görünsün (deviceId/label);
    // Teams aldığı track'in deviceId/label'ını istediğiyle karşılaştırıyor olabilir
    try { Object.defineProperty(track, "label", { get: () => s.label, configurable: true }); } catch (e) {}
    def("getSettings", () => ({
      deviceId: s.deviceId, groupId: s.groupId,
      width: s.canvas.width, height: s.canvas.height,
      aspectRatio: s.canvas.width / s.canvas.height,
      frameRate: 30, facingMode: "user", resizeMode: "none",
    }));
    def("getCapabilities", () => ({
      deviceId: s.deviceId, groupId: s.groupId,
      width: { min: 160, max: 1920 }, height: { min: 120, max: 1080 },
      aspectRatio: { min: 0.5, max: 4 }, frameRate: { min: 1, max: 30 },
      facingMode: ["user"], resizeMode: ["none", "crop-and-scale"],
    }));
    def("getConstraints", () => ({ ...s.constraints }));
    def("applyConstraints", async (c) => {
      c = c || {};
      s.constraints = { ...s.constraints, ...c };
      const w = num(c.width), h = num(c.height);
      if (w) s.canvas.width = Math.min(1920, Math.max(160, w));
      if (h) s.canvas.height = Math.min(1080, Math.max(120, h));
      drawTo(s);
    });
    const origClone = track.clone.bind(track);
    def("clone", () => {
      const t = dress(origClone(), s);
      s.tracks.add(t);
      return t;
    });
    return track;
  }

  async function gum(constraints) {
    await ready();
    if (!constraints || !constraints.video) return orig(constraints);

    const vc = typeof constraints.video === "object" ? constraints.video : {};
    const id = wantedId(vc);
    // sayfa gerçek bir kamerayı seçtiyse "kamera" modunda onu kullan
    if (id && id !== VID) camDeviceId = id;
    else if (id === VID) camDeviceId = null;

    const canvas = document.createElement("canvas");
    canvas.width = Math.min(1920, num(vc.width) || 1280);
    canvas.height = Math.min(1080, num(vc.height) || 720);
    // Teams gibi siteler kareleri MediaStreamTrackProcessor ile işliyor ve kamera gibi
    // YUV (NV12/I420) bekliyor; canvas.captureStream BGRA kare verir ve önizleme boş kalır.
    // Bu yüzden mümkünse MediaStreamTrackGenerator'a I420 kare yazıyoruz.
    const useGen = typeof MediaStreamTrackGenerator === "function" && typeof VideoFrame === "function";
    const ctx = canvas.getContext("2d", useGen ? { willReadFrequently: true } : undefined);
    let out, gen = null, writer = null;
    if (useGen) {
      try {
        gen = new MediaStreamTrackGenerator({ kind: "video" });
        writer = gen.writable.getWriter();
        out = new MediaStream([gen]);
      } catch (e) { gen = writer = null; }
    }
    if (!gen) out = canvas.captureStream(30);
    const s = { canvas, ctx, writer, busy: false, yuv: null, constraints: { ...vc }, tracks: new Set(), deviceId: VID, groupId: VID, label: VLABEL };
    if (id && id !== VID) {
      try {
        const d = (await origEnum.call(md)).find((x) => x.kind === "videoinput" && x.deviceId === id);
        if (d) { s.deviceId = d.deviceId; s.groupId = d.groupId; s.label = d.label || VLABEL; }
      } catch (e) {}
    }
    dlog("getUserMedia", JSON.stringify(constraints), "-> canvas track as", s.label, s.deviceId.slice(0, 12));
    const vt = dress(out.getVideoTracks()[0], s);
    s.tracks.add(vt);
    sessions.add(s);
    applyCfg();
    drawTo(s);
    if (s.writer) pushFrame(s);
    startTicker();

    if (constraints.audio) {
      try {
        (await orig({ audio: constraints.audio })).getAudioTracks().forEach((t) => out.addTrack(t));
      } catch (e) {}
    }
    return out;
  }

  async function enumerateDevices() {
    const list = await origEnum.call(md);
    // izin yokken gerçek cihazların label'ı boş olur; sanal cihaz yine görünsün
    const v = {
      deviceId: VID, groupId: VID, kind: "videoinput", label: VLABEL,
      toJSON() { return { deviceId: VID, groupId: VID, kind: "videoinput", label: VLABEL }; },
    };
    if (typeof InputDeviceInfo !== "undefined") Object.setPrototypeOf(v, InputDeviceInfo.prototype);
    ["deviceId", "groupId", "kind", "label"].forEach((k) =>
      Object.defineProperty(v, k, { value: v[k], enumerable: true }));
    v.getCapabilities = () => ({ deviceId: VID, groupId: VID, width: { min: 160, max: 1920 }, height: { min: 120, max: 1080 }, frameRate: { min: 1, max: 30 } });
    return [v, ...list];
  }

  // native görünüm: bazı siteler toString ile kontrol eder
  const native = (fn, name) => {
    try { Object.defineProperty(fn, "name", { value: name }); } catch (e) {}
    fn.toString = () => `function ${name}() { [native code] }`;
    return fn;
  };
  const gumFn = native(function getUserMedia(c) { return gum(c); }, "getUserMedia");
  const enumFn = native(function enumerateDevices_() { return enumerateDevices(); }, "enumerateDevices");
  MDP.getUserMedia = gumFn;
  MDP.enumerateDevices = enumFn;
  // eski API: navigator.getUserMedia(constraints, ok, err)
  const legacy = function (c, ok, err) { gum(c).then(ok, err); };
  ["getUserMedia", "webkitGetUserMedia"].forEach((k) => {
    if (k in navigator) try { navigator[k] = legacy; } catch (e) {}
  });
})();
