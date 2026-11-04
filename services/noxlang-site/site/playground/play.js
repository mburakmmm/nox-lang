// Nox Playground (beta): derleme ve çalıştırma tamamen tarayıcıda. Kaynak kod hiçbir sunucuya gönderilmez.
const $ = (id) => document.getElementById(id);
const editor = $("editor");
const hl = $("pg-hl").firstElementChild;
const gutter = $("pg-gutter");
const term = $("pg-term");
const statusEl = $("pg-status");
const runBtn = $("pg-run");
const stopBtn = $("pg-stop");
const shareBtn = $("pg-share");
const select = $("pg-example");
const stdinEl = $("pg-stdin");

const TIMEOUT_MS = 15000;
const isMac = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent);
runBtn.querySelector("kbd").textContent = isMac ? "⌘↵" : "Ctrl+↵";

// ------------------------------------------------------------------ vurgulama
const KEYWORDS = new Set(["def", "class", "if", "elif", "else", "while", "for", "in", "return", "import", "from", "as", "try", "except", "finally", "raise", "with", "pass", "break", "continue", "and", "or", "not", "is", "async", "await", "spawn", "yield", "defer", "assert", "del", "lowlevel", "extern"]);
const CONSTS = new Set(["None", "True", "False", "self"]);
const TYPES = new Set(["int", "float", "bool", "str", "list", "dict", "set", "tuple", "Task", "Channel", "Iterator", "ptr", "bytes", "u8", "u16", "u32", "u64", "i8", "i16", "i32", "i64", "Exception", "print", "len", "range", "sorted", "sum", "min", "max", "abs", "round", "map", "filter", "zip", "enumerate"]);

