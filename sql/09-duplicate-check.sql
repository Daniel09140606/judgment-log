-- =========================================================
-- 判斷紀錄 · 重複紀錄的「看得見」，不是「自動消失」
-- 在 Supabase → SQL Editor 貼上整段執行一次。可重複執行。
--
-- 2026-09-30 發生的事：
--   Chrome 外掛在 claude.ai 上把介面的狀態字（「3 minutes ago」、
--   「Running page script」、「2m 51s」）當成 AI 的回答收了進來。
--   這些字每幾秒換一次，而當時判斷「這輪存過了沒」的指紋是「問句＋回答」，
--   回答一變就被當成新的一輪 —— 同一個問題被記了 42 次。
--   241 段紀錄裡有 71 段是這樣來的，將近三成。
--
-- 真正的修法在外掛（v0.6.0）：認問句不認回答、擋掉介面狀態字、
-- 送出前先扣 30 秒等回答講完。源頭堵住了，就不會再生出重複。
--
-- 那資料庫這一層要不要也加一道「同一個對話裡同一個問句只准一筆」？
--   不要。
--   因為「同意」「繼續」「好」這種話，同一個對話裡本來就會講很多次。
--   加了唯一索引，那些真的講過兩次的話會被資料庫默默吃掉一次 ——
--   一個會讓原文安靜消失的系統，拿去當證據是沒有價值的。
--
--   所以這裡做的是「查得出來」，不是「自動刪掉」。
--   刪不刪、刪哪一筆，是使用者看過之後自己決定的事。
-- =========================================================

create or replace function public.jl_duplicates()
returns table (
  log_id     uuid,
  log_title  text,
  q_head     text,
  copies     bigint,
  first_seen timestamptz,
  last_seen  timestamptz,
  a_lengths  int[]
)
language sql
security invoker              -- 跟著呼叫者的 RLS 走：只查得到自己的
set search_path = public
as $$
  select
    t.log_id,
    l.title,
    -- 分組是用前 300 字，顯示只要前 40 字。
    -- 這裡一定要用聚合函式包起來：顯示的表達式跟 group by 的表達式不一樣，
    -- 直接寫 left(t.q, 40) 會被 PostgreSQL 擋下來（must appear in the GROUP BY clause）。
    -- 2026-10-03 把 01～11 依序裝一次才發現這支從頭到尾沒跑起來過。
    min(left(regexp_replace(t.q, '\s+', ' ', 'g'), 40)),
    count(*),
    min(t.captured_at),
    max(t.captured_at),
    array_agg(length(coalesce(t.a, '')) order by length(coalesce(t.a, '')))
  from public.turns t
  join public.logs  l on l.id = t.log_id
  group by t.log_id, l.title, left(regexp_replace(t.q, '\s+', ' ', 'g'), 300)
  having count(*) > 1
  order by count(*) desc, min(t.captured_at);
$$;

-- ---------- 怎麼用 ----------
--   select * from jl_duplicates();
--
-- 看 a_lengths 就知道是哪一種重複：
--   {13,13,48,76,527}  → 介面狀態字被當成回答（外掛 v0.6.0 之後不會再有）
--   {829,829}          → 同一段被送了兩次
--   {261,254}          → 真的問了兩次類似的話，多半該留著
--
-- 要刪的話，自己挑 id，一筆一筆確認過再刪。不要寫成自動的。
