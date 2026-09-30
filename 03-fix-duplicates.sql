-- =========================================================
-- 判斷紀錄 · 修掉「同一個對話被開成好幾份」
-- 在 Supabase → SQL Editor 貼上整段執行一次。可重複執行。
--
-- 為什麼會這樣：
--   資料送進來有兩條路（外掛直送、網站那一頁代收）。
--   兩條路都是先問「這個對話存在嗎？不存在就開一份」。
--   幾乎同時問的時候，兩邊都得到「不存在」，於是各開一份。
--
--   原本擋重複只擋到「同一段不能有兩份」（turns 上的指紋唯一索引），
--   沒擋「同一個對話不能有兩份」。這一份把後者補上。
--
-- 原則沒變：這種事要擋在資料庫，不是靠畫面上的程式自律。
-- 畫面可以被改，資料庫的規則不行。
--
-- 這份做兩件事：
--   1. 把已經重複的合併回一份（段落不會掉，判讀結果與你補的說明會保留）
--   2. 加上唯一規則，以後不可能再重複
-- =========================================================

-- ---------- 1. 合併已經重複的 ----------

do $$
declare
  g      record;
  keeper uuid;
  dup    uuid;
  moved  int;
  total  int := 0;
  groups int := 0;
begin
  for g in
    select owner, captured_from
      from public.logs
     where captured_from is not null
     group by owner, captured_from
    having count(*) > 1
  loop
    groups := groups + 1;

    -- 留最早建立的那一份。最早的那份才是「當下」那一份。
    select id into keeper from public.logs
     where owner = g.owner and captured_from = g.captured_from
     order by created_at, id
     limit 1;

    for dup in
      select id from public.logs
       where owner = g.owner and captured_from = g.captured_from and id <> keeper
    loop
      -- (a) 重複那份如果有判讀結果或補充說明，而留下來那份沒有，先補過去。
      --     一模一樣的那一段在兩份裡都有，別讓合併把判讀弄不見。
      update public.turns k
         set ai     = coalesce(k.ai, d.ai),
             why    = coalesce(k.why, d.why),
             why_at = coalesce(k.why_at, d.why_at),
             opens  = greatest(k.opens, d.opens)
        from public.turns d
       where d.log_id = dup
         and k.log_id = keeper
         and k.fingerprint = d.fingerprint;

      -- (b) 只有重複那份才有的段落，搬過去。
      update public.turns
         set log_id = keeper
       where log_id = dup
         and not exists (
           select 1 from public.turns k
            where k.log_id = keeper and k.fingerprint = public.turns.fingerprint
         );
      get diagnostics moved = row_count;
      total := total + moved;

      -- (c) 如果你曾經把其中一份標成「課程作業」，那是你的決定，要留住。
      update public.logs l
         set scope     = 'course',
             course_id = coalesce(l.course_id, d.course_id),
             scope_log = l.scope_log || jsonb_build_object(
                           'from', l.scope, 'to', 'course',
                           'at', now(), 'note', '合併重複紀錄時沿用原本的分類')
        from public.logs d
       where l.id = keeper and d.id = dup
         and d.scope = 'course' and l.scope <> 'course';

      -- (d) 剩下的都是重複段落，連同那份空殼一起刪掉（turns 會跟著走）
      delete from public.logs where id = dup;
    end loop;
  end loop;

  raise notice '合併完成：% 組重複，搬回 % 段', groups, total;
end $$;

-- ---------- 2. 以後不可能再重複 ----------
-- 同一個人、同一個對話網址，只能有一份。
create unique index if not exists logs_owner_capturedfrom_idx
  on public.logs(owner, captured_from)
  where captured_from is not null;

-- ---------- 3. 讓寫入端遇到搶號時不要開新的，改去用既有那一份 ----------
create or replace function public.redeem_import_code(_code text, _logs jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  tk    public.import_tokens%rowtype;
  j     jsonb;
  t     jsonb;
  lid   uuid;
  cf    text;
  n     int;
  total int := 0;
begin
  select * into tk from import_tokens
   where code = upper(trim(coalesce(_code, '')))
     and revoked_at is null
     and expires_at > now();

  if tk.id is null then raise exception '這組匯入代碼不能用'; end if;
  if jsonb_typeof(_logs) <> 'array' then raise exception '格式不對，要一個陣列'; end if;
  if jsonb_array_length(_logs) > 20 then raise exception '一次最多 20 份紀錄'; end if;

  for j in select * from jsonb_array_elements(_logs) loop
    if jsonb_array_length(coalesce(j->'turns', '[]'::jsonb)) > 500 then
      raise exception '一份紀錄一次最多 500 段';
    end if;

    cf  := nullif(j->>'capturedFrom', '');
    lid := null;

    if cf is not null then
      select id into lid from logs
       where owner = tk.owner and captured_from = cf
       limit 1;
    end if;

    if lid is null then
      -- 查完到寫入之間，另一條路可能剛好也開了同一份。
      -- 撞到唯一規則就不要硬開，回頭去用人家那一份。
      begin
        insert into logs(owner, title, source, captured_from, scope)
        values (
          tk.owner,
          coalesce(nullif(j->>'title', ''), '未命名對話'),
          coalesce(nullif(j->>'source', ''), '外部工具擷取') || ' · 以匯入代碼直送',
          cf, 'self'
        )
        returning id into lid;
      exception when unique_violation then
        select id into lid from logs
         where owner = tk.owner and captured_from = cf
         limit 1;
      end;
    end if;

    if lid is null then continue; end if;

    n := 0;
    for t in select * from jsonb_array_elements(coalesce(j->'turns', '[]'::jsonb)) loop
      insert into turns(log_id, owner, fingerprint, captured_at, q, a, via_token)
      values (
        lid, tk.owner,
        coalesce(nullif(t->>'fp', ''), public.jl_fingerprint(t->>'q', t->>'a')),
        case when (t->>'t') ~ '^[0-9]+$'
             then to_timestamp((t->>'t')::bigint / 1000.0)
             else now() end,
        coalesce(t->>'q', ''), coalesce(t->>'a', ''),
        tk.id
      )
      on conflict (log_id, fingerprint) do nothing;
      if found then n := n + 1; end if;
    end loop;

    if n > 0 then update logs set updated_at = now() where id = lid; end if;
    total := total + n;
  end loop;

  update import_tokens
     set uses = uses + 1, last_used = now(), turns_written = turns_written + total
   where id = tk.id;

  return jsonb_build_object('ok', true, 'added', total);
end $$;

revoke all on function public.redeem_import_code(text, jsonb) from public;
grant execute on function public.redeem_import_code(text, jsonb) to anon, authenticated;

-- ---------- 檢查 ----------
-- 跑完之後這一句應該回 0 列：
--   select owner, captured_from, count(*) from public.logs
--    where captured_from is not null group by 1,2 having count(*) > 1;
