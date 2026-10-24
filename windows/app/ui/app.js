// Clouding Bar for Windows: the widget's page. The app sends its state
// ("state" events, once a second at least); this draws the pill, the panel
// or Claude's request, and sends back what you pick.
const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

let snap = null;
let expanded = false;
let openTimer = null, closeTimer = null;
let otherText = "";
let lastSize = "";
// A new card takes Esc and the digits only after a moment, so a key meant
// for the window behind can't answer it.
const ARM_MS = 1200;
let armedId = null, armedAt = 0;

const root = document.getElementById("root");
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const pct = (p) => (p == null ? "—" : Math.round(p) + "%");

function bar(p, cls = "") {
  const v = Math.max(0, Math.min(100, p ?? 0));
  const tone = v >= 90 ? "full" : v >= 75 ? "warn" : "";
  return `<div class="bar ${tone} ${cls}"><i style="width:${v}%"></i></div>`;
}

/** Cloud, from the mascot's 40-unit drawing: asleep, working or waiting. */
function cloud(activity, size, grab = false) {
  const ink = "#1C1C1E";
  const body = activity === "sleep" ? "#B8B6B1" : "#ECEAE5";
  let face = "";
  if (activity === "sleep") {
    face = `<path d="M13.6 22.2 q2.4 1.8 4.8 0 M21.6 22.2 q2.4 1.8 4.8 0" stroke="#2C2C2E" stroke-width="1.6" fill="none" stroke-linecap="round"/>`;
  } else if (activity === "wait") {
    face = `<ellipse cx="16" cy="20.5" rx="2.2" ry="3" fill="${ink}"/><ellipse cx="24" cy="20.5" rx="2.2" ry="3" fill="${ink}"/><ellipse cx="20" cy="27" rx="1.6" ry="1.2" fill="${ink}"/>`;
  } else {
    face = `<ellipse cx="16" cy="20.5" rx="2" ry="2.8" fill="${ink}"/><ellipse cx="24" cy="20.5" rx="2" ry="2.8" fill="${ink}"/>`;
  }
  const extras = activity === "sleep"
    ? `<g class="zs" fill="#8E8E93" font-weight="600"><text x="27" y="15" font-size="4">z</text><text x="30" y="12" font-size="5">z</text><text x="33" y="8.5" font-size="6">z</text></g>`
    : activity === "work"
      ? `<g class="dots" fill="#A1A1A6"><circle cx="14" cy="4.5" r="1.5"/><circle cx="20" cy="4.5" r="1.5"/><circle cx="26" cy="4.5" r="1.5"/></g>`
      : `<g class="badge"><circle cx="33" cy="8" r="4.2" fill="#FF9F0A"/><rect x="32.3" y="5.4" width="1.4" height="3.4" rx=".7" fill="${ink}"/><circle cx="33" cy="10.4" r=".8" fill="${ink}"/></g>`;
  return `<svg class="cloud ${activity} ${grab ? "grab" : ""}" ${grab ? "data-tauri-drag-region" : ""} viewBox="0 0 40 40" width="${size}" height="${size}">
    <ellipse cx="20" cy="35.5" rx="9" ry="1.6" fill="#000" opacity=".35"/>
    <g class="body"><rect x="7" y="11" width="26" height="23" rx="11.5" fill="${body}"/>${face}</g>${extras}</svg>`;
}

/** A chat's colour dot and its name; "other chat" when it isn't the one shown. */
function chatTag(name, color, elsewhere = false, done = false) {
  if (!name) return "";
  const dot = done ? `<i class="cdone">✓</i>` : `<i class="cdot" style="background:${esc(color)}"></i>`;
  return `<span class="chat-tag">${dot}<span class="cname">${esc(name)}</span>${
    elsewhere ? `<span class="other-chat">other chat</span>` : ""}</span>`;
}

function statusTitle(s) {
  if (s.request) return s.request.kind === "question" ? "Claude asks" : "Needs your OK";
  return { work: "Working", wait: "Needs your OK", sleep: "Idle" }[s.activity] || "Idle";
}

// MARK: Views

