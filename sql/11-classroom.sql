-- =========================================================
-- 判斷紀錄 · Classroom：老師看得到判斷，看不到原文
-- 在 Supabase → SQL Editor 貼上整段執行一次。可重複執行。
--
-- ⚠ 這一支會改變老師端的行為，而且網站必須同時更新到對應的版本。
--   跑完之後，老師直接查 turns 會查不到任何東西——這是故意的。
--
-- 要守住的那句話：
--   「老師看到的是你交出來的判斷，不是你的對話。」
--
-- 分兩層：
--   紀錄層（logs.scope = 'course'）：老師看得到這份紀錄存在，
--     看得到判斷分布、時間分布、以及學生自己寫的「為什麼」。
--   單輪層（turns.shared）：原文預設不給看。
--     學生要一輪一輪按「給老師看」，老師才讀得到 q 與 a。
--
-- 關鍵在下面那段 drop policy。原本 turns_teacher_read 讓老師
-- 直接 select turns 就拿得到 q 和 a——那道門不關，視圖只是裝飾。
-- 「畫面上沒有」不等於「做不到」，這套系統的前提是後者。
-- =========================================================

-- ---------- 單輪開放 ----------
alter table public.turns
  add column if not exists shared boolean not null default false;

create index if not exists turns_shared_idx on public.turns(log_id) where shared;

-- 開放與收回都留痕。學生可以收回（歸屬是他的），但收回這件事看得見。
create table if not exists public.share_log (
  id       uuid primary key default gen_random_uuid(),
  turn_id  uuid not null references public.turns(id) on delete cascade,
  owner    uuid not null references auth.users(id)  on delete cascade,
  shared   boolean not null,
  at       timestamptz not null default now()
);
alter table public.share_log enable row level security;
drop policy if exists share_log_own on public.share_log;
create policy share_log_own on public.share_log
  for select using (owner = auth.uid());

-- 這個觸發器必須是 security definer。
-- share_log 刻意沒有給使用者 INSERT 政策——留痕只能由系統寫，不能由人寫，
-- 不然「開放紀錄」這件事本身就可以被偽造。
-- 但那也代表學生自己按收回時，觸發器會被 RLS 擋下來、連帶整個更新被回滾。
-- 2026-10-03 測出來的：第一次開放走 answer_request（definer）會成功，
-- 學生自己按收回就炸，而且是靜默地什麼都沒發生。
create or replace function public.log_share_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.shared is distinct from old.shared then
    insert into public.share_log(turn_id, owner, shared)
    values (new.id, new.owner, new.shared);
  end if;
  return new;
end $$;

drop trigger if exists turns_share_log on public.turns;
create trigger turns_share_log
  after update on public.turns
  for each row execute function public.log_share_change();

-- ---------- 把老師直接讀 turns 的那道門關掉 ----------
-- 這是整支 SQL 最重要的一行。
-- 關掉之後老師唯一的路是下面的 course_turns 視圖，而那個視圖
-- 在未開放時回傳 null，不是回傳空字串、也不是前端不顯示。
drop policy if exists turns_teacher_read on public.turns;

-- ---------- 老師看到的那一層 ----------
-- security definer 視圖：自己檢查權限，不靠呼叫者的 RLS，
-- 所以授權邏輯寫在 where 裡面，要寫得讓人一眼看懂。
drop view if exists public.course_turns;
create view public.course_turns
with (security_invoker = false) as
select
  t.id,
  t.log_id,
  t.owner,
  t.captured_at,
  t.ai,                                    -- 判定（jsonb，裡面有 verdict / basis）
  t.why,                                   -- 學生自己寫的那一句，老師看得到
  t.why_edits,
  t.why_first_at,
  t.why_at,
  t.opens,
  t.shared,
  length(coalesce(t.q, '')) as q_len,      -- 有多長看得到，內容看不到
  length(coalesce(t.a, '')) as a_len,
  case when t.shared or t.owner = auth.uid() then t.q end as q,
  case when t.shared or t.owner = auth.uid() then t.a end as a
from public.turns t
join public.logs l on l.id = t.log_id
where l.deleted_at is null
  and (
    t.owner = auth.uid()                   -- 自己的，全部看得到
    or (                                   -- 或：你是這門課的老師，而他交了這份
      l.scope = 'course'
      and l.course_id is not null
      and exists (select 1 from public.courses c
                   where c.id = l.course_id and c.teacher = auth.uid())
      and exists (select 1 from public.enrollments e
                   where e.course_id = l.course_id and e.student = t.owner)
    )
  );

grant select on public.course_turns to authenticated;

