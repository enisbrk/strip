// Where the download button points. GitHub serves the newest release asset under this fixed name.
const DOWNLOAD_URL = "https://github.com/enisbrk/strip/releases/latest/download/Strip.dmg";
const VERSION = "1.1.1";

/* ---------------- Language ---------------- */

const I18N = window.STRIP_I18N;
const english = {};
document.querySelectorAll("[data-i18n]").forEach((el) => { english[el.dataset.i18n] = el.innerHTML; });
let lang = "en";

function t(key) {
  return (I18N[lang] && I18N[lang][key]) || I18N.en[key] || english[key] || key;
}

function setLanguage(next) {
  lang = next === "tr" ? "tr" : "en";
  document.documentElement.lang = lang;
  document.querySelectorAll("[data-i18n]").forEach((el) => { el.innerHTML = t(el.dataset.i18n); });
  document.querySelectorAll("[data-lang]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.lang === lang)));
  try { localStorage.setItem("strip.lang", lang); } catch (_) { /* storage unavailable */ }
  if (hud.classList.contains("is-on") && hud.dataset.key) hudLabel.textContent = t(hud.dataset.key);
}

document.querySelectorAll("[data-lang]").forEach((b) => b.addEventListener("click", () => setLanguage(b.dataset.lang)));

document.querySelectorAll(".js-download").forEach((a) => {
  a.href = DOWNLOAD_URL;
  a.addEventListener("click", () => confetti(a));
});

/** A small burst of colored paper from the button that was clicked. */
function confetti(from) {
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
  const colors = ["#ffd23f", "#ff7eb6", "#6ec8ff", "#5ee0a8", "#a78bfa", "#ffb17a", "#c6f45b"];
  const box = from.getBoundingClientRect();
  for (let i = 0; i < 36; i++) {
    const piece = document.createElement("i");
    piece.className = "confetti";
    piece.style.background = colors[i % colors.length];
    piece.style.left = box.left + box.width / 2 + "px";
    piece.style.top = box.top + box.height / 2 + "px";
    document.body.appendChild(piece);
    const angle = Math.random() * Math.PI * 2, distance = 80 + Math.random() * 160;
    piece.animate([
      { transform: "translate(-50%, -50%) rotate(0)", opacity: 1 },
      { transform: `translate(${Math.cos(angle) * distance}px, ${Math.sin(angle) * distance + 120}px) rotate(${Math.random() * 720}deg)`, opacity: 0 },
    ], { duration: 900 + Math.random() * 500, easing: "cubic-bezier(.2, .7, .3, 1)" }).onfinish = () => piece.remove();
  }
}
document.querySelectorAll(".js-version").forEach((el) => { el.textContent = "v" + VERSION; });

/* ---------------- Hero animation ----------------
   A tiny model of Strip: columns of windows on a horizontal strip, a focused window and a scroll
   offset. Each step runs one command; CSS transitions do the motion. */

const screen = document.getElementById("screen");
const stripEl = document.getElementById("strip");
const hud = document.getElementById("hud");
const hudKeys = document.getElementById("hudKeys");
const hudLabel = document.getElementById("hudLabel");
const minimap = document.getElementById("minimap");
const menubarApp = document.getElementById("menubarApp");

const APPS = {
  safari: { title: "Safari", color: "#6ec8ff", kind: "web" },
  notes: { title: "Notes", color: "#ffd23f", kind: "text" },
  terminal: { title: "Terminal", color: "#5ee0a8", kind: "code" },
  music: { title: "Music", color: "#ff7eb6", kind: "tiles" },
  xcode: { title: "Xcode", color: "#a78bfa", kind: "code" },
};
const WIDTHS = [1 / 3, 1 / 2, 2 / 3, 1];

let cols, focus, scroll, elements = {};

function initialState() {
  cols = [
    { w: 1 / 2, wins: ["safari"] },
    { w: 1 / 3, wins: ["notes"] },
    { w: 1 / 2, wins: ["terminal"] },
    { w: 1 / 3, wins: ["music"] },
  ];
  focus = { col: 0, row: 0 };
  scroll = 0;
}

function makeWindow(id) {
  const app = APPS[id];
  const el = document.createElement("div");
  el.className = "win win--" + app.kind;
  el.style.setProperty("--c", app.color);
  const body = app.kind === "web" || app.kind === "tiles"
    ? '<div class="tile"></div><i></i><i></i><i></i>'
    : "<i></i><i></i><i></i><i></i><i></i>";
  el.innerHTML = '<div class="win__bar"><span class="win__dots"><i></i><i></i><i></i></span>' + app.title +
    '</div><div class="win__body">' + body + "</div>";
  stripEl.appendChild(el);
  return el;
}

function metrics() {
  const W = screen.clientWidth, H = screen.clientHeight;
  const gap = W * 0.008;
  const top = H * 0.034 + gap;
  return { W, H, gap, top, height: H - top - gap };
}

function columnWidth(m, w) { return w * (m.W - 2 * m.gap + m.gap) - m.gap; }

/** Room a column takes on the strip: a centered column (⌃⌥C) takes a whole screen. */
function slotWidth(m, col) { return col.centered ? m.W - 2 * m.gap : columnWidth(m, col.w); }

/** Left margin of a centered column's windows inside its slot. */
function inset(m, col) { return col.centered ? (slotWidth(m, col) - columnWidth(m, col.w)) / 2 : 0; }

function columnX(m, index) {
  let x = m.gap;
  for (let i = 0; i < index; i++) x += slotWidth(m, cols[i]) + m.gap;
  return x;
}

/** Scrolls just enough to show the focused column (Strip's default "never center" mode). */
function revealFocus(m, center = false) {
  const left = columnX(m, focus.col), width = slotWidth(m, cols[focus.col]);
  if (center) scroll = left + width / 2 - m.W / 2;
  else if (left - m.gap < scroll) scroll = left - m.gap;
  else if (left + width + m.gap > scroll + m.W) scroll = left + width + m.gap - m.W;
  const total = columnX(m, cols.length);
  scroll = Math.max(0, Math.min(scroll, Math.max(0, total - m.W)));
}

function render() {
  const m = metrics();
  const seen = new Set();
  cols.forEach((col, c) => {
    const x = columnX(m, c) + inset(m, col) - scroll;
    const w = columnWidth(m, col.w);
    const h = (m.height - m.gap * (col.wins.length - 1)) / col.wins.length;
    col.wins.forEach((id, r) => {
      const el = elements[id] || (elements[id] = makeWindow(id));
      seen.add(id);
      el.style.transform = `translate3d(${x}px, ${m.top + r * (h + m.gap)}px, 0)`;
      el.style.width = w + "px";
      el.style.height = h + "px";
      const focused = c === focus.col && r === focus.row;
      el.classList.toggle("is-focus", focused);
      el.classList.toggle("is-dim", !focused);
      el.style.zIndex = focused ? 2 : 1;
    });
  });
  for (const id of Object.keys(elements)) {
    if (!seen.has(id)) { elements[id].remove(); delete elements[id]; }
  }
  menubarApp.textContent = APPS[cols[focus.col].wins[focus.row]].title;
  renderMinimap(m);
}

function renderMinimap(m) {
  const k = 0.11; // minimap pixels per screen pixel
  const pad = m.W * 0.005;
  const total = columnX(m, cols.length);
  minimap.style.width = Math.max(total, m.W) * k + pad * 2 + "px";
  const blocks = minimap.querySelectorAll("b");
  cols.forEach((col, c) => {
    const b = blocks[c] || minimap.insertBefore(document.createElement("b"), minimap.querySelector("s"));
    b.style.left = pad + (columnX(m, c) + inset(m, col)) * k + "px";
    b.style.width = columnWidth(m, col.w) * k + "px";
    b.style.setProperty("--c", APPS[col.wins[0]].color);
    b.classList.toggle("is-focus", c === focus.col);
  });
  for (let i = cols.length; i < blocks.length; i++) blocks[i].remove();
  let view = minimap.querySelector("s");
  if (!view) view = minimap.appendChild(document.createElement("s"));
  view.style.left = pad + scroll * k + "px";
  view.style.width = m.W * k + "px";
}

let hudTimer;
function showHUD(keys, key) {
  hudKeys.innerHTML = keys.map((k) => "<kbd>" + k + "</kbd>").join("");
  hud.dataset.key = key;
  hudLabel.textContent = t(key);
  hud.classList.add("is-on");
  clearTimeout(hudTimer);
  hudTimer = setTimeout(() => hud.classList.remove("is-on"), 1300);
}

const CMD = ["⌃", "⌥"];
const steps = [
  { keys: [...CMD, "L"], label: "hud.focusRight", run: () => { focus = { col: 1, row: 0 }; } },
  { keys: [...CMD, "L"], label: "hud.focusRight", run: () => { focus = { col: 2, row: 0 }; } },
  {
    keys: ["⌘", "N"], label: "hud.newWindow",
    run: () => {
      cols.splice(focus.col + 1, 0, { w: 1 / 2, wins: ["xcode"] });
      focus = { col: focus.col + 1, row: 0 };
      // Fade the new window in at its final place.
      const el = elements.xcode = makeWindow("xcode");
      el.classList.add("is-new");
      el.style.transition = "none";
      const m = metrics();
      el.style.transform = `translate3d(${columnX(m, focus.col) - scroll}px, ${m.top + m.height * 0.04}px, 0) scale(.96)`;
      el.style.width = columnWidth(m, 1 / 2) + "px";
      el.style.height = m.height + "px";
      el.offsetWidth; // commit the starting frame
      el.style.transition = "";
      el.classList.remove("is-new");
    },
  },
  {
    keys: [...CMD, "R"], label: "hud.cycle",
    run: () => {
      const col = cols[focus.col];
      col.w = WIDTHS[(WIDTHS.findIndex((w) => Math.abs(w - col.w) < 0.01) + 1) % WIDTHS.length];
    },
  },
  {
    keys: [...CMD, "["], label: "hud.stack",
    run: () => {
      const [id] = cols[focus.col].wins.splice(focus.row, 1);
      cols.splice(focus.col, 1);
      const left = cols[focus.col - 1];
      left.wins.push(id);
      focus = { col: focus.col - 1, row: left.wins.length - 1 };
    },
  },
  // The stack gets a screen of its own, centered with margins; its neighbours slide away.
  { keys: [...CMD, "C"], label: "hud.centerOwn", run: () => { cols[focus.col].centered = true; } },
  { keys: [...CMD, "H"], label: "hud.focusLeft", run: () => { focus = { col: focus.col - 1, row: 0 }; } },
  { keys: [...CMD, "←"], label: "hud.screenLeft", run: () => { focus = { col: 0, row: 0 }; scroll = 0; } },
];

const STEP_MS = 1900;
let stepIndex = 0, timer = null, running = false;

function tick() {
  if (stepIndex < steps.length) {
    const step = steps[stepIndex++];
    step.run();
    revealFocus(metrics(), step.center);
    showHUD(step.keys, step.label);
    render();
    timer = setTimeout(tick, STEP_MS);
  } else {
    // Start over: fade the strip out, reset, fade back in.
    stripEl.style.transition = "opacity .5s ease";
    stripEl.style.opacity = "0";
    timer = setTimeout(() => {
      initialState();
      for (const id of Object.keys(elements)) { elements[id].remove(); delete elements[id]; }
      render();
      stripEl.style.opacity = "1";
      stepIndex = 0;
      timer = setTimeout(tick, STEP_MS);
    }, 700);
  }
}

function start() { if (!running) { running = true; timer = setTimeout(tick, 1200); } }
function stop() { running = false; clearTimeout(timer); }

/** Re-lays out without animation (first paint, resizes). */
function snap() {
  for (const el of Object.values(elements)) el.style.transition = "none";
  revealFocus(metrics());
  render();
  stripEl.offsetWidth;
  for (const el of Object.values(elements)) el.style.transition = "";
}

initialState();
const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
if (reduceMotion) {
  // A representative still frame: four columns with the focus moved along.
  steps.slice(0, 3).forEach((s) => s.run());
}
snap();
new ResizeObserver(snap).observe(screen);

if (!reduceMotion) {
  new IntersectionObserver(([entry]) => (entry.isIntersecting && !document.hidden ? start() : stop()))
    .observe(screen);
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) stop();
    else if (screen.getBoundingClientRect().bottom > 0) start();
  });
}

/* ---------------- Initial language ---------------- */

let saved = null;
try { saved = localStorage.getItem("strip.lang"); } catch (_) { /* storage unavailable */ }
setLanguage(saved || ((navigator.language || "").toLowerCase().startsWith("tr") ? "tr" : "en"));