function pill(s) {
  if (!s.hasSession) {
    return `<div class="pill glass" data-open>${cloud("sleep", 30, true)}<span class="num label">${pct(s.sessionPercent)}</span></div>`;
  }
  const reset = s.resetShort ? `<div class="item"><span class="label">↻</span><span class="num">${esc(s.resetShort)}</span></div>` : "";
  // With several chats: which one this is.
  const chat = s.sessions.length > 1 ? `<div class="item">${chatTag(s.chatName, s.chatColor, false, s.chatDone)}</div>` : "";
  return `<div class="pill glass ${s.request ? "waiting" : ""}" data-open>
    ${cloud(s.activity, 30, true)}${chat}
    <div class="item">${bar(s.sessionPercent)}<span class="num">${pct(s.sessionPercent)}</span></div>
    <div class="item"><span class="label">ctx</span>${bar(s.contextPercent)}<span class="num">${pct(s.contextPercent)}</span></div>
    ${reset}
  </div>`;
}

function head(s, title, sub, tag = "") {
  return `<div class="head">${cloud(s.request ? "wait" : s.activity, 24, true)}
    <span class="title">${esc(title)}</span>${tag}<span class="sub">${esc(sub || "")}</span>
    <span class="spacer"></span>
    ${s.request ? "" : `<button class="icon-btn" data-close title="Collapse">⌃</button>`}</div>`;
}

/** Every chat as a tab, the one shown lit in its colour; a click follows another. */
function tabs(s) {
  return `<div class="tabs">${s.sessions.map((x) => `<button class="tab ${x.current ? "current" : ""}" data-focus="${esc(x.id)}"
      style="--c:${esc(x.color)}" title="${esc([x.place, x.status].join(" · "))}">
      <i class="cdot" style="background:${esc(x.color)}"></i><span class="cname">${esc(x.name)}</span>${
      x.waiting ? `<span class="dot wait"></span>` : ""}</button>`).join("")}</div>`;
}

function panel(s) {
  const several = s.sessions.length > 1;
  const line = [s.chatPlace, s.chatStatus].filter(Boolean).join(" · ");
  const parts = [`<div class="head">${cloud(s.request ? "wait" : s.activity, 24, true)}
    <div class="who">${several ? tabs(s) : `<span class="title">${esc(s.chatName || statusTitle(s))}</span>`}
      <span class="sub">${esc(line)}</span></div>
    <span class="spacer"></span><button class="icon-btn" data-close title="Collapse">⌃</button></div>`];
  parts.push(`<div class="meters">
    <div class="meter"><div class="row"><span class="name">Session</span><span class="val num">${pct(s.sessionPercent)}</span></div>${bar(s.sessionPercent)}
      <div class="cap">${s.reset ? "Resets in " + esc(s.reset) : "5-hour limit"}</div></div>
    <div class="meter"><div class="row"><span class="name">Context</span><span class="val num">${pct(s.contextPercent)}</span></div>${bar(s.contextPercent)}
      <div class="cap">${esc(s.model || "")}</div></div></div>`);
  const chips = [];
  if (s.weekPercent != null) chips.push(`Week ${pct(s.weekPercent)}`);
  if (chips.length) parts.push(`<div class="chips">${chips.map((c) => `<span class="chip num">${esc(c)}</span>`).join("")}</div>`);
  if (!s.hooksConnected) {
    parts.push(`<div class="notice"><span>Clouding Bar isn't connected to Claude Code yet: it adds a hook to ~/.claude/settings.json (backed up first).</span>
      <button class="btn primary" data-connect>Connect</button></div>`);
  }
  if (s.setupMessage) parts.push(`<div class="hint">${esc(s.setupMessage)}</div>`);
  return `<div class="panel glass enter">${parts.join("")}</div>`;
}

function request(s) {
  const r = s.request;
  if (r.kind === "permission") {
    return `<div class="panel glass enter">${head(s, "Needs your OK", r.verb === "Run" ? "run in terminal" : r.verb.toLowerCase(), chatTag(r.chat, r.chatColor, r.elsewhere))}
      <div class="code" tabindex="0">${esc(r.detail)}</div>${
        (r.detail.includes("⏎") || r.detail.length > 120) ? `<div class="code-note">Long or multi-line command: scroll to read all of it before allowing.</div>` : ""}
      <div class="btns"><button class="btn primary" data-answer="allow">Allow</button>
        <button class="btn" data-answer="always">Always allow</button>
        <button class="btn deny" data-answer="deny">Deny</button></div></div>`;
  }
  const options = r.options.map((o, i) => `<button class="option ${r.picked.includes(i) ? "picked" : ""}" data-option="${i}">
      ${r.multiSelect ? `<span class="check"></span>` : `<span class="key">${i < 9 ? i + 1 : ""}</span>`}
      <span>${esc(o)}${r.descriptions[i] ? `<span class="desc">${esc(r.descriptions[i])}</span>` : ""}</span></button>`).join("");
  const send = r.multiSelect && r.picked.length
    ? `<button class="btn primary" data-answer="send">Send ${r.picked.length} selected</button>` : "";
  return `<div class="panel glass enter">${head(s, "Claude asks", r.count > 1 ? `${r.index + 1} of ${r.count}` : "", chatTag(r.chat, r.chatColor, r.elsewhere))}
    <div class="question">${esc(r.question)}</div>
    <div class="options">${options}
      <div class="other"><span class="hint">Other</span><input id="other" value="${esc(otherText)}" spellcheck="false">
        <button class="send" data-answer="other" title="Send">↑</button></div></div>
    ${send}<div class="hint">${r.options.length ? `1–${Math.min(9, r.options.length)} to pick` : ""}</div></div>`;
}

