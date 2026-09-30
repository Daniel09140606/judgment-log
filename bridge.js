/* =========================================================
   判斷紀錄 擷取器 — bridge
   在判斷紀錄網站的頁面上跑，做兩件事：

   1. 接收網站送來的「現在登入的是誰」，存成歸屬。
      擷取當下就蓋上歸屬，不是事後看誰登入——公用電腦才不會記錯人。
   2. 把本機擷取到的、屬於這個人的對話廣播給網站。

   外掛全程不持有任何帳號或金鑰。寫進資料庫的是網站，用使用者自己的身分。
   ========================================================= */

const CH_DATA  = "judgment-log-capture";   // 外掛 → 網站：這是擷取到的對話
const CH_OWNER = "judgment-log-owner";     // 網站 → 外掛：現在登入的是誰
const CH_EP    = "judgment-log-endpoint";  // 網站 → 外掛：一組只能寫的匯入代碼
const EVERY_MS = 4000;

const SITE_NAME = { claude: "Claude", chatgpt: "ChatGPT", gemini: "Gemini" };

let bTimer = null;
let lastSaid = "";
/* 狀態變了才印，不要每 4 秒洗版 */
function say(s) {
  if (s === lastSaid) return;
  lastSaid = s;
  console.log("[判斷紀錄] " + s);
}
function alive() {
  try { return !!(chrome.runtime && chrome.runtime.id); } catch (e) { return false; }
}

/* ---------- 網站告訴我們現在是誰 ---------- */
window.addEventListener("message", (e) => {
  const d = e.data;
  if (!d || d.type !== CH_OWNER || !alive()) return;
  const u = d.user;
  try {
    if (u && u.id) {
      chrome.storage.local.set({ owner: { id: u.id, name: u.name || "", at: Date.now() } });
    } else {
      chrome.storage.local.remove("owner");
    }
  } catch (err) { /* 外掛已重新載入 */ }
});

/* ---------- 網站交給我們一組匯入代碼 ----------
   收到之後，這一頁關著也送得出去（由 background.js 直送）。
   拿到的只有網址、公開金鑰、代碼——沒有帳號、沒有密碼、沒有登入狀態，
   而且那組代碼在資料庫那邊只能寫、不能讀。 */
window.addEventListener("message", (e) => {
  const d = e.data;
  if (!d || d.type !== CH_EP || !alive()) return;
  try {
    if (d.endpoint && d.endpoint.code && d.endpoint.owner) {
      chrome.storage.local.set({ endpoint: d.endpoint }, () => {
        try { chrome.runtime.sendMessage({ kind: "push" }); } catch (err) {}
      });
    } else {
      chrome.storage.local.remove("endpoint");   // 代碼被撤銷了
    }
  } catch (err) {}
});

function toLog(rec) {
  return {
    title: rec.title || "未命名對話",
    course: "", semester: "", scope: "self",
    source: `${SITE_NAME[rec.site] || rec.site} · Chrome 外掛於對話當下擷取 · AI 回覆為原文`
      + (rec.claimedLate ? " · 歸屬為事後認領，非擷取當下" : ""),
    capturedFrom: rec.url,
    turns: (rec.turns || []).map(t => ({ t: t.t, q: t.q, a: t.a }))
  };
}

function broadcast() {
  if (!alive()) {
    if (bTimer) clearInterval(bTimer);
    console.log("[判斷紀錄] bridge 停止：外掛已重新載入，重新整理這一頁即可繼續。");
    return;
  }
  try {
    chrome.storage.local.get(null, (all) => {
      const owner = all.owner;
      const all_keys = (all.index || []).filter(k => all[k] && (all[k].turns || []).length);

      if (!owner || !owner.id) {
        say(`尚未取得歸屬（本機有 ${all_keys.length} 個對話，先扣著不送）。`
          + `請確認判斷紀錄網站這一頁是登入狀態。`);
        return;
      }

      // 只送屬於這個人的。別人的、還沒指定歸屬的，都扣在本機。
      const keys = all_keys.filter(k => all[k].owner === owner.id);
      if (!keys.length) {
        const none = all_keys.filter(k => !all[k].owner).length;
        say(`歸屬：${owner.name || owner.id.slice(0, 8)}，但沒有屬於他的對話。`
          + (none ? `有 ${none} 個是登入前擷取的，到外掛視窗按「認領為我的」。` : ""));
        return;
      }
      say(`廣播 ${keys.length} 個對話給判斷紀錄（歸屬：${owner.name || ""}）。`);

      const msg = { type: CH_DATA, at: Date.now(), owner: owner.id, logs: keys.map(k => toLog(all[k])) };
      window.postMessage(msg, "*");                         // 網站本身
      document.querySelectorAll("iframe").forEach(f => {    // 包在 iframe 裡的情況
        try { f.contentWindow.postMessage(msg, "*"); } catch (e) {}
      });
    });
  } catch (e) { if (bTimer) clearInterval(bTimer); }
}

bTimer = setInterval(broadcast, EVERY_MS);
setTimeout(broadcast, 1200);
console.log("[判斷紀錄] bridge 已啟動");
