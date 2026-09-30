/* 判斷紀錄 擷取器 — popup：看擷取到什麼、匯出成判斷紀錄的格式 */

/* 你的 Supabase 專案。換成自己的專案時改這兩行。
   anon key 是公開金鑰，本來就設計成要出現在每個人的瀏覽器裡，
   寫在這裡沒問題——真正的防線是資料庫的 Row Level Security。
   ⚠ service_role 那一把永遠不要放進來。 */
const SUPABASE_URL = "https://wgjyfrawkveydwpqlkfv.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndnanlmcmF3a3ZleWR3cHFsa2Z2Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODkyNTgzMDMsImV4cCI6MjEwNDgzNDMwM30.orOnN8CYia663OdZOBcxpq2r6gPwli-cY2Fiob_rnB8";

const SITE_NAME = { claude: "Claude", chatgpt: "ChatGPT", gemini: "Gemini" };
const esc = s => String(s ?? "").replace(/[&<>"]/g,
  c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const p2 = n => String(n).padStart(2, "0");
const clock = t => { const d = new Date(t);
  return `${p2(d.getMonth() + 1)}-${p2(d.getDate())} ${p2(d.getHours())}:${p2(d.getMinutes())}`; };

let store = {};

load();

function load() {
  chrome.storage.local.get(null, (all) => {
    store = all || {};
    const keys = (store.index || []).filter(k => store[k]);
    render(keys);
  });
}

function render(keys) {
  const status = document.getElementById("status");
  const list = document.getElementById("list");
  const note = document.getElementById("note");

  const owner = store.owner;
  const mine   = keys.filter(k => owner && store[k].owner === owner.id);
  const others = keys.filter(k => store[k].owner && (!owner || store[k].owner !== owner.id));
  const none   = keys.filter(k => !store[k].owner);
  const turns  = mine.reduce((n, k) => n + (store[k].turns || []).length, 0);

  if (!owner) {
    status.className = "status warn";
    status.innerHTML = `<b>還沒指定歸屬。</b>打開判斷紀錄網站並登入，這裡就會顯示你的名字，`
      + `之後擷取到的對話會直接算在你名下。在那之前擷取到的東西會扣在本機不送出。`
      + (none.length ? `<br>目前有 <b>${none.length}</b> 個未指定歸屬的對話。` : "");
  } else {
    status.className = "status";
    status.innerHTML = `目前歸屬：<b class="ok">${esc(owner.name || owner.id.slice(0, 8))}</b><br>`
      + `屬於你的有 <b class="ok">${mine.length}</b> 個對話、<b class="ok">${turns}</b> 輪往返。`
      + `原文與時間都是擷取當下寫下的，這個外掛不會改它們。`
      + (others.length ? `<br>另有 <b>${others.length}</b> 個對話屬於別人，不會送到你的帳號。` : "")
      + (none.length ? `<br>還有 <b>${none.length}</b> 個是登入前擷取的，沒有歸屬。` : "");
  }

  // 直送狀態：有匯入代碼的話，判斷紀錄那一頁關著也送得出去
  const ep = store.endpoint, ps = store.push;
  const send = document.getElementById("send");
  if (!ep) {
    send.className = "status warn";
    send.innerHTML = `<b>直送未開。</b>到判斷紀錄網站下方「匯入代碼」發一組，`
      + `貼進下面這一格就會開始送——網站在哪個網址都沒關係。`;
    document.getElementById("codebox").hidden = false;
  } else {
    document.getElementById("codebox").hidden = true;
    send.className = "status";
    send.innerHTML = `直送已開，代碼 <b class="ok">${esc(ep.code)}</b>。`
      + `這一頁關著也會送。<br>`
      + (ps ? `最後一次：${ps.ok ? `<span class="ok">${esc(ps.why)}</span>` : `<b>${esc(ps.why)}</b>`}`
            + ` · ${clock(ps.at)}` : "還沒送過。")
      + `<br>這組代碼只能寫、不能讀，而且在網站上按一下就能撤銷。`;
  }

  if (!keys.length) {
    list.innerHTML = `<p class="empty">還沒擷取到東西。打開 ChatGPT 或 Claude 講一句話，回來這裡看。</p>`;
    note.textContent = "";
    return;
  }

  list.innerHTML = keys
    .map(k => ({ k, r: store[k] }))
    .sort((a, b) => (b.r.lastSeen || 0) - (a.r.lastSeen || 0))
    .map(({ k, r }) => `
      <div class="conv">
        <h2>${esc(r.title || "未命名對話")}</h2>
        <div class="meta">${SITE_NAME[r.site] || r.site} · ${(r.turns || []).length} 輪 · 最後擷取 ${clock(r.lastSeen || r.firstSeen)}${
          !r.owner ? " · 未指定歸屬"
          : (store.owner && r.owner === store.owner.id ? "" : " · 屬於其他使用者")}</div>
        <div class="row">
          ${!r.owner && store.owner
            ? `<button class="primary" data-claim="${esc(k)}">認領為我的</button>` : ""}
          <button data-copy="${esc(k)}">複製 JSON</button>
          <button data-save="${esc(k)}">下載 JSON</button>
          <button data-del="${esc(k)}">刪除</button>
        </div>
      </div>`).join("");

  note.textContent = ep
    ? "會自己送進判斷紀錄。下面的匯出是備份用的。"
    : "複製後到判斷紀錄網站按「從外掛匯入」。";
}

/* 把診斷結果排成看得懂的樣子 */
function fmtDiag(r) {
  if (r.error) return "檢查時出錯：" + r.error;
  const line = x => `  ${x.n < 0 ? "選擇器壞了" : x.n + " 個"}  ${x.sel}`;
  const L = [];
  L.push(`站台：${SITE_NAME[r.site] || r.site}`);
  L.push("");
  L.push("你的訊息，各組選擇器找到幾個：");
  r.user.forEach(x => L.push(line(x)));
  L.push(`  → 實際用的是：${r.used.user || "一組都沒中"}`);
  L.push("");
  L.push("AI 回覆，各組選擇器找到幾個：");
  r.ai.forEach(x => L.push(line(x)));
  L.push(`  → 實際用的是：${r.used.ai || "一組都沒中"}`);
  L.push("");
  L.push(`配對成 ${r.turns} 輪。畫面上讀到 ${r.seen.length} 則訊息：`);
  r.seen.forEach((m, i) => L.push(
    `  ${String(i + 1).padStart(2, "0")} ${m.role === "user" ? "你 " : "AI"} ${m.len} 字`
    + (m.twice ? "  ⚠ 同一句被收了兩次" : "") + `\n     ${m.head}`));
  if (!r.seen.length) L.push("  （什麼都沒讀到——選擇器要改了）");
  return L.join("\n");
}

/* 匯出成判斷紀錄那一頁吃得下的格式 */
function toLog(rec) {
  return {
    title: rec.title || "未命名對話",
    course: "",
    semester: "",
    scope: "self",   // 預設自主研究；要給老師看的再到頁面上改成課程作業
    source: `${SITE_NAME[rec.site] || rec.site} · Chrome 外掛於對話當下擷取 · AI 回覆為原文`
      + (rec.claimedLate ? " · 歸屬為事後認領，非擷取當下" : ""),
    capturedFrom: rec.url,
    turns: (rec.turns || []).map(t => ({ t: t.t, q: t.q, a: t.a }))
  };
}

document.addEventListener("click", (e) => {
  const btn = e.target.closest("button");
  if (!btn) return;

  // 網站改版時，先按這個。它問的是「外掛在你正在看的那一頁看到什麼」。
  if (btn.id === "diag") {
    const out = document.getElementById("diagout");
    out.hidden = false;
    out.textContent = "檢查中…";
    chrome.tabs.query({ active: true, currentWindow: true }, (tabs) => {
      const id = tabs && tabs[0] && tabs[0].id;
      if (!id) { out.textContent = "找不到目前的分頁。"; return; }
      chrome.tabs.sendMessage(id, { kind: "diag" }, (r) => {
        if (chrome.runtime.lastError || !r) {
          out.textContent = "這一頁沒有擷取程式在跑。\n可能是：不是 ChatGPT／Claude／Gemini，"
            + "或外掛剛重新載入過而這個分頁還沒重新整理（按 F5 就好）。";
          return;
        }
        out.textContent = fmtDiag(r);
      });
    });
    return;
  }

  if (btn.id === "clear") {
    if (!confirm("全部清除？這些紀錄刪掉就沒有了。")) return;
    chrome.storage.local.clear(() => load());
    return;
  }

  // 公用電腦用完按這個：下一個人的對話不會記到你頭上
  // 代碼也一起丟掉，不然下一個人的機器上還留著你的寫入權
  if (btn.id === "clearowner") {
    chrome.storage.local.remove(["owner", "endpoint", "push"], () => load());
    return;
  }

  // 手動輸入匯入代碼。
  // 這樣外掛就不必知道網站住在哪個網址——搬家、換網域、別人自己架一份，
  // 都不用改外掛。網站的 Supabase 專案位置是公開資訊，寫死在外掛裡沒問題；
  // anon key 本來就設計成要出現在每個人的瀏覽器裡，真正的防線是資料庫的 RLS。
  if (btn.id === "setcode") {
    const el = document.getElementById("codein");
    const code = (el.value || "").trim().toUpperCase();
    if (!/^JL-[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}$/.test(code)) {
      el.style.borderColor = "#B06A16";
      el.value = "";
      el.placeholder = "格式應該像 JL-FD12-1091-8D2D";
      return;
    }
    // owner 留空：手動輸入時外掛不知道你是誰，
    // 所以這台電腦上擷取到的都會送給這組代碼的主人。
    // 公用電腦請改用網站上的按鈕發碼，那條路會帶著歸屬進來。
    chrome.storage.local.set({
      endpoint: { url: SUPABASE_URL, key: SUPABASE_ANON_KEY, code, owner: null, manual: true }
    }, () => {
      try { chrome.runtime.sendMessage({ kind: "push" }); } catch (e) {}
      load();
    });
    return;
  }

  if (btn.id === "clearcode") {
    if (!confirm("從這台電腦移除匯入代碼？擷取照常，只是要判斷紀錄那一頁開著才送得上去。\n"
      + "（這只是移除本機這一份。要讓代碼整組失效，請到網站上按撤銷。）")) return;
    chrome.storage.local.remove(["endpoint", "push"], () => load());
    return;
  }

  const k = btn.dataset.copy || btn.dataset.save || btn.dataset.del || btn.dataset.claim;
  if (!k || !store[k]) return;

  // 認領：把登入前擷取的對話指給目前使用者。
  // 但這件事會留痕——紀錄上會標成「事後認領」，跟當下擷取的分得開。
  if (btn.dataset.claim) {
    if (!store.owner) return;
    const rec = { ...store[k], owner: store.owner.id, claimedLate: Date.now() };
    chrome.storage.local.set({ [k]: rec }, () => load());
    return;
  }

  if (btn.dataset.del) {
    const index = (store.index || []).filter(x => x !== k);
    chrome.storage.local.remove(k, () =>
      chrome.storage.local.set({ index }, () => load()));
    return;
  }

  const json = JSON.stringify(toLog(store[k]), null, 2);

  if (btn.dataset.copy) {
    navigator.clipboard.writeText(json).then(() => {
      btn.textContent = "已複製";
      setTimeout(() => { btn.textContent = "複製 JSON"; }, 1600);
    });
    return;
  }

  const url = URL.createObjectURL(new Blob([json], { type: "application/json" }));
  const a = document.createElement("a");
  a.href = url;
  a.download = (store[k].title || "judgment-log").replace(/[\\/:*?"<>|]/g, "_") + ".json";
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 3000);
});
