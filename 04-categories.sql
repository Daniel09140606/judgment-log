-- =========================================================
-- 判斷紀錄 · 分類 與 垃圾桶
-- 在 Supabase → SQL Editor 貼上整段執行一次。可重複執行。
--
-- 兩件事，一個原則：
--
--   分類  = 這份紀錄「屬於哪裡」。屬於哪裡你說了算。
--   垃圾桶 = 這份紀錄「還在不在」。存不存在不完全你說了算。
--
-- 所以：
--   * 刪掉一個分類，裡面的紀錄留著，只是變回未分類。
--     分類是資料夾標籤，刪資料夾不該連內容一起燒掉。
--   * 掛在課程底下、老師看得到的紀錄，不能直接丟垃圾桶。
--     要丟，得先自己把它改回「自主研究」——而那個改動會留在 scope_log 裡，
--     老師看得到「這份曾經在課程底下，某時被移走」。
--     你還是有主導權，但拿掉的動作本身是公開的。
--   * 丟進垃圾桶不是消失，是 14 天的緩衝。14 天後才真的刪掉。
--
-- 這條「課程紀錄不能直接刪」是寫成資料庫的觸發器，不是畫面上的判斷。
-- 畫面可以被改，觸發器不行。
-- =========================================================

-- ---------- 分類 ----------

create table if not exists public.categories (
  id         uuid primary key default gen_random_uuid(),
  owner      uuid not null references auth.users(id) on delete cascade,
  name       text not null,
  sort       int not null default 0,
  created_at timestamptz not null default now()
);

-- 同一個人不能有兩個同名分類（大小寫視為同一個）
create unique index if not exists categories_owner_name_idx
  on public.categories(owner, lower(name));

alter table public.categories enable row level security;

drop policy if exists categories_owner on public.categories;
create policy categories_owner on public.categories
  for all using (owner = auth.uid()) with check (owner = auth.uid());

-- on delete set null：刪分類，紀錄留著，變回未分類
alter table public.logs
  add column if not exists category_id uuid references public.categories(id) on delete set null;

-- ---------- 垃圾桶 ----------

alter table public.logs
  add column if not exists deleted_at timestamptz;

create index if not exists logs_trash_idx on public.logs(owner, deleted_at);

-- 掛在課程底下的紀錄，不准直接丟垃圾桶；也不准把垃圾桶裡的東西掛回課程。
create or replace function public.guard_trash()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.deleted_at is not null and old.deleted_at is null and new.scope = 'course' then
    raise exception '這份紀錄掛在課程底下，老師看得到，不能直接丟掉。請先改回「自主研究」——那個改動會留在紀錄上。';
  end if;
  if new.scope = 'course' and new.deleted_at is not null then
    raise exception '垃圾桶裡的紀錄不能掛回課程。請先還原。';
  end if;
  return new;
end $$;

drop trigger if exists logs_guard_trash on public.logs;
create trigger logs_guard_trash
  before update on public.logs
  for each row execute function public.guard_trash();

-- 老師端看不到垃圾桶裡的東西（雖然上面已經擋住課程紀錄進垃圾桶，這裡再保一層）
drop policy if exists logs_teacher_read on public.logs;
create policy logs_teacher_read on public.logs
  for select using (
    scope = 'course' and course_id is not null
    and deleted_at is null
    and public.is_teacher_of(course_id)
  );

drop policy if exists turns_teacher_read on public.turns;
create policy turns_teacher_read on public.turns
  for select using (
    exists (
      select 1 from public.logs l
      where l.id = turns.log_id
        and l.scope = 'course'
        and l.course_id is not null
        and l.deleted_at is null
        and public.is_teacher_of(l.course_id)
    )
  );

-- 超過 14 天的，真的刪掉。網站每次載入會呼叫一次，不需要排程服務。
create or replace function public.purge_trash()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is null then return 0; end if;
  delete from logs
   where owner = auth.uid()
     and deleted_at is not null
     and deleted_at < now() - interval '14 days';
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.purge_trash() from public;
grant execute on function public.purge_trash() to authenticated;

-- ---------- 註記 ----------
-- 丟進垃圾桶之後，外掛如果還在送那個對話，新的段落照樣會寫進去，
-- 但那份紀錄不會因此自己跑回列表上——你按過的刪除不會被系統推翻。
-- 還原的時候，那段期間的內容也都在。