// MARK: Drawing

function render() {
  if (!snap) return;
  if (snap.request && snap.request.id !== armedId) { armedId = snap.request.id; armedAt = Date.now(); }
  const typing = document.activeElement && document.activeElement.id === "other";
  const caret = typing ? document.activeElement.selectionStart : null;
  root.innerHTML = snap.request ? request(snap) : expanded ? panel(snap) : pill(snap);
  if (typing) {
    const input = document.getElementById("other");
    if (input) { input.focus(); input.setSelectionRange(caret, caret); }
  }
  // The window takes the page's size.
  const box = root.getBoundingClientRect();
  const size = `${Math.ceil(box.width)}x${Math.ceil(box.height)}`;
  if (size !== lastSize) {
    lastSize = size;
    invoke("resize", { width: Math.ceil(box.width), height: Math.ceil(box.height) });
  }
}

function setExpanded(v) {
  if (expanded === v) return;
  expanded = v;
  render();
}

// MARK: Pointer and keys

root.addEventListener("mouseenter", () => {
  clearTimeout(closeTimer);
  if (!expanded) openTimer = setTimeout(() => setExpanded(true), 2000);
});
root.addEventListener("mouseleave", () => {
  clearTimeout(openTimer);
  if (snap && snap.request) return;
  closeTimer = setTimeout(() => setExpanded(false), 400);
});

root.addEventListener("click", (e) => {
  const t = e.target.closest("[data-answer],[data-option],[data-close],[data-connect],[data-focus],[data-open]");
  if (!t || !snap) return;
  const r = snap.request;
  if (t.dataset.answer) {
    const action = t.dataset.answer;
    const text = action === "other" ? otherText : null;
    if (action === "other" && !otherText.trim() && !(r && r.picked.length)) return;
    if (action === "other") otherText = "";
    invoke("answer", { id: r.id, action, index: null, text });
  } else if (t.dataset.option != null) {
    invoke("answer", { id: r.id, action: "option", index: Number(t.dataset.option), text: null });
  } else if ("close" in t.dataset) {
    setExpanded(false);
  } else if ("connect" in t.dataset) {
    invoke("connect_claude");
  } else if (t.dataset.focus) {
    invoke("focus_session", { id: t.dataset.focus });
  } else if ("open" in t.dataset && !e.target.closest("[data-tauri-drag-region]")) {
    clearTimeout(openTimer);
    setExpanded(true);
  }
});

root.addEventListener("input", (e) => {
  if (e.target.id === "other") {
    otherText = e.target.value;
    if (snap && snap.request) invoke("touch", { id: snap.request.id });
  }
});

document.addEventListener("keydown", (e) => {
  const r = snap && snap.request;
  if (!r) { if (e.key === "Escape") setExpanded(false); return; }
  const armed = Date.now() - armedAt >= ARM_MS;
  if (e.key === "Enter" && document.activeElement && document.activeElement.id === "other") {
    if (otherText.trim() || r.picked.length) {
      const text = otherText;
      otherText = "";
      invoke("answer", { id: r.id, action: "other", index: null, text });
    }
  } else if (armed && r.kind === "permission" && e.key === "Escape") {
    invoke("answer", { id: r.id, action: "deny", index: null, text: null });
  } else if (armed && r.kind === "question" && /^[1-9]$/.test(e.key) && document.activeElement?.id !== "other") {
    const i = Number(e.key) - 1;
    if (i < r.options.length) invoke("answer", { id: r.id, action: "option", index: i, text: null });
  }
});

listen("state", (e) => {
  const hadRequest = snap && snap.request;
  snap = e.payload;
  if (hadRequest && !snap.request) { otherText = ""; setTimeout(() => setExpanded(false), 300); }
  render();
});
invoke("snapshot").then((s) => { snap = s; render(); });
invoke("start_expanded").then((v) => { if (v) setExpanded(true); });