-- ---------- 老師請求查看某一輪 ----------
-- 老師看不到原文，但看得到「這一輪照單全收，而且他寫了這句話」。
-- 想看內容就按一下請求，由學生決定給不給。不給也可以，而且不給這件事留痕。
-- 這一來一往就是「對話」跟「監控」的差別。
create table if not exists public.view_requests (
  id         uuid primary key default gen_random_uuid(),
  turn_id    uuid not null references public.turns(id) on delete cascade,
  course_id  uuid not null references public.courses(id) on delete cascade,
  teacher    uuid not null references auth.users(id) on delete cascade,
  student    uuid not null references auth.users(id) on delete cascade,
  note       text,                                   -- 老師想問什麼，可留空
  state      text not null default 'pending'
             check (state in ('pending','granted','declined')),
  asked_at   timestamptz not null default now(),
  answered_at timestamptz,
  unique (turn_id, teacher)
);
create index if not exists vr_student_idx on public.view_requests(student, state);
alter table public.view_requests enable row level security;

drop policy if exists vr_read on public.view_requests;
create policy vr_read on public.view_requests
  for select using (student = auth.uid() or teacher = auth.uid());

drop policy if exists vr_ask on public.view_requests;
create policy vr_ask on public.view_requests
  for insert with check (
    teacher = auth.uid()
    and exists (select 1 from public.courses c
                 where c.id = course_id and c.teacher = auth.uid())
    and exists (select 1 from public.enrollments e
                 where e.course_id = course_id and e.student = view_requests.student)
  );

-- 學生回應：只能動 state 與 answered_at，動不了是誰問的、問哪一輪。
drop policy if exists vr_answer on public.view_requests;
create policy vr_answer on public.view_requests
  for update using (student = auth.uid()) with check (student = auth.uid());

create or replace function public.guard_vr_update()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.turn_id is distinct from old.turn_id
     or new.teacher is distinct from old.teacher
     or new.student is distinct from old.student
     or new.course_id is distinct from old.course_id
     or new.asked_at is distinct from old.asked_at then
    raise exception '請求的內容不可修改，只能回應';
  end if;
  if new.state is distinct from old.state then new.answered_at := now(); end if;
  return new;
end $$;

drop trigger if exists vr_guard on public.view_requests;
create trigger vr_guard before update on public.view_requests
  for each row execute function public.guard_vr_update();

-- ---------- 班級總覽 ----------
-- 一列一個學生。老師第一眼看到的就是這個。
--
-- 刻意沒有「他總共有幾份」：那個數字會洩漏學生的私人紀錄數量，
-- 而且會讓學生覺得交多一點比較安全。原則講一次就好，不要變成每個人頭上的數字。
drop function if exists public.class_roster(uuid);
create function public.class_roster(_course uuid)
returns table (
  student        uuid,
  display_name   text,
  logs_submitted bigint,
  turns_total    bigint,
  turns_shared   bigint,
  adopt          bigint,
  pushback       bigint,
  reject         bigint,
  choose         bigint,
  unjudged       bigint,
  why_written    bigint,
  why_missing    bigint,   -- 照單全收但沒寫為什麼
  first_at       timestamptz,
  last_at        timestamptz,
  active_days    bigint,
  flags          text[]    -- 值得聊一下的理由；空的就是一切正常
)
language sql security definer set search_path = public as $$
  with guard as (
    select 1 from public.courses c where c.id = _course and c.teacher = auth.uid()
  ),
  mine as (
    select e.student from public.enrollments e
     where e.course_id = _course and exists (select 1 from guard)
  ),
  sub as (
    select l.id, l.owner from public.logs l
     where l.course_id = _course and l.scope = 'course' and l.deleted_at is null
  ),
  agg as (
    select
      m.student,
      coalesce(p.display_name, '（未命名）') as display_name,
      count(distinct s.id)                                    as logs_submitted,
      count(t.id)                                             as turns_total,
      count(*) filter (where t.shared)                        as turns_shared,
      count(*) filter (where t.ai->>'verdict' = 'adopt')      as adopt,
      count(*) filter (where t.ai->>'verdict' = 'push')       as pushback,
      count(*) filter (where t.ai->>'verdict' = 'reject')     as reject,
      count(*) filter (where t.ai->>'verdict' = 'choose')     as choose,
      count(*) filter (where t.id is not null and t.ai is null) as unjudged,
      count(*) filter (where btrim(coalesce(t.why,'')) <> '') as why_written,
      count(*) filter (where t.ai->>'verdict' = 'adopt'
                         and btrim(coalesce(t.why,'')) = '')  as why_missing,
      min(t.captured_at)                                      as first_at,
      max(t.captured_at)                                      as last_at,
      count(distinct (t.captured_at at time zone 'Asia/Taipei')::date) as active_days
    from mine m
    left join public.profiles p on p.id = m.student
    left join sub s             on s.owner = m.student
    left join public.turns t    on t.log_id = s.id
    group by m.student, p.display_name
  )
  select a.*,
    (select coalesce(array_agg(f), '{}')
       from (
         select '還沒交任何紀錄' as f where a.logs_submitted = 0
         union all
         select '照單全收 ' || round(100.0*a.adopt/nullif(a.turns_total,0)) || '%'
           where a.turns_total >= 5 and a.adopt::numeric/nullif(a.turns_total,0) >= 0.8
         union all
         select '有 ' || a.why_missing || ' 段照單全收沒寫為什麼'
           where a.why_missing >= 3
         union all
         select '只在 ' || a.active_days || ' 天之內用完'
           where a.turns_total >= 8 and a.active_days <= 2
         union all
         select a.unjudged || ' 段還沒判讀'
           where a.unjudged >= 5
       ) x) as flags
  from agg a
  order by a.last_at desc nulls last;
