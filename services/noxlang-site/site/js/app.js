(function () {
  "use strict";
  var root = document.documentElement;

  // ---- tema ----
  function currentTheme() {
    var t = root.getAttribute("data-theme");
    if (t) return t;
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
  }
  document.querySelectorAll("[data-theme-toggle]").forEach(function (b) {
    b.addEventListener("click", function () {
      var next = currentTheme() === "dark" ? "light" : "dark";
      root.setAttribute("data-theme", next);
      try { localStorage.setItem("nox-theme", next); } catch (e) {}
    });
  });

  // ---- mobil menü ----
  document.querySelectorAll("[data-menu-toggle]").forEach(function (b) {
    b.addEventListener("click", function () { document.body.classList.toggle("menu-open"); });
  });
  document.addEventListener("click", function (e) {
    if (document.body.classList.contains("menu-open") && !e.target.closest(".sidebar") && !e.target.closest("[data-menu-toggle]")) {
      document.body.classList.remove("menu-open");
    }
  });

  // ---- kod kopyalama ----
  document.addEventListener("click", function (e) {
    var btn = e.target.closest(".code-copy");
    if (!btn) return;
    var pre = btn.closest(".code").querySelector("pre");
    var text = pre ? pre.innerText : "";
    var done = function () { btn.textContent = "Copied"; setTimeout(function () { btn.textContent = "Copy"; }, 1400); };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, function () {});
    else {
      var ta = document.createElement("textarea"); ta.value = text; document.body.appendChild(ta); ta.select();
      try { document.execCommand("copy"); done(); } catch (err) {} document.body.removeChild(ta);
    }
  });
  document.querySelectorAll("[data-copy]").forEach(function (el) {
    el.addEventListener("click", function () {
      var done = function () { el.setAttribute("data-copied", "1"); setTimeout(function () { el.removeAttribute("data-copied"); }, 1400); };
      if (navigator.clipboard) navigator.clipboard.writeText(el.getAttribute("data-copy")).then(done, function () {});
    });
  });

  // ---- landing sekmeleri ----
  var tablist = document.querySelector("[role=tablist]");
  if (tablist) {
    var tabs = Array.prototype.slice.call(tablist.querySelectorAll("[role=tab]"));
    var select = function (tab, focus) {
      tabs.forEach(function (t) {
        var on = t === tab;
        t.setAttribute("aria-selected", on ? "true" : "false");
        t.tabIndex = on ? 0 : -1;
        document.getElementById(t.getAttribute("aria-controls")).hidden = !on;
      });
      if (focus) tab.focus();
    };
    tabs.forEach(function (t, i) {
      t.addEventListener("click", function () { select(t); });
      t.addEventListener("keydown", function (e) {
        var n = null;
        if (e.key === "ArrowDown" || e.key === "ArrowRight") n = tabs[(i + 1) % tabs.length];
        if (e.key === "ArrowUp" || e.key === "ArrowLeft") n = tabs[(i - 1 + tabs.length) % tabs.length];
        if (n) { e.preventDefault(); select(n, true); }
      });
    });
  }

  // ---- içindekiler izleme ----
  var tocLinks = Array.prototype.slice.call(document.querySelectorAll(".toc a"));
  if (tocLinks.length && "IntersectionObserver" in window) {
    var map = {};
    tocLinks.forEach(function (a) { map[a.getAttribute("href").slice(1)] = a; });
    var heads = Object.keys(map).map(function (id) { return document.getElementById(id); }).filter(Boolean);
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        if (en.isIntersecting) {
          tocLinks.forEach(function (a) { a.classList.remove("active"); });
          map[en.target.id].classList.add("active");
        }
      });
    }, { rootMargin: "-70px 0px -70% 0px" });
    heads.forEach(function (h) { io.observe(h); });
  }
  var cur = document.querySelector(".sidebar a[aria-current=page]");
  if (cur && cur.scrollIntoView) { try { cur.scrollIntoView({ block: "center" }); } catch (e) {} }

  // ---- arama ----
  var modal = document.getElementById("search-modal");
  var input = document.getElementById("search-input");
  var list = document.getElementById("search-results");
  var index = null, loading = null, sel = -1, shown = [];
  function load() {
    if (index) return Promise.resolve(index);
    if (!loading) loading = fetch("/search-index.json").then(function (r) { return r.json(); }).then(function (j) { index = j; return j; });
    return loading;
  }
  function esc(s) { return s.replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; }); }
  function score(p, toks) {
    var s = 0, title = p.t.toLowerCase(), best = null;
    for (var i = 0; i < toks.length; i++) {
      var t = toks[i], hit = 0;
      if (title === t) hit += 40; else if (title.indexOf(t) === 0) hit += 24; else if (title.indexOf(t) > -1) hit += 16;
      for (var j = 0; j < p.h.length; j++) {
        var h = p.h[j].t.toLowerCase();
        if (h.indexOf(t) > -1) { hit += h.indexOf(t) === 0 ? 9 : 6; if (!best) best = p.h[j]; }
      }
      if (p.x.indexOf(t) > -1) hit += 2;
      if (p.d.toLowerCase().indexOf(t) > -1) hit += 3;
      if (hit === 0) return { s: 0 };
      s += hit;
    }
    return { s: s, h: best };
  }
  function render(q) {
    var toks = q.toLowerCase().split(/\s+/).filter(Boolean);
    shown = []; sel = -1;
    if (!toks.length) { list.innerHTML = ""; return; }
    var res = [];
    index.forEach(function (p) { var r = score(p, toks); if (r.s > 0) res.push({ p: p, s: r.s, h: r.h }); });
    res.sort(function (a, b) { return b.s - a.s; });
    shown = res.slice(0, 12);
    if (!shown.length) { list.innerHTML = '<li class="empty">No results for “' + esc(q) + '”.</li>'; return; }
    list.innerHTML = shown.map(function (r, i) {
      var url = r.p.u + (r.h ? "#" + r.h.i : "");
      var line = r.h ? esc(r.h.t) : esc(r.p.d);
      return '<li role="option" data-i="' + i + '"><a href="' + url + '"><span class="r-t">' + esc(r.p.t) + '</span><span class="r-s">' + esc(r.p.s) + '</span><span class="r-d">' + line + "</span></a></li>";
    }).join("");
    move(0);
  }
  function move(i) {
    var items = list.querySelectorAll("li[data-i]");
    if (!items.length) return;
    sel = (i + items.length) % items.length;
    items.forEach(function (li, k) { li.classList.toggle("sel", k === sel); });
    items[sel].scrollIntoView({ block: "nearest" });
  }
  function open() { if (!modal) return; modal.hidden = false; input.value = ""; list.innerHTML = ""; load().then(function () { if (input.value) render(input.value); }); setTimeout(function () { input.focus(); }, 0); }
  function close() { if (modal) modal.hidden = true; }
  document.querySelectorAll("[data-search-open]").forEach(function (b) { b.addEventListener("click", open); });
  document.querySelectorAll("[data-search-close]").forEach(function (b) { b.addEventListener("click", close); });
  if (input) {
    input.addEventListener("input", function () { load().then(function () { render(input.value); }); });
    input.addEventListener("keydown", function (e) {
      if (e.key === "ArrowDown") { e.preventDefault(); move(sel + 1); }
      else if (e.key === "ArrowUp") { e.preventDefault(); move(sel - 1); }
      else if (e.key === "Enter" && shown[sel]) { var a = list.querySelectorAll("li[data-i] a")[sel]; if (a) window.location.href = a.getAttribute("href"); }
    });
  }
  document.addEventListener("keydown", function (e) {
    var typing = /^(INPUT|TEXTAREA|SELECT)$/.test((document.activeElement || {}).tagName || "");
    if (e.key === "Escape") close();
    else if ((e.key === "/" && !typing) || ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k")) { e.preventDefault(); open(); }
  });
})();
