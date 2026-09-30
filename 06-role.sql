-- =========================================================
-- 判斷紀錄 · 身分（學生 / 老師）
-- 在 Supabase → SQL Editor 貼上整段執行一次。可重複執行。
--
-- 身分在註冊時決定，登入後就是兩個不同的產品：
--   學生看到的是自己的紀錄，沒有老師那一側的入口。
--   老師看到的是班級與追問建議，沒有學生那一側的入口。
--
-- 要講清楚的一件事：這個欄位只決定「你看到哪個畫面」，不決定「你看得到誰的資料」。
-- 勾了老師不會讓你多看到任何一個人——老師要看得到東西，
-- 必須有學生拿著你的課程代碼主動加入你的課，而且把那份紀錄標成課程作業。
-- 所以就算有人亂勾老師，他手上還是空的。
--
-- 正式上線時這裡應該接學校的帳號系統來認定老師身分。
-- 現在不做，但要知道自己沒做。
-- =========================================================

alter table public.profiles
  add column if not exists role text not null default 'student';

do $$
begin
  alter table public.profiles
    add constraint profiles_role_chk check (role in ('student', 'teacher'));
exception when duplicate_object then null;
end $$;

-- 註冊時把身分一起寫進來。沒帶就是學生。
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id, display_name, role)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data->>'display_name', ''),
             split_part(new.email, '@', 1)),
    case when new.raw_user_meta_data->>'role' = 'teacher' then 'teacher' else 'student' end
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- profiles 的政策本來就是「自己的那一列自己全權」，
-- 所以「在設定裡改身分」不用另外開函式，改自己那一列就好。
-- 改身分不會讓任何人多看到一筆資料——看得到什麼是 logs / turns 的政策在管。

-- ---------- 檢查 ----------
-- select id, display_name, role from public.profiles;
-- 舊帳號會是 student。要把自己改成老師，在網站的「設定 → 我的身分」按一下就好。
