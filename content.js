/* =========================================================
   判斷紀錄 擷取器 — content script
   在對話頁面上把每一輪往返擷取下來，存進瀏覽器本機。

   這一版是 DOM 層擷取：讀畫面上已經出現的訊息。
   正式版應該做傳輸層攔截（攔 fetch / SSE），那樣不會因為網站改版就失效。
   這裡先證明「擷取這件事在使用者端做得到，而且不需要 AI 自己配合」。
   ========================================================= */

const HOST = location.hostname;
const SITE =
  HOST.includes("claude.ai")    ? "claude"  :
  HOST.includes("chatgpt.com")  ? "chatgpt" :
  HOST.includes("openai.com")   ? "chatgpt" :
  HOST.includes("gemini.google")? "gemini"  : null;

/* 各站的訊息節點選擇器。網站改版時要改的就是這一段。
   每個站給多組備援，前面的找不到就換下一組。 */
const SELECTORS = {
  chatgpt: {
    user: ['[data-message-author-role="user"]'],
    ai:   ['[data-message-author-role="assistant"]']
  },
  claude: {
    user: ['[data-testid="user-message"]', '.font-user-message'],
    ai:   ['.font-claude-message', '[data-testid="assistant-message"]',
           '[data-is-streaming] .font-claude-message']
  },
  gemini: {
    // user-query / model-response 是 Angular 的元件標籤，比 class 穩定，
    // 所以放在最後當保底：class 改名了還抓得到。
    user: ['user-query-content', 'user-query .query-text', 'user-query'],
    ai:   ['model-response message-content', 'model-response']
  }
};

/* ---------- 只讀「使用者真的看得到」的文字 ----------
   為什麼需要這個：有些網站會在同一塊裡放兩份相同的文字——
   一份給你看，一份是編輯用的輸入框或螢幕閱讀器專用的隱藏副本。
   直接讀 innerText 就會把同一句話收兩次。

   注意這裡做的不是「偵測到重複就刪掉一份」。
   那種做法會把真的打了兩次的人的原文改掉，
   而一個原文會被系統偷偷改寫的紀錄，拿去當證據是沒有價值的。
   這裡做的是：不要去讀畫面上根本看不到的那一份。 */
const SKIP_TAG = { TEXTAREA: 1, INPUT: 1, BUTTON: 1, SCRIPT: 1, STYLE: 1, SVG: 1, NOSCRIPT: 1 };
const BLOCKISH = /^(block|flex|grid|list-item|table|flow-root)/;

function hidden(el) {
  const cs = getComputedStyle(el);
  if (cs.display === "none" || cs.visibility === "hidden") return true;
  if (parseFloat(cs.opacity) === 0) return true;
  // 螢幕閱讀器專用的老招式：裁成 0、或縮到 1px
  if (cs.clip === "rect(0px, 0px, 0px, 0px)") return true;
  if (cs.clipPath === "inset(50%)") return true;
  const r = el.getBoundingClientRect();
  if (r.width <= 1 && r.height <= 1) return true;
  return false;
}

