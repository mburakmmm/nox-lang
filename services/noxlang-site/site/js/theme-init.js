// Tema tercihini ilk boyamadan ÖNCE uygular (FOUC'u önler). Harici dosya: CSP inline betiğe izin vermez.
(function () {
  try {
    var t = localStorage.getItem("nox-theme");
    if (t === "light" || t === "dark") document.documentElement.setAttribute("data-theme", t);
  } catch (e) { /* depolama kapalı olabilir */ }
})();