function esc(s) { return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;"); }
function span(cls, s) { return '<span class="' + cls + '">' + esc(s) + "</span>"; }

function highlight(src) {
  let out = "";
  let i = 0;
  const n = src.length;
  let prevWord = "";
  while (i < n) {
    const c = src[i];
    if (c === "#") {
      let j = src.indexOf("\n", i);
      if (j < 0) j = n;
      out += span("t-c", src.slice(i, j));
      i = j;
    } else if (c === '"' || c === "'") {
      const q = c;
      const triple = src.startsWith(q + q + q, i);
      let j = i + (triple ? 3 : 1);
      while (j < n) {
        if (src[j] === "\\") { j += 2; continue; }
        if (triple ? src.startsWith(q + q + q, j) : src[j] === q || src[j] === "\n") break;
        j++;
      }
      j = Math.min(n, j + (triple ? 3 : (src[j] === q ? 1 : 0)));
      out += span("t-s", src.slice(i, j));
      i = j;
    } else if (/[0-9]/.test(c)) {
      let j = i + 1;
      while (j < n && /[0-9a-fA-FxXoObB_.]/.test(src[j])) j++;
      out += span("t-m", src.slice(i, j));
      i = j;
    } else if (/[A-Za-z_]/.test(c)) {
      let j = i + 1;
      while (j < n && /[A-Za-z0-9_]/.test(src[j])) j++;
      const w = src.slice(i, j);
      if (prevWord === "def") out += span("t-nf", w);
      else if (prevWord === "class") out += span("t-nc", w);
      else if (KEYWORDS.has(w)) out += span("t-k", w);
      else if (CONSTS.has(w)) out += span("t-kc", w);
      else if (TYPES.has(w)) out += span("t-nb", w);
      else out += esc(w);
      prevWord = w;
      i = j;
      continue;
    } else if (c === "@") {
      let j = i + 1;
      while (j < n && /[A-Za-z0-9_.]/.test(src[j])) j++;
      out += span("t-nd", src.slice(i, j));
      i = j;
    } else {
      out += esc(c);
      i++;
    }
    if (!/\s/.test(c)) prevWord = "";
  }
  return out;
}

function renderEditor() {
  const src = editor.value;
  hl.innerHTML = highlight(src) + "\n";
  const lines = src.split("\n").length;
  let g = "";
  for (let i = 1; i <= lines; i++) g += i + "\n";
  gutter.textContent = g;
  syncScroll();
}

function syncScroll() {
  const pre = $("pg-hl");
  pre.scrollTop = editor.scrollTop;
  pre.scrollLeft = editor.scrollLeft;
  gutter.scrollTop = editor.scrollTop;
}

editor.addEventListener("scroll", syncScroll);
editor.addEventListener("input", () => { renderEditor(); scheduleCheck(); });
editor.addEventListener("keydown", (e) => {
  if ((e.metaKey || e.ctrlKey) && e.key === "Enter") { e.preventDefault(); run(); return; }
  if (e.key === "Tab") {
    e.preventDefault();
    const s = editor.selectionStart, t = editor.selectionEnd;
    if (e.shiftKey) {
      const lineStart = editor.value.lastIndexOf("\n", s - 1) + 1;
      if (editor.value.startsWith("    ", lineStart)) {
        editor.setRangeText("", lineStart, lineStart + 4, "preserve");
        editor.selectionStart = Math.max(lineStart, s - 4);
        editor.selectionEnd = Math.max(lineStart, t - 4);
      }
    } else {
      editor.setRangeText("    ", s, t, "end");
    }
    renderEditor();
    scheduleCheck();
    return;
  }
  if (e.key === "Enter" && !e.shiftKey && !e.altKey) {
    e.preventDefault();
    const s = editor.selectionStart;
    const lineStart = editor.value.lastIndexOf("\n", s - 1) + 1;
    const line = editor.value.slice(lineStart, s);
    let indent = /^ */.exec(line)[0];
    if (/:\s*$/.test(line.replace(/#.*$/, ""))) indent += "    ";
    editor.setRangeText("\n" + indent, s, editor.selectionEnd, "end");
    renderEditor();
    scheduleCheck();
  }
});

// ------------------------------------------------------------------ çıktı
function clearTerm() { term.textContent = ""; }
function append(text, cls) {
  const node = document.createElement("span");
  if (cls) node.className = cls;
  node.textContent = text;
  term.appendChild(node);
  term.scrollTop = term.scrollHeight;
}
function setStatus(text, kind) {
  statusEl.textContent = text;
  statusEl.className = "pg-status" + (kind ? " " + kind : "");
}

// ------------------------------------------------------------------ derleyici işçisi
let compiler = null;
let compilerReady = false;
let nextId = 1;
const pending = new Map();
let checkTimer = null;
let checkSeq = 0;

function startCompiler() {
  try {
    compiler = new Worker("/playground/compile-worker.js", { type: "module" });
  } catch (err) {
    setStatus("Your browser cannot run module workers.", "err");
    append("The playground needs a current browser (module Web Workers and WebAssembly).\n", "e");
    return;
  }
  compiler.onmessage = (e) => {
    const m = e.data;
    if (m.op === "status") { setStatus(m.text, "busy"); return; }
    if (m.op === "frontend-ready") { scheduleCheck(); runBtn.disabled = false; return; }
    if (m.op === "ready") { compilerReady = true; setStatus("Ready", "ok"); scheduleCheck(); return; }
    if (m.op === "fatal") {
      setStatus("The compiler could not be loaded.", "err");
      append("Could not load the compiler: " + m.text + "\n", "e");
      return;
    }
    const cb = pending.get(m.id);
    if (cb) { pending.delete(m.id); cb(m); }
  };
  compiler.onerror = (e) => {
    setStatus("The compiler worker failed.", "err");
    append("Compiler worker error: " + (e.message || "unknown") + "\n", "e");
  };
}

function ask(op, source) {
  return new Promise((resolve) => {
    const id = nextId++;
    pending.set(id, resolve);
    compiler.postMessage({ id, op, source });
  });
}

function scheduleCheck() {
  clearTimeout(checkTimer);
  checkTimer = setTimeout(async () => {
    if (!compiler || running) return;
    const seq = ++checkSeq;
    const r = await ask("check", editor.value);
    if (seq !== checkSeq || running) return;
    if (r.ok) {
      if (compilerReady) setStatus("No errors", "ok");
    } else {
      const first = (r.diagnostics || "").split("\n").find((l) => l.trim().length > 0) || "error";
      setStatus(first, "err");
    }
  }, 450);
}

// ------------------------------------------------------------------ çalıştırma
let running = false;
let runner = null;
let timeoutHandle = null;

function finish(label, kind) {
  running = false;
  clearTimeout(timeoutHandle);
  if (runner) { runner.terminate(); runner = null; }
  stopBtn.hidden = true;
  runBtn.hidden = false;
  runBtn.disabled = false;
  setStatus(label, kind);
}

async function run() {
  if (running || !compiler) return;
  running = true;
  clearTerm();
  runBtn.disabled = true;
  setStatus(compilerReady ? "Compiling…" : "Waiting for the compiler to finish loading…", "busy");
  const r = await ask("compile", editor.value);
  if (!r.ok) {
    append(r.diagnostics || "compilation failed\n", "e");
    finish("Compilation failed", "err");
    return;
  }
  setStatus("Running…", "busy");
  stopBtn.hidden = false;
  runBtn.hidden = true;
  const t0 = performance.now();
  runner = new Worker("/playground/run-worker.js", { type: "module" });
  runner.onmessage = (e) => {
    const m = e.data;
    if (m.t === "out") append(m.text, m.fd === 2 ? "e" : "");
    else if (m.t === "exit") {
      const ms = Math.round(performance.now() - t0);
      append("\n[exit " + m.code + " · " + ms + " ms · compiled in " + r.ms + " ms]\n", "m");
      finish(m.code === 0 ? "Finished" : "Exited with code " + m.code, m.code === 0 ? "ok" : "err");
    } else if (m.t === "fatal") {
      append("\n" + m.text + "\n", "e");
      finish("Runtime error", "err");
    }
  };
  runner.onerror = (e) => {
    append("\nRuntime worker error: " + (e.message || "unknown") + "\n", "e");
    finish("Runtime error", "err");
  };
  timeoutHandle = setTimeout(() => {
    append("\n[stopped: the program ran for more than " + TIMEOUT_MS / 1000 + " seconds]\n", "e");
    finish("Timed out", "err");
  }, TIMEOUT_MS);
  const wasm = r.wasm;
  runner.postMessage({ wasm, stdin: stdinEl.value.length ? stdinEl.value + "\n" : "" }, [wasm]);
}

runBtn.addEventListener("click", run);
stopBtn.addEventListener("click", () => {
  if (!running) return;
  append("\n[stopped]\n", "m");
  finish("Stopped", "");
});

// ------------------------------------------------------------------ örnekler + paylaşım
const DEFAULT_EXAMPLE = "hello";
let examples = [];

function encodeSource(s) { return btoa(String.fromCharCode(...new TextEncoder().encode(s))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, ""); }
function decodeSource(b) {
  const bin = atob(b.replace(/-/g, "+").replace(/_/g, "/"));
  return new TextDecoder().decode(Uint8Array.from(bin, (c) => c.charCodeAt(0)));
}

function setSource(src) {
  editor.value = src;
  renderEditor();
  scheduleCheck();
}

select.addEventListener("change", () => {
  const ex = examples.find((x) => x.id === select.value);
  if (ex) { setSource(ex.code); history.replaceState(null, "", "#example=" + ex.id); clearTerm(); }
});

shareBtn.addEventListener("click", async () => {
  const code = editor.value;
  const url = location.origin + "/playground/#code=" + encodeSource(code);
  history.replaceState(null, "", "#code=" + encodeSource(code));
  try { await navigator.clipboard.writeText(url); setStatus("Link copied to the clipboard", "ok"); }
  catch (e) { setStatus("Link is in the address bar", ""); }
});

async function loadExamples() {
  try {
    const list = await (await fetch("/playground/examples.json")).json();
    examples = list;
    for (const ex of list) {
      const o = document.createElement("option");
      o.value = ex.id; o.textContent = ex.title;
      select.appendChild(o);
    }
  } catch (e) { /* örnek yoksa boş editör */ }
  const h = location.hash || "";
  if (h.startsWith("#code=")) {
    try { setSource(decodeSource(h.slice(6))); return; } catch (e) { /* bozuk bağlantı: varsayılana düş */ }
  }
  const want = h.startsWith("#example=") ? h.slice(9) : DEFAULT_EXAMPLE;
  const ex = examples.find((x) => x.id === want) || examples[0];
  if (ex) { select.value = ex.id; setSource(ex.code); }
}

loadExamples();
startCompiler();
renderEditor();
