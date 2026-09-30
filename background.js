/* =========================================================
   判斷紀錄 擷取器 — background（直送）

   本來的路：擷取 → 判斷紀錄網站那一頁 → 資料庫。那一頁得開著。
   這裡加的路：擷取 → 直接寫進資料庫。網站關著也送得出去。

   憑什麼能直接寫？因為使用者在網站上發了一組「匯入代碼」給這個外掛。
   這個外掛手上只有三樣東西：網址、公開金鑰、那組代碼。
   拿這三樣只能呼叫 redeem_import_code 一個函式，而那個函式：
     只能寫、只能寫給代碼的主人、會過期、主人隨時可以撤銷。
   所以就算這個外掛被反編譯、storage 被翻出來，
   拿到的人也讀不到任何一個人的任何一段紀錄——它手上從來沒有讀取權。
   ========================================================= */

const RPC = "/rest/v1/rpc/redeem_import_code";

/* 剛擷取到的那一輪先扣著，不要立刻送。
   回答還在串流的時候看起來就已經「停了一下」，這時候送出去的是半截的原文，
   而原文寫進資料庫之後改不了——寧可晚 30 秒，不要送一段不完整的進去。
   扣著的這段時間裡 content.js 還會把回答補完整。 */
const HOLD_MS = 30000;

/* 指紋要跟 content.js、跟網站算的一致，同一輪才不會重複進去 */
function turnKey(t) {
  const s = (t.q || "").slice(0, 150) + "§" + (t.a || "").slice(0, 150);
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
  return String(h);
}

const SITE_NAME = { claude: "Claude", chatgpt: "ChatGPT", gemini: "Gemini" };

const get = keys => new Promise(r => chrome.storage.local.get(keys, r));
const set = obj  => new Promise(r => chrome.storage.local.set(obj, r));

function note(state) {
  return set({ push: { ...state, at: Date.now() } });
}

let running = false;

async function pushAll() {
  if (running) return;
  running = true;
  try {
    const all = await get(null);
    const ep = all.endpoint;

    if (!ep || !ep.url || !ep.key || !ep.code) {
      await note({ ok: false, why: "還沒拿到匯入代碼" });
      return;
    }

    // 這一輪可以送到第幾段為止：跳過還在 HOLD_MS 內、可能還沒講完的尾巴。
    const ripeEnd = r => {
      const cut = Date.now() - HOLD_MS;
      let end = r.turns.length;
      while (end > 0 && (r.turns[end - 1].t || 0) > cut) end--;
      return end;
    };

    // 只送屬於代碼主人的。別人的、還沒指定歸屬的，一律扣在本機。
    //
    // 例外：代碼是手動貼進來的（ep.owner 是空的）。
    // 那條路上外掛不知道你是誰，所以這台電腦擷取到的都算這組代碼主人的。
    // 公用電腦請改用網站上的按鈕發碼，那條路會把歸屬一起帶進來。
    const anyOwner = !ep.owner;
    const keys = (all.index || []).filter(k => {
      const r = all[k];
      return r && (r.turns || []).length && (anyOwner || r.owner === ep.owner)
        && (r.pushed || 0) < ripeEnd(r);
    });

    if (!keys.length) { await note({ ok: true, why: "沒有新的要送" }); return; }

    const batch = keys.slice(0, 20);
    const sent = {};                 // 這一趟每個對話實際送了幾輪
    const logs = batch.map(k => {
      const r = all[k];
      const from = r.pushed || 0;
      const to = Math.min(ripeEnd(r), from + 500);
      sent[k] = to - from;
      return {
        title: r.title || "未命名對話",
        source: `${SITE_NAME[r.site] || r.site} · Chrome 外掛於對話當下擷取 · AI 回覆為原文`
          + (r.claimedLate ? " · 歸屬為事後認領，非擷取當下" : "")
          // 外掛第一次看到這個對話時，畫面上已經有的那幾輪是舊的，
          // 時間戳是擷取當下、不是發話當下。講清楚，不要讓人誤以為是即時記的。
          + (r.backfilled ? ` · 前 ${r.backfilled} 輪為外掛啟用時補抓的既有對話，時間為擷取當下而非發話當下` : ""),
        capturedFrom: r.url,
        // 只送還沒送過、而且已經確定講完的那一段。
        turns: r.turns.slice(from, to)
          .map(t => ({ t: t.t, q: t.q, a: t.a, fp: turnKey(t) }))
      };
    });

    const res = await fetch(ep.url.replace(/\/+$/, "") + RPC, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: ep.key,
        Authorization: "Bearer " + ep.key
      },
      body: JSON.stringify({ _code: ep.code, _logs: logs })
    });

    const text = await res.text();

    if (!res.ok) {
      let why = text;
      try { why = JSON.parse(text).message || text; } catch (e) {}
      const dead = /代碼不能用|does not exist/.test(why);
      await note({ ok: false, why: dead ? "代碼已失效或被撤銷，回網站再發一組" : why });
      return;
    }

    let added = 0;
    try { added = JSON.parse(text).added || 0; } catch (e) {}

    // 送成功才推進水位。失敗就維持原樣，下一輪再送一次。
    // 重新讀一次再寫：送出去的這段時間裡可能又擷取到新的，
    // 拿舊的整筆蓋回去會把那幾輪弄不見。水位只往前推「這趟真的送出去的輪數」。
    const fresh = await get(batch);
    const upd = {};
    batch.forEach(k => {
      const rf = fresh[k];
      if (!rf) return;
      upd[k] = { ...rf, pushed: (all[k].pushed || 0) + (sent[k] || 0) };
    });
    await set(upd);
    await note({ ok: true, why: `直送成功，寫進 ${added} 段` });
  } catch (e) {
    await note({ ok: false, why: "連不上判斷紀錄的資料庫：" + e.message });
  } finally {
    running = false;
  }
}

