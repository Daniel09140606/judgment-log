-- =========================================================
-- 判斷紀錄 · 說明可以改，但改了會留下痕跡
-- 在 Supabase → SQL Editor 貼上整段執行一次。可重複執行。
--
-- 三件事：
--
-- 1. 被標記時補的那一句，從「只能寫一次」改成「可以改」。
--    人會想到更好的說法，鎖死只會逼人隨便寫一句交差。
--
-- 2. 但改了要看得出來：改過幾次、第一次是什麼時候、最後一次是什麼時候。
--    這三個數字由資料庫自己算，前端送什麼都不算數——
--    不然「改過 3 次」這個資訊就跟沒有一樣。
--
-- 3. 順便把一個洞補起來：原本學生可以透過 API 改掉自己的 q 與 a。
--    畫面上沒有這個按鈕，但「畫面上沒有」不等於「做不到」。
--    這套系統的整個前提是「原文與時間寫進去就改不了」，
--    那它就必須是資料庫擋的，不是介面沒做。
-- =========================================================

alter table public.turns add column if not exists why_first_at timestamptz;
alter table public.turns add column if not exists why_edits    int not null default 0;

create or replace function public.guard_turn_update()
returns trigger language plpgsql set search_path = public as $$
begin
  -- ---------- 原文與時間，任何人都不能改 ----------
  -- 包括紀錄的擁有者本人。這一條是整套系統的地基。
  if new.q is distinct from old.q
     or new.a is distinct from old.a
     or new.captured_at is distinct from old.captured_at
     or new.fingerprint is distinct from old.fingerprint then
    raise exception '對話原文與擷取時間寫入後不可修改';
  end if;

  -- ---------- 補充說明：可以改，但痕跡由資料庫決定 ----------
  if new.why is distinct from old.why then
    new.why_at := now();
    if old.why is null or btrim(old.why) = '' then
      new.why_first_at := now();          -- 第一次寫
      new.why_edits    := 0;
    else
      new.why_first_at := old.why_first_at;
      new.why_edits    := coalesce(old.why_edits, 0) + 1;
    end if;
  else
    -- 沒動到內容就不准動這三個欄位，免得有人把次數歸零
    new.why_at       := old.why_at;
    new.why_first_at := old.why_first_at;
    new.why_edits    := old.why_edits;
  end if;

  return new;
end $$;

drop trigger if exists turns_guard on public.turns;
create trigger turns_guard
  before update on public.turns
  for each row execute function public.guard_turn_update();

-- 既有資料補上第一次時間，免得舊的那幾段看起來像從沒寫過
update public.turns
   set why_first_at = why_at
 where why is not null and btrim(why) <> '' and why_first_at is null;

-- ---------- 檢查 ----------
-- 試著改原文，應該會被擋下來：
--   update public.turns set q = '改改看' where id = '任一段的 id';
--   → ERROR:  對話原文與擷取時間寫入後不可修改
