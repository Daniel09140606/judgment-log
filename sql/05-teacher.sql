-- =========================================================
-- 判斷紀錄 · 老師端
-- 在 Supabase → SQL Editor 貼上整段執行一次。可重複執行。
--
-- 老師端的資料規則在第一份 schema.sql 就寫好了：
--   老師只讀得到「掛在自己課底下」而且「學生標成課程作業」的紀錄，
--   而且展開原文會被記次數、學生看得到。
-- 這一份只補兩件缺的：
--   1. 開課（原本要手動去 Supabase 塞一列）
--   2. 一個讓老師確認「這門課我到底看得到什麼」的自我檢查函式
-- =========================================================

-- ---------- 開一門課 ----------
-- 課程代碼由資料庫產生，不讓前端指定——不然有人可以挑一組別人已經發出去的碼。
drop function if exists public.create_course(text, text);
create function public.create_course(_name text, _semester text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare c text; cid uuid; tries int := 0;
begin
  if auth.uid() is null then raise exception '請先登入'; end if;
  if coalesce(trim(_name), '') = '' then raise exception '課程名稱不能空白'; end if;

  -- 一個人最多 20 門課，免得被灌爆
  if (select count(*) from courses where teacher = auth.uid()) >= 20 then
    raise exception '一個帳號最多開 20 門課';
  end if;

  loop
    tries := tries + 1;
    -- 十六進位只有 0-9 A-F，不會有 O 跟 0、I 跟 1 抄錯的問題
    c := substr(upper(replace(gen_random_uuid()::text, '-', '')), 1, 6);
    begin
      insert into courses(teacher, name, semester, join_code)
      values (auth.uid(), trim(_name), coalesce(trim(_semester), ''), c)
      returning id into cid;
      exit;
    exception when unique_violation then
      if tries > 8 then raise exception '產生課程代碼失敗，請再試一次'; end if;
    end;
  end loop;

  return jsonb_build_object('id', cid, 'join_code', c, 'name', trim(_name));
end $$;

revoke all on function public.create_course(text, text) from public;
grant execute on function public.create_course(text, text) to authenticated;

-- ---------- 這門課我看得到什麼 ----------
-- 給老師自己看的透明度工具：班上有幾個人、幾個人交了、
-- 以及有多少份紀錄是學生標成「自主研究」而你看不到的。
--
-- 最後那個數字是故意給的。老師應該知道「有東西是我看不到的」，
-- 而不是以為自己看到了全部——後者才會讓人誤判。
-- 它只回數量，不回任何內容。
create or replace function public.course_overview(_course uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  if not public.is_teacher_of(_course) then raise exception '這不是你的課'; end if;

  select jsonb_build_object(
    'students',  (select count(*) from enrollments where course_id = _course),
    'visible',   (select count(*) from logs
                   where course_id = _course and scope = 'course' and deleted_at is null),
    'hidden',    (select count(*) from logs
                   where course_id = _course and scope <> 'course' and deleted_at is null),
    'submitters',(select count(distinct owner) from logs
                   where course_id = _course and scope = 'course' and deleted_at is null)
  ) into r;
  return r;
end $$;

revoke all on function public.course_overview(uuid) from public;
grant execute on function public.course_overview(uuid) to authenticated;

-- ---------- 檢查 ----------
-- 開一門課：select public.create_course('財報分析','114-1');
-- 看得到什麼：select public.course_overview('剛剛回傳的 id');
