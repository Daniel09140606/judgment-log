-- =========================================================
-- 判斷紀錄 · 同一輪只記一筆（外掛優先）
-- 在 Supabase → SQL Editor 貼上整段執行一次。可重複執行。
--
-- 要解決的事：同一場對話有兩個寫入者。
--   Chrome 外掛 —— 用「對話網址」認這是哪一場，寫的是完整原文。
--   Cowork 同步技能 —— 用「專案名」認，寫的是節錄。
--   兩邊互相不知道對方存在，於是同一輪被記進兩個地方。
--   外掛自己重送（水位被調回、重新載入）時也會再寫一次。
--
-- 怎麼認出「這是同一輪」：
--   看問句，不看回答。
--   兩個寫入者讀的是你同一句話，所以 q 幾乎一樣；
--   a 一個是全文、一個是節錄，本來就不同 —— 拿 a 比對永遠比不出來。
--   （原本的指紋是「問句＋回答」，這就是它擋不住的原因。）
--
-- 為什麼不做「內容相似度」：
--   「相似」會把兩句真的不同的話判成同一句，而被判掉的那句會安靜消失。
--   一個會讓原文安靜消失的系統，拿去當證據就沒有價值了。
--   所以這裡只認「同一個問句」，不認「意思差不多」。
-- =========================================================

-- ---------- 比對用的正規化 ----------
-- 空白全部拿掉（兩個寫入者的換行與空格不一致）、
-- 拿掉同步技能加在截圖前面的「（截圖）」、統一逗號。
create or replace function public.jl_qkey(_q text)
returns text language sql immutable set search_path = public as $$
  select md5(
    regexp_replace(
      regexp_replace(
        regexp_replace(coalesce(_q, ''), '^\s*（截圖）\s*', ''),
      '\s+', '', 'g'),
    '[,，]', '', 'g')
  );
$$;

-- ---------- 被擋下來的都留下來，不是消失 ----------
create table if not exists public.turn_skips (
  id         uuid primary key default gen_random_uuid(),
  owner      uuid not null references auth.users(id) on delete cascade,
  log_id     uuid,
  kept_turn  uuid,                -- 已經在裡面的那一筆
  q          text,
  a          text,                -- 被擋下來的這一版回答，原封不動留著
  captured_at timestamptz,
  reason     text,                -- 'resend' 或 'two-writers'
  at         timestamptz not null default now()
);
alter table public.turn_skips enable row level security;
drop policy if exists turn_skips_own on public.turn_skips;
create policy turn_skips_own on public.turn_skips
  for select using (owner = auth.uid());

create index if not exists turns_owner_qkey_idx
  on public.turns (owner, public.jl_qkey(q), captured_at);

-- ---------- 進來之前先問：這一輪是不是已經有了 ----------
create or replace function public.guard_turn_insert()
returns trigger language plpgsql set search_path = public as $$
declare
  k     text := public.jl_qkey(new.q);
  qlen  int  := length(regexp_replace(coalesce(new.q, ''), '\s+', '', 'g'));
  hit   public.turns%rowtype;
  why   text;
begin
  -- 規則一：同一個人、同一個問句、同一個擷取時間 → 這是重送。
  -- 零誤判：真的問兩次不可能落在同一秒。
  select * into hit from public.turns
   where owner = new.owner
     and public.jl_qkey(q) = k
     and captured_at = new.captured_at
   limit 1;
  if found then why := 'resend'; end if;

  -- 規則二：同一個人、同一個問句、15 分鐘內 → 兩個寫入者記了同一輪。
  -- 只套用在 12 字以上的問句：
  -- 「好了」「同意」「繼續」這種短句，同一段時間裡真的會講很多次，
  -- 那些交給規則一就好，不要讓規則二去猜。
  if why is null and qlen >= 12 then
    select * into hit from public.turns
     where owner = new.owner
       and public.jl_qkey(q) = k
       and captured_at between new.captured_at - interval '15 minutes'
                           and new.captured_at + interval '15 minutes'
     limit 1;
    if found then why := 'two-writers'; end if;
  end if;

  if why is null then return new; end if;

  -- 擋下來的那一版完整留著，之後查得到，不是不見了
  insert into public.turn_skips(owner, log_id, kept_turn, q, a, captured_at, reason)
  values (new.owner, new.log_id, hit.id, new.q, new.a, new.captured_at, why);

  return null;   -- 不寫進 turns
end $$;

drop trigger if exists turns_guard_insert on public.turns;
create trigger turns_guard_insert
  before insert on public.turns
  for each row execute function public.guard_turn_insert();

-- ---------- 外掛優先 ----------
-- 上面是「先到先留」。要讓外掛的全文贏過技能的節錄，
-- 做法不是讓資料庫去刪已經寫進去的東西（那等於系統可以竄改紀錄），
-- 而是讓同步技能晚一點寫：外掛擷取後 30 秒內就會送出，
-- 技能等兩分鐘再送，那時候規則二就會把技能這一版擋掉。
-- 真正沒被外掛看到的對話（桌面版 Cowork 沒開 claude.ai 分頁），
-- 規則二找不到對應的那一筆，技能就會正常寫進去。

-- ---------- 檢查 ----------
--   select reason, count(*) from turn_skips group by reason;
--   select q, reason, at from turn_skips order by at desc limit 20;
--
-- 想把某一筆被擋掉的放回去：自己看過 turn_skips 那一列再決定，
-- 不要寫成自動的。
