(function () {
  var q = document.getElementById("q");
  if (q) {
    var cards = Array.prototype.slice.call(document.querySelectorAll(".card"));
    var empty = document.getElementById("empty");
    q.addEventListener("input", function () {
      var v = q.value.toLowerCase();
      var shown = 0;
      cards.forEach(function (card) {
        var hay = ((card.dataset.name || "") + " " + (card.dataset.repo || "") + " " + (card.dataset.description || "") + " " + (card.dataset.tags || "")).toLowerCase();
        var vis = hay.indexOf(v) !== -1;
        card.style.display = vis ? "" : "none";
        if (vis) shown++;
      });
      if (empty) empty.hidden = shown !== 0;
    });
  }

  function csrf() {
    var meta = document.querySelector('meta[name="csrf"]');
    return meta ? meta.getAttribute("content") : "";
  }

  function showErr(form, msg) {
    var el = form.querySelector(".err");
    if (!el) return;
    el.textContent = msg;
    el.hidden = false;
  }

  document.addEventListener("submit", function (e) {
    var form = e.target;
    if (!form || !form.getAttribute) return;
    var url = form.getAttribute("data-post");
    if (!url) return;
    e.preventDefault();
    var btn = form.querySelector("button[type=submit]");
    if (btn) btn.disabled = true;
    var obj = {};
    var fields = form.querySelectorAll("[name]");
    for (var i = 0; i < fields.length; i++) obj[fields[i].name] = fields[i].value;
    if (!obj.csrf) obj.csrf = csrf();
    var err = form.querySelector(".err");
    if (err) err.hidden = true;
    fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(obj)
    }).then(function (r) {
      return r.text().then(function (text) {
        var data = {};
        try { data = JSON.parse(text || "{}"); } catch (parseErr) { data = {}; }
        if (r.ok && data.ok !== false) {
          var next = form.getAttribute("data-next") || "";
          if (next) window.location = next;
          else window.location.reload();
        } else if (r.status === 429) {
          showErr(form, "Çok fazla deneme. Biraz sonra tekrar dene.");
          if (btn) btn.disabled = false;
        } else {
          showErr(form, (data && data.error) || "İşlem tamamlanamadı.");
          if (btn) btn.disabled = false;
        }
      });
    }).catch(function () {
      showErr(form, "Bağlantı hatası.");
      if (btn) btn.disabled = false;
    });
  });

  var logout = document.getElementById("logout");
  if (logout) {
    logout.addEventListener("click", function () {
      fetch("/cikis", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ csrf: csrf() })
      }).then(function () { window.location = "/"; });
    });
  }

  var theme = document.getElementById("theme");
  if (theme) {
    theme.addEventListener("click", function () {
      var cur = document.documentElement.getAttribute("data-theme");
      var next = "dark";
      if (cur === "dark") next = "light";
      else if (cur === "light") next = "dark";
      else if (window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches) next = "dark";
      document.documentElement.setAttribute("data-theme", next);
      try { localStorage.setItem("nox-theme", next); } catch (err) {}
    });
  }

  document.querySelectorAll("[data-admin-post]").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var url = btn.getAttribute("data-admin-post");
      var body = csrf();
      var extra = btn.getAttribute("data-extra");
      if (extra) body = body + "\n" + extra;
      fetch(url, { method: "POST", body: body }).then(function (r) {
        if (r.ok) window.location.reload();
      });
    });
  });
})();
