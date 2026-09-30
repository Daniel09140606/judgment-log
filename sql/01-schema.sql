-- =========================================================
-- 判斷紀錄 · 資料庫骨架
-- 在 Supabase → SQL Editor 貼上整段執行一次就好。可重複執行。
--
-- 設計原則：權限判定在資料庫裡，不在畫面上。
-- 前端就算被改掉，也拿不到別人的資料——因為查詢在資料庫這一層就被擋掉了。
-- =========================================================

-- ---------- 資料表 ----------

create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default '',
  created_at   timestamptz not null default now()
);

create table if not exists public.courses (
  id         uuid primary key default gen_random_uuid(),
  teacher    uuid not null references auth.users(id) on delete cascade,
  name       text not null,
  semester   text not null default '',
  join_code  text not null unique,          -- 學生用這組代碼加入
  created_at timestamptz not null default now()
);

create table if not exists public.enrollments (
  course_id uuid not null references public.courses(id) on delete cascade,
  student   uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (course_id, student)
);

-- 一份紀錄 = 一個對話／一份作業
create table if not exists public.logs (
  id            uuid primary key default gen_random_uuid(),
  owner         uuid not null references auth.users(id) on delete cascade,
  course_id     uuid references public.courses(id) on delete set null,
  title         text not null default '未命名對話',
  source        text not null default '',
  captured_from text,                        -- 外掛擷取的來源網址，用來認出同一個對話
  scope         text not null default 'self' check (scope in ('self','course')),
  scope_log     jsonb not null default '[]'::jsonb,   -- 分類異動留痕
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- 一輪往返。原文與時間寫進來之後就不該再改。
create table if not exists public.turns (
  id          uuid primary key default gen_random_uuid(),
  log_id      uuid not null references public.logs(id) on delete cascade,
  owner       uuid not null references auth.users(id) on delete cascade,
  fingerprint text not null,                 -- 內容指紋，同一輪不會重複進來
  captured_at timestamptz not null,          -- 擷取當下的時間
  q           text not null default '',
  a           text not null default '',
  produced    text not null default '',
  ai          jsonb,                         -- {verdict, reasoned, basis, judged_at}
  why         text,                          -- 被標記時學生補的那一句
  why_at      timestamptz,
  opens       int not null default 0,        -- 老師展開原文的次數
  last_open   timestamptz,
  created_at  timestamptz not null default now()
);

create index if not exists logs_owner_idx    on public.logs(owner);
create index if not exists logs_course_idx   on public.logs(course_id);
create index if not exists turns_log_idx     on public.turns(log_id);
create unique index if not exists turns_dedupe_idx on public.turns(log_id, fingerprint);

-- ---------- 輔助函式 ----------
-- 用 security definer 繞過巢狀 RLS 遞迴；這些函式只回傳 true/false，不外洩內容。

create or replace function public.is_teacher_of(_course uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from courses where id = _course and teacher = auth.uid());
$$;

create or replace function public.is_my_classmate_teacher(_student uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from enrollments e join courses c on c.id = e.course_id
    where e.student = _student and c.teacher = auth.uid()
  );
$$;

create or replace function public.is_enrolled(_course uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from enrollments where course_id = _course and student = auth.uid());
$$;

-- 老師展開原文：把這件事記在紀錄上。學生看得到誰展開過幾次。
create or replace function public.record_open(_turn uuid)
returns void language plpgsql security definer set search_path = public as $$
declare ok boolean;
begin
  select exists (
    select 1 from turns t
      join logs l    on l.id = t.log_id
      join courses c on c.id = l.course_id
    where t.id = _turn and l.scope = 'course' and c.teacher = auth.uid()
  ) into ok;
  if not ok then raise exception '沒有權限展開這一段'; end if;
  update turns set opens = opens + 1, last_open = now() where id = _turn;
end; $$;

-- 用邀請碼加入課程
create or replace function public.join_course(_code text)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid;
begin
  select id into cid from courses where join_code = upper(trim(_code));
  if cid is null then raise exception '找不到這組課程代碼'; end if;
  insert into enrollments(course_id, student) values (cid, auth.uid())
    on conflict do nothing;
  return cid;
end; $$;

-- 註冊時自動建 profile
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id, display_name)
  values (new.id, coalesce(nullif(new.raw_user_meta_data->>'display_name',''),
                           split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- 開啟列級安全 ----------

alter table public.profiles    enable row level security;
alter table public.courses     enable row level security;
alter table public.enrollments enable row level security;
alter table public.logs        enable row level security;
alter table public.turns       enable row level security;

-- profiles：自己全權；老師讀得到自己課裡學生的名字
drop policy if exists profiles_self on public.profiles;
create policy profiles_self on public.profiles
  for all using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists profiles_teacher_read on public.profiles;
create policy profiles_teacher_read on public.profiles
  for select using (public.is_my_classmate_teacher(id));

-- courses：老師擁有自己的課；修課學生讀得到
drop policy if exists courses_owner on public.courses;
create policy courses_owner on public.courses
  for all using (teacher = auth.uid()) with check (teacher = auth.uid());

drop policy if exists courses_student_read on public.courses;
create policy courses_student_read on public.courses
  for select using (public.is_enrolled(id));

-- enrollments：學生管自己的；老師讀得到自己課的名單
drop policy if exists enroll_self on public.enrollments;
create policy enroll_self on public.enrollments
  for all using (student = auth.uid()) with check (student = auth.uid());

drop policy if exists enroll_teacher_read on public.enrollments;
create policy enroll_teacher_read on public.enrollments
  for select using (public.is_teacher_of(course_id));

-- logs：擁有者全權。老師「只讀」，而且只限自己課底下、分類為課程作業的那些。
-- 學生標成自主研究的紀錄，老師在資料庫這一層就查不到。
drop policy if exists logs_owner on public.logs;
create policy logs_owner on public.logs
  for all using (owner = auth.uid()) with check (owner = auth.uid());

drop policy if exists logs_teacher_read on public.logs;
create policy logs_teacher_read on public.logs
  for select using (
    scope = 'course' and course_id is not null and public.is_teacher_of(course_id)
  );

-- turns：跟著所屬的 log 走
drop policy if exists turns_owner on public.turns;
create policy turns_owner on public.turns
  for all using (owner = auth.uid()) with check (owner = auth.uid());

drop policy if exists turns_teacher_read on public.turns;
create policy turns_teacher_read on public.turns
  for select using (
    exists (
      select 1 from public.logs l
      where l.id = turns.log_id
        and l.scope = 'course'
        and l.course_id is not null
        and public.is_teacher_of(l.course_id)
    )
  );

-- ---------- 檢查 ----------
-- 跑完之後，Table Editor 裡五張表都該顯示 "RLS enabled"。
-- 想驗證隔離：開兩個瀏覽器各註冊一個帳號，A 建立紀錄，B 應該完全看不到。
--
-- 這份跑完之後，再跑一次 schema-import-code.sql，
-- 那份是「匯入代碼」：讓外掛在網站關著的時候也能把資料送進來。
