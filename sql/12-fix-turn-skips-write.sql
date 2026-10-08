-- =========================================================
-- 判斷紀錄 · 修正：擋重複的觸發器寫不進 turn_skips，害整批匯入失敗
-- 在 Supabase → SQL Editor 貼上整段執行一次。可重複執行。
--
-- 症狀：匯入時 POST /rest/v1/turns 回 403 (Forbidden)，整批都沒進去。
--
-- 原因（10-one-turn-one-record.sql 的疏漏）：
--   turn_skips 開了 RLS，但只給了 select 政策，沒有給 insert。
--   guard_turn_insert() 又不是 security definer，所以它是「用你的身分」
--   去寫 turn_skips —— 被 RLS 擋下，丟出例外。
--
--   於是只要那一批裡有「一筆」重複，整個 INSERT 語句就整批回滾。
--   不是「重複的那筆被擋掉」，是「那一次匯入全部沒進去」。
--   而且錯誤訊息是 403，看起來像權限問題，看不出是擋重複的機制在作怪。
--
-- 這跟 11-classroom.sql 裡 log_share_change() 的問題是同一種：
--   觸發器要寫一張「使用者本人不該能直接寫」的表，就必須 security definer。
--   11 那支我有加，10 這支漏了。
--
-- 為什麼是 security definer 而不是補一條 insert 政策：
--   turn_skips 是「被擋下來的紀錄」，它的可信度來自「只有系統寫得進去」。
--   開放使用者直接 insert，等於任何人都能偽造一筆「這段被判定為重複」。
--   所以：使用者只能讀自己的，寫入只有觸發器做得到。
-- =========================================================

create or replace function public.guard_turn_insert()
returns trigger
language plpgsql
security definer                 -- ← 這一行就是修正本身
set search_path = public as $$
declare
  k     text := public.jl_qkey(new.q);
  qlen  int  := length(regexp_replace(coalesce(new.q, ''), '\s+', '', 'g'));
  hit   public.turns%rowtype;
  why   text;
begin
  -- 規則一：同一個人、同一個問句、同一個擷取時間 → 這是重送。
  select * into hit from public.turns
   where owner = new.owner
     and public.jl_qkey(q) = k
     and captured_at = new.captured_at
   limit 1;
  if found then why := 'resend'; end if;

  -- 規則二：同一個人、同一個問句、15 分鐘內 → 兩個寫入者記了同一輪。
  -- 只套用在 12 字以上的問句。
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

  insert into public.turn_skips(owner, log_id, kept_turn, q, a, captured_at, reason)
  values (new.owner, new.log_id, hit.id, new.q, new.a, new.captured_at, why);

  return null;   -- 不寫進 turns，但整批其他筆照常進去
end $$;

drop trigger if exists turns_guard_insert on public.turns;
create trigger turns_guard_insert
  before insert on public.turns
  for each row execute function public.guard_turn_insert();

-- ---------- 檢查：以 authenticated 身分跑，不要用管理員身分 ----------
-- 管理員會繞過 RLS，用管理員身分測這一題永遠會過，等於沒測。
--
--   select reason, count(*) from public.turn_skips group by reason;
--
-- 跑完之後回網站重新匯入一次，Console 不應該再出現 403。