/* ---------- 一次性清理：把 v0.5.0 存進本機的假紀錄清掉 ----------
   v0.5.0 把介面的狀態字（「3 minutes ago」「Running page script」）
   當成回答存了起來。那些東西還留在本機，不清掉的話，
   就算換了新版，下一次醒來還是會把它們送進資料庫。

   這裡清的是「本機暫存」，不是已經寫進資料庫的紀錄——
   資料庫裡的要刪哪一筆，是使用者自己看過才決定的事。 */
const JUNK_A = [
  /^\s*just now\s*$/i,
  /^\s*\d+\s*(second|minute|hour|day|week|month|year)s?\s+ago\s*$/i,
  /^\s*\d+\s*(分鐘|小時|天|週|個月|年)前\s*$/,
  /^\s*\d+m(\s*\d+s)?\s*$/i,
  /^\s*\d+s\s*$/i,
  /^\s*(thinking|running|running page script|starting preview|taking shape|settling|pressing|needs your input|claude is thinking)\s*$/i
];
function junkAnswer(a) {
  const lines = (a || "").split("\n").map(s => s.trim()).filter(Boolean);
  if (!lines.length) return true;
  return lines.every(line => JUNK_A.some(re => re.test(line)));
}
function qk(t) {
  const s = (t.q || "").replace(/\s+/g, " ").trim().slice(0, 300);
  let h = 0;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
  return "q" + h;
}

async function cleanLocal() {
  const all = await get(null);
  if (all.cleanedV6) return;
  const upd = {};
  let removed = 0;
  for (const k of (all.index || [])) {
    const r = all[k];
    if (!r || !Array.isArray(r.turns)) continue;
    const keep = [];
    const at = {};
    let before = 0;                       // 被移掉、而且位置在水位之前的數量
    r.turns.forEach((t, i) => {
      const drop = () => { removed++; if (i < (r.pushed || 0)) before++; };
      if (junkAnswer(t.a)) return drop();
      const key = qk(t);
      if (key in at) {                    // 同一個問句：留回答最長的那一版
        const j = at[key];
        if ((t.a || "").length > (keep[j].a || "").length) keep[j] = t;
        return drop();
      }
      at[key] = keep.length;
      keep.push(t);
    });
    if (keep.length !== r.turns.length) {
      upd[k] = { ...r, turns: keep, seen: Object.keys(at),
                 pushed: Math.max(0, (r.pushed || 0) - before) };
    }
  }
  upd.cleanedV6 = true;
  await set(upd);
  await note({ ok: true, why: `已清掉本機 ${removed} 段介面狀態字與重複` });
  console.log(`[判斷紀錄] 本機清理：移除 ${removed} 段`);
}

chrome.runtime.onMessage.addListener((m) => {
  if (m && m.kind === "push") pushAll();
});

/* service worker 會被瀏覽器收掉，所以用鬧鐘定期醒來補送。
   擷取當下沒送成功（斷網、代碼剛換）的，一分鐘後會自己再試。 */
chrome.alarms.create("jl-push", { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener((a) => { if (a.name === "jl-push") cleanLocal().then(pushAll); });
chrome.runtime.onStartup.addListener(() => cleanLocal().then(pushAll));
chrome.runtime.onInstalled.addListener(() => cleanLocal().then(pushAll));