function visibleText(root) {
  const out = [];
  const walk = (n) => {
    if (n.nodeType === 3) { if (n.nodeValue && n.nodeValue.trim()) out.push(n.nodeValue); return; }
    if (n.nodeType !== 1) return;
    if (SKIP_TAG[n.tagName]) return;
    if (n.getAttribute("aria-hidden") === "true") return;
    let block = false;
    try { if (hidden(n)) return; block = BLOCKISH.test(getComputedStyle(n).display); } catch (e) {}
    if (block) out.push("\n");
    for (const c of n.childNodes) walk(c);
    if (block) out.push("\n");
  };
  walk(root);
  return out.join("")
    .replace(/ /g, " ")
    .replace(/[ \t]+/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .split("\n").map(s => s.trim()).join("\n")
    .trim();
}

const POLL_MS   = 1500;   // 多久看一次畫面
const STABLE_MS = 9000;   // 內容多久沒變才算「這一輪講完了」

/* ---------- 不是回答的東西，不要當成回答 ----------
   2026-09-30：在 claude.ai 上抓到 71 段假紀錄，內容是
   「3 minutes ago」「Running page script」「2m 51s」「Needs your input」——
   這些是介面自己的狀態字，不是 AI 的回答。它們每隔幾秒就換一次，
   於是每換一次就被當成一輪新的對話存進去，同一個問題被記了 42 次。

   這裡擋掉的是「明顯不是回答的字串」，不是「看起來像重複的字串」。
   兩者差很多：後者會動到真正的原文，那是這套系統不能做的事。 */
const JUNK_A = [
  /^\s*just now\s*$/i,
  /^\s*\d+\s*(second|minute|hour|day|week|month|year)s?\s+ago\s*$/i,
  /^\s*\d+\s*(分鐘|小時|天|週|個月|年)前\s*$/,
  /^\s*\d+m(\s*\d+s)?\s*$/i,          // 2m 51s
  /^\s*\d+s\s*$/i,
  /^\s*(thinking|running|running page script|starting preview|taking shape|settling|pressing|needs your input|claude is thinking)\s*$/i
];

/* 狀態字常常被重複貼成「Thinking\nThinking\n27s\nrunning」這種形狀，
   所以逐行檢查：每一行都是狀態字（或空白），整段就不是回答。 */
function junkAnswer(a) {
  const lines = (a || "").split("\n").map(s => s.trim()).filter(Boolean);
  if (!lines.length) return true;
  return lines.every(line => JUNK_A.some(re => re.test(line)));
}

let lastSig = "";
let stableSince = 0;
let timers = [];

/* 重新載入外掛之後，舊分頁裡的這份腳本會失去跟外掛的連線。
   偵測到就自己停掉，不要繼續噴錯。 */
function alive() {
  try { return !!(chrome.runtime && chrome.runtime.id); } catch (e) { return false; }
}
function stopAll() {
  timers.forEach(clearInterval);
  timers = [];
  console.log("[判斷紀錄] 外掛已重新載入，這個分頁的舊腳本停止。重新整理分頁即可繼續擷取。");
}

function start() {
  timers.push(setInterval(tick, POLL_MS));
  // 換對話（單頁應用不會重新載入）時重來一次
  let lastPath = location.pathname;
  timers.push(setInterval(() => {
    if (!alive()) return stopAll();
    if (location.pathname !== lastPath) { lastPath = location.pathname; lastSig = ""; }
  }, 1000));
}

function pick(list) {
  for (const sel of list) {
    const found = document.querySelectorAll(sel);
    if (found.length) return [...found];
  }
  return [];
}

/* 把畫面上的訊息依 DOM 順序排成一串。
   deep=false：只拿 innerText 算長度，用來判斷「畫面還在不在變」，很便宜。
   deep=true ：真的要寫進紀錄了，才跑比較貴的可見文字萃取。 */
function readMessages(deep) {
  const s = SELECTORS[SITE];
  const items = [
    ...pick(s.user).map(n => ({ role: "user", n })),
    ...pick(s.ai).map(n => ({ role: "ai", n }))
  ];
  items.sort((a, b) =>
    (a.n.compareDocumentPosition(b.n) & Node.DOCUMENT_POSITION_FOLLOWING) ? -1 : 1);
  return items
    .map(x => {
      let text = (x.n.innerText || "").trim();
      if (deep) {
        const v = visibleText(x.n);
        if (v) text = v;          // 萃取失敗就退回 innerText，寧可多讀也不要漏掉整輪
      }
      return { role: x.role, text };
    })
    .filter(x => x.text);
}

/* 一則使用者訊息 + 緊接著的一則 AI 回覆 = 一輪 */
function toTurns(msgs) {
  const turns = [];
  let q = null;
  for (const m of msgs) {
    if (m.role === "user") q = m.text;
    else if (q !== null) { turns.push({ q, a: m.text }); q = null; }
  }
  return turns;
}

function tick() {
  if (!alive()) return stopAll();
  const msgs = readMessages(false);
  const sig = msgs.map(m => m.role + ":" + m.text.length).join("|");

  // 畫面還在變（正在串流）就先不寫
  if (sig !== lastSig) { lastSig = sig; stableSince = Date.now(); return; }
  if (!sig || Date.now() - stableSince < STABLE_MS) return;

  const turns = toTurns(readMessages(true));
  if (!turns.length) return;
  if (turns.length !== lastCount) {
    lastCount = turns.length;
    console.log(`[判斷紀錄] 畫面上目前看得到 ${turns.length} 輪`);
  }
  save(turns);
}
let lastCount = -1;

/* 一輪的身分：只看「問句」。
   原本這裡把回答也算進去，結果是回答只要多一個字就變成另一輪。
   串流中的回答每秒都在長，介面的狀態字每幾秒換一次——
   於是同一個問題被存成幾十輪。

   在同一個對話網址底下，一個問句就是一輪。
   回答會從不完整長到完整，那是同一輪的不同時刻，不是兩輪。 */
function qKey(t) {
  const s = (t.q || "").replace(/\s+/g, " ").trim().slice(0, 300);
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
  return "q" + h;
}

/* 舊版的指紋（問+答）。舊紀錄的 seen 清單裡存的是這個，
   升級後要讀得懂，不然已經存過的會被當成新的再存一次。 */
function legacyKey(t) {
  const s = (t.q || "").slice(0, 150) + "§" + (t.a || "").slice(0, 150);
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
  return String(h);
}

function save(turns) {
  if (!alive()) return stopAll();
  const key = "conv::" + SITE + "::" + location.pathname;
  try { chrome.storage.local.get([key, "index", "owner"], (data) => {
    const now = Date.now();
    const owner = data.owner?.id || null;   // 擷取當下就蓋上歸屬
    const isNew = !data[key];
    const rec = data[key] || {
      site: SITE,
      owner,
      url: location.href,
      title: (document.title || "未命名對話").replace(/\s*[-|–]\s*(Claude|ChatGPT|Gemini).*$/i, ""),
      firstSeen: now,
      turns: []
    };

    // 第一次在一個「已經聊了好幾輪」的對話上跑起來時，畫面上那些都是舊的。
    // 它們會被蓋上「現在」的時間，但那不是它們發生的時間——
    // 這套系統整個前提是「當下決定，事後不補」，
    // 所以這種情況要標出來，不能讓它看起來像當下擷取的。
    if (isNew && turns.length > 1) rec.backfilled = turns.length;

    // 用內容比對決定哪幾輪是新的。
    // 不能用「畫面上有幾輪」減「已存幾輪」——ChatGPT 會把捲出畫面的舊訊息從 DOM 移除，
    // 畫面上的輪數會變少，用數量比就會漏掉新的那一輪。
    //
    // 認的是問句。同一個問句再看到，代表「這一輪的回答又長了一點」，
    // 不是新的一輪：還沒送出去的話就把回答換成比較完整的那一版，
    // 已經送出去的就不要再動——送進資料庫的原文不可修改，是這套系統的地基。
    const pushed = rec.pushed || 0;
    const legacy = new Set(rec.seen || []);
    const idx = {};
    rec.turns.forEach((t, i) => { idx[qKey(t)] = i; });

    let added = 0, grown = 0, junk = 0;
    for (const t of turns) {
      if (junkAnswer(t.a)) { junk++; continue; }      // 介面狀態字，不是回答

      const k = qKey(t);
      if (k in idx) {
        const i = idx[k];
        if (i < pushed) continue;                      // 已送出，不動
        if ((t.a || "").length > (rec.turns[i].a || "").length) {
          rec.turns[i].a = t.a;                        // 同一輪，回答更完整了
          grown++;
        }
        continue;
      }
      if (legacy.has(legacyKey(t))) continue;          // 舊版存過的，別重存

      idx[k] = rec.turns.length;
      rec.turns.push({ t: now, q: t.q, a: t.a });
      added++;
    }
    rec.seen = Object.keys(idx);
    if (junk && !added && !grown) return;
    if (!added && !grown) return;

    rec.title = (document.title || rec.title).replace(/\s*[-|–]\s*(Claude|ChatGPT|Gemini).*$/i, "");
    rec.lastSeen = now;
    if (rec.owner === undefined) rec.owner = owner;   // 舊紀錄補上欄位

    const index = new Set(data.index || []);
    index.add(key);

    chrome.storage.local.set({ [key]: rec, index: [...index] }, () => {
      if (added) badge(added);
      console.log(`[判斷紀錄] 新增 ${added} 輪、補完 ${grown} 輪`
        + (junk ? `、擋掉 ${junk} 段介面狀態字` : "")
        + `，本對話累計 ${rec.turns.length} 輪`);
      // 有匯入代碼就直接送進資料庫，不必等判斷紀錄那一頁開著。
      // 沒有代碼的話這一句什麼也不會發生，還是走原本的路。
      try { chrome.runtime.sendMessage({ kind: "push" }); } catch (e) {}
    });
  }); } catch (e) { stopAll(); }
}

/* 畫面右下角閃一下，讓你知道它真的在記 */
function badge(n) {
  let el = document.getElementById("__jl_badge");
  if (!el) {
    el = document.createElement("div");
    el.id = "__jl_badge";
    el.style.cssText = [
      "position:fixed", "right:18px", "bottom:18px", "z-index:2147483647",
      "background:#0F5C4A", "color:#F4F5F3", "padding:8px 14px", "border-radius:8px",
      "font:500 13px/1.5 system-ui,-apple-system,'Noto Sans TC',sans-serif",
      "box-shadow:0 2px 10px rgba(0,0,0,.18)", "pointer-events:none",
      "opacity:0", "transition:opacity .25s"
    ].join(";");
    document.body.appendChild(el);
  }
  el.textContent = `判斷紀錄：已擷取 ${n} 輪`;
  el.style.opacity = "1";
  clearTimeout(el.__t);
  el.__t = setTimeout(() => { el.style.opacity = "0"; }, 2200);
}

/* ---------- 診斷 ----------
   網站改版的時候，最需要知道的是「外掛在這一頁到底看到什麼」。
   以前這要開 F12 貼程式碼；現在外掛視窗按一顆按鈕就好。
   （這裡只有讀跟回報，不會動到頁面上的任何東西。） */
function firstHit(list) {
  for (const sel of list) {
    try { if (document.querySelectorAll(sel).length) return sel; } catch (e) {}
  }
  return null;
}

function diagnose() {
  const s = SELECTORS[SITE] || { user: [], ai: [] };
  const probe = list => list.map(sel => {
    let n = -1;
    try { n = document.querySelectorAll(sel).length; } catch (e) {}
    return { sel, n };
  });
  const msgs = readMessages(true);
  return {
    site: SITE, url: location.href,
    user: probe(s.user), ai: probe(s.ai),
    used: { user: firstHit(s.user), ai: firstHit(s.ai) },
    seen: msgs.map(m => ({
      role: m.role, len: m.text.length,
      head: m.text.slice(0, 70).replace(/\n/g, "⏎"),
      // 同一句話被收兩次的話，這裡會是 true——用來確認問題有沒有好
      twice: m.text.length > 6 &&
             m.text.slice(0, Math.floor(m.text.length / 2)).trim() ===
             m.text.slice(Math.ceil(m.text.length / 2)).trim()
    })),
    turns: toTurns(msgs).length
  };
}

try {
  chrome.runtime.onMessage.addListener((m, _s, reply) => {
    if (!m || m.kind !== "diag") return;
    try { reply(diagnose()); } catch (e) { reply({ error: String(e) }); }
    return true;
  });
} catch (e) {}

/* 啟動要放在最後：上面那些 const 都定義完了才開始跑 */
if (SITE) {
  console.log(`[判斷紀錄] 已啟動，站台：${SITE}`);
  start();
} else {
  console.log("[判斷紀錄] 這個網站不在支援清單內");
}