$$;

-- ---------- 學生加入課程：加入不等於交出 ----------
-- 01-schema.sql 裡的 join_course 回傳 uuid，這裡要改成回傳 jsonb
-- （多帶課名和「你有幾份可以交」，加入之後才跳得出勾選畫面）。
-- create or replace 改不了既有函式的回傳型別，一定要先 drop。
-- 2026-10-03 實際跑在正式資料庫上才撞到——我當初是在乾淨的測試庫上裝 11，
-- 沒有先裝 01～10，所以測不出這個衝突。
drop function if exists public.join_course(text);
create or replace function public.join_course(_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c public.courses%rowtype;
begin
  select * into c from public.courses where upper(join_code) = upper(btrim(_code));
  if not found then raise exception '找不到這個加入碼'; end if;
  if c.teacher = auth.uid() then raise exception '這是你自己開的課'; end if;

  insert into public.enrollments(course_id, student)
  values (c.id, auth.uid()) on conflict do nothing;

  -- 加入當下一份都沒交。下一步由學生自己勾。
  return jsonb_build_object('course', c.id, 'name', c.name, 'semester', c.semester,
    'available', (select count(*) from public.logs
                   where owner = auth.uid() and deleted_at is null and scope <> 'course'));
end $$;

-- 學生勾選要交出哪幾份（可以再收回，收回會留在 scope_log）
drop function if exists public.submit_logs(uuid, uuid[]);
create or replace function public.submit_logs(_course uuid, _logs uuid[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not exists (select 1 from public.enrollments
                  where course_id = _course and student = auth.uid()) then
    raise exception '你不在這門課裡';
  end if;
  update public.logs
     set course_id = _course, scope = 'course',
         scope_log = coalesce(scope_log, '[]'::jsonb) ||
           jsonb_build_object('at', now(), 'from', scope, 'to', 'course')
   where owner = auth.uid() and id = any(_logs)
     and deleted_at is null and scope is distinct from 'course';
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'submitted', n);
end $$;

-- 學生回應請求：同意＝開放那一輪的原文。
-- 做成一個函式，是因為「標記為同意」跟「真的開放」必須是同一件事——
-- 分成兩步就會出現「畫面說同意了、實際上老師還是讀不到」。
drop function if exists public.answer_request(uuid, boolean);
create or replace function public.answer_request(_id uuid, _grant boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.view_requests%rowtype;
begin
  select * into r from public.view_requests where id = _id and student = auth.uid();
  if not found then raise exception '找不到這筆請求'; end if;

  update public.view_requests
     set state = case when _grant then 'granted' else 'declined' end
   where id = _id;

  if _grant then
    update public.turns set shared = true
     where id = r.turn_id and owner = auth.uid();   -- 會觸發 share_log 留痕
  end if;

  return jsonb_build_object('ok', true, 'state',
    case when _grant then 'granted' else 'declined' end);
end $$;

grant execute on function public.answer_request(uuid, boolean) to authenticated;
grant execute on function public.class_roster(uuid)      to authenticated;
grant execute on function public.join_course(text)       to authenticated;
grant execute on function public.submit_logs(uuid, uuid[]) to authenticated;

-- ---------- 檢查 ----------
-- 以老師身分：未開放的那幾輪，q 與 a 應該是 null
--   select id, shared, q_len, q, a from course_turns where owner <> auth.uid() limit 5;
-- 以老師身分：直接查 turns 應該一列都沒有
--   select count(*) from turns where owner <> auth.uid();
-- 班級總覽
--   select display_name, logs_submitted, turns_total, flags from class_roster('課程 id');
