(function () {
  "use strict";
  var root = document.documentElement;
  root.classList.add("js");

  var tabs = Array.prototype.slice.call(document.querySelectorAll(".os-tab"));
  var panels = Array.prototype.slice.call(document.querySelectorAll(".os-panel"));
  var detected = document.getElementById("dl-detected");
  var state = { os: "macos", arch: null, release: null };

  function select(os, focus) {
    tabs.forEach(function (t) {
      var on = t.getAttribute("data-os") === os;
      t.setAttribute("aria-selected", on ? "true" : "false");
      t.tabIndex = on ? 0 : -1;
      if (on && focus) t.focus();
    });
    panels.forEach(function (p) { p.hidden = p.getAttribute("data-panel") !== os; });
    state.os = os;
    try { history.replaceState(null, "", "#" + os); } catch (e) {}
    markArch();
  }

  tabs.forEach(function (t, i) {
    t.addEventListener("click", function () { select(t.getAttribute("data-os"), false); });
    t.addEventListener("keydown", function (e) {
      var n = tabs.length, j = -1;
      if (e.key === "ArrowRight") j = (i + 1) % n;
      else if (e.key === "ArrowLeft") j = (i - 1 + n) % n;
      else if (e.key === "Home") j = 0;
      else if (e.key === "End") j = n - 1;
      if (j >= 0) { e.preventDefault(); select(tabs[j].getAttribute("data-os"), true); }
    });
  });

  // ---- işletim sistemi + mimari algılama ----
  function fromUA() {
    var ua = navigator.userAgent || "";
    var plat = (navigator.userAgentData && navigator.userAgentData.platform) || navigator.platform || "";
    var os = "other", arch = null;
    if (/Windows/i.test(ua) || /^Win/i.test(plat)) { os = "windows"; arch = "x64"; }
    else if (/Android/i.test(ua)) { os = "other"; }
    else if (/iPhone|iPad|iPod/i.test(ua)) { os = "other"; }
    else if (/Mac/i.test(plat) || /Macintosh|Mac OS X/i.test(ua)) { os = "macos"; arch = "arm64"; }
    else if (/Linux|X11|CrOS/i.test(ua) || /Linux/i.test(plat)) {
      os = "linux";
      arch = /aarch64|arm64|armv8/i.test(ua + " " + plat) ? "arm64" : "x64";
    }
    return { os: os, arch: arch };
  }

  function detect() {
    var base = fromUA();
    var uad = navigator.userAgentData;
    if (uad && uad.getHighEntropyValues) {
      return uad.getHighEntropyValues(["architecture", "bitness", "platform"]).then(function (v) {
        var a = (v.architecture || "").toLowerCase();
        if (base.os === "linux" || base.os === "windows") {
          if (a === "arm") base.arch = "arm64";
          else if (a === "x86") base.arch = "x64";
        }
        return base;
      }, function () { return base; });
    }
    return Promise.resolve(base);
  }

  var OS_NAME = { macos: "macOS", windows: "Windows", linux: "Linux" };
  var ARCH_NAME = { arm64: "ARM64", x64: "x86-64" };

  function markArch() {
    // Algılanan mimariye uyan Linux düğmesini öne çıkar.
    document.querySelectorAll("[data-arch]").forEach(function (el) {
      var match = state.arch && el.getAttribute("data-arch") === state.arch;
      el.classList.toggle("is-match", !!(match && state.os === "linux"));
    });
    if (state.os === "linux" && state.arch) {
      var primaries = document.querySelectorAll("#os-linux .dl-btns:not(.small) .dl-btn");
      primaries.forEach(function (el) {
        var isMatch = el.getAttribute("data-arch") === state.arch;
        el.classList.toggle("btn-primary", isMatch);
      });
    }
  }

  // ---- sürüm bilgisi (/api/release: Nyx uygulaması GitHub'dan önbellekli çeker) ----
  var PATTERNS = {
    "macos-arm64": /-macos-arm64\.tar\.gz$/,
    "linux-x64": /-linux-x64\.tar\.gz$/,
    "linux-arm64": /-linux-arm64\.tar\.gz$/,
    "windows-setup": /-windows-x64-setup\.exe$/,
    "windows-zip": /-windows-x64\.zip$/,
    "appimage-x86_64": /x86_64\.AppImage$/,
    "appimage-aarch64": /aarch64\.AppImage$/,
    "webcompiler": /^nox-web-compiler-.*\.tar\.gz$/
  };

  function fmtSize(n) {
    if (!n) return "";
    if (n >= 1048576) return (n / 1048576).toFixed(1) + " MB";
    return Math.max(1, Math.round(n / 1024)) + " KB";
  }

  function applyRelease(rel) {
    state.release = rel;
    document.querySelectorAll("[data-version]").forEach(function (el) { el.textContent = rel.tag; });
    document.querySelectorAll("[data-asset]").forEach(function (el) {
      var key = el.getAttribute("data-asset");
      var re = PATTERNS[key];
      var hit = null;
      for (var i = 0; re && i < rel.assets.length; i++) {
        if (re.test(rel.assets[i].name)) { hit = rel.assets[i]; break; }
      }
      var size = el.querySelector("[data-size]");
      if (hit) {
        el.href = hit.url;
        el.setAttribute("rel", "noopener");
        if (size) size.textContent = fmtSize(hit.size);
        el.removeAttribute("aria-disabled");
        el.classList.remove("is-missing");
      } else {
        el.href = rel.page || "https://github.com/mburakmmm/nox-lang/releases/latest";
        el.classList.add("is-missing");
        if (size) size.textContent = "see releases";
      }
    });
  }

  function loadRelease() {
    if (!window.fetch) return;
    fetch("/api/release", { headers: { Accept: "application/json" } }).then(function (r) {
      if (!r.ok) throw new Error("status " + r.status);
      return r.json();
    }).then(function (j) {
      if (j && j.tag && j.assets) applyRelease(j);
    }).catch(function () { /* statik bağlantılar (releases/latest) kalır */ });
  }

  // ---- kopyalama: app.js [data-copy]'yi zaten bağlar; burada yalnızca algılama ----
  var wanted = (location.hash || "").replace("#", "");
  detect().then(function (d) {
    state.arch = d.arch;
    var pick = OS_NAME[wanted] || wanted === "web" ? wanted : d.os;
    if (!OS_NAME[pick] && pick !== "web") pick = "macos";
    if (OS_NAME[d.os] && detected) {
      detected.hidden = false;
      detected.textContent = "Detected: " + OS_NAME[d.os] + (d.arch ? " · " + ARCH_NAME[d.arch] : "");
    }
    select(pick, false);
  });
  loadRelease();
  window.addEventListener("hashchange", function () {
    var h = (location.hash || "").replace("#", "");
    if (OS_NAME[h] || h === "web") select(h, false);
  });
})();
