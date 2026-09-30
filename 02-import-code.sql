-- =========================================================
-- 判斷紀錄 · 匯入代碼（路一）
-- 在 Supabase → SQL Editor 貼上整段，執行一次。可重複執行。
--
-- 要解決的問題：
--   外部工具（Chrome 外掛、之後的手機 App）想把擷取到的對話寫進你的帳號，
--   但它不該拿到你的帳號密碼，也不該拿到任何讀取權。
--
-- 做法：你在網站上發一組短期代碼給那個工具。代碼的限制寫死在資料庫裡：
--   1. 只能寫，不能讀      —— 這個函式只回「寫進去幾段」，沒有任何查詢用途
--   2. 只能寫給你          —— 寫進去的擁有者由代碼決定，呼叫的人改不了
--   3. 會過期              —— 預設 14 天
--   4. 你隨時可以撤銷      —— 按一下就失效，不用改程式、不用換金鑰
--   5. 不能決定誰看得到    —— 代碼開出來的紀錄一律是「自主研究」。
--                            要讓老師看得到，只能你自己登入後改分類。
--
-- 第 5 條是這套系統的原則：可以決定歸屬，不可以決定存在；
-- 反過來，代碼可以讓紀錄長出來，不能決定誰看得到。
-- =========================================================

-- ---------- 代碼本體 ----------

create table if not exists public.import_tokens (
  id            uuid primary key default gen_random_uuid(),
  owner         uuid not null references auth.users(id) on delete cascade,
  code          text not null unique,
  label         text not null default '',
  created_at    timestamptz not null default now(),
  expires_at    timestamptz not null,
  revoked_at    timestamptz,
  uses          int not null default 0,          -- 被用過幾次
  turns_written int not null default 0,          -- 總共寫進幾段
  last_used     timestamptz
);

create index if not exists import_tokens_owner_idx on public.import_tokens(owner);

-- 哪些段是「用代碼直送」進來的，留痕。
-- 登入後親手匯入的、跟外部工具送進來的，事後分得開。
alter table public.turns
  add column if not exists via_token uuid references public.import_tokens(id) on delete set null;

alter table public.import_tokens enable row level security;

-- 只有本人看得到自己的代碼。
-- 這裡「只有」select 政策，沒有 insert / update / delete：
--   代碼一律由下面的函式產生，前端塞不進一組自己的；
--   用過幾次、寫進幾段這兩個數字，前端也改不掉——不然它就不能當證據。
drop policy if exists tokens_read on public.import_tokens;
create policy tokens_read on public.import_tokens
  for select using (owner = auth.uid());

drop policy if exists tokens_revoke on public.import_tokens;   -- 舊版本留下的，清掉

-- ---------- 指紋（跟瀏覽器端算法一致） ----------
-- 同一輪對話不管從哪條路進來，指紋一樣就只會留一份。
-- 外部工具會自己帶 fp 進來；沒帶的時候用這個補算。
create or replace function public.jl_fingerprint(_q text, _a text)
returns text language plpgsql immutable set search_path = public as $$
declare s text; h bigint := 0; i int;
begin
  s := left(coalesce(_q, ''), 150) || '§' || left(coalesce(_a, ''), 150);
  for i in 1..length(s) loop
    h := (h * 31 + ascii(substr(s, i, 1))) % 4294967296;
    -- 收回 32 位元有號整數，對應 JavaScript 的 |0
    if h >= 2147483648 then h := h - 4294967296;
    elsif h < -2147483648 then h := h + 4294967296;
    end if;
  end loop;
  return h::text;
end $$;

-- ---------- 發一組代碼 ----------
drop function if exists public.mint_import_code(int, text);
create function public.mint_import_code(_days int default 14, _label text default '')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  hex text; c text; d int; nid uuid; exp timestamptz;
begin
  if auth.uid() is null then raise exception '請先登入'; end if;

  d := least(greatest(coalesce(_days, 14), 1), 90);

  -- 同時最多 5 組有效代碼。逼你去撤銷用不到的，而不是散一地。
  if (select count(*) from import_tokens tk
        where tk.owner = auth.uid()
          and tk.revoked_at is null
          and tk.expires_at > now()) >= 5 then
    raise exception '有效的匯入代碼最多 5 組，先撤銷用不到的那幾組';
  end if;

  -- 代碼要猜不到，所以用 gen_random_uuid 的亂數，不用 random()。
  -- 取 12 個十六進位字元 ≈ 48 bits，硬猜不會中。
  -- 十六進位只有 0-9 A-F，不會有 O 跟 0、I 跟 1 抄錯的問題。
  hex := upper(replace(gen_random_uuid()::text, '-', ''));
  c := 'JL-' || substr(hex, 1, 4) || '-' || substr(hex, 5, 4) || '-' || substr(hex, 9, 4);

  insert into import_tokens(owner, code, label, expires_at)
  values (auth.uid(), c, coalesce(_label, ''), now() + (d || ' days')::interval)
  returning id, expires_at into nid, exp;

  return jsonb_build_object('id', nid, 'code', c, 'expires_at', exp);
end $$;

-- ---------- 撤銷 ----------
drop function if exists public.revoke_import_code(uuid);
create function public.revoke_import_code(_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update import_tokens set revoked_at = now()
   where id = _id and owner = auth.uid() and revoked_at is null;
end $$;

-- ---------- 拿代碼寫入（外部工具唯一能呼叫的東西） ----------
-- 參數只有兩個：代碼、要寫的內容。
-- 沒有「寫給誰」這個參數——擁有者從代碼查出來，呼叫的人指定不了。
drop function if exists public.redeem_import_code(text, jsonb);
create function public.redeem_import_code(_code text, _logs jsonb)
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

  -- 不分「不存在」跟「已過期」，免得拿錯誤訊息來試代碼
  if tk.id is null then raise exception '這組匯入代碼不能用'; end if;

  if jsonb_typeof(_logs) <> 'array' then raise exception '格式不對，要一個陣列'; end if;
  if jsonb_array_length(_logs) > 20 then raise exception '一次最多 20 份紀錄'; end if;

  for j in select * from jsonb_array_elements(_logs) loop
    if jsonb_array_length(coalesce(j->'turns', '[]'::jsonb)) > 500 then
      raise exception '一份紀錄一次最多 500 段';
    end if;

    cf  := nullif(j->>'capturedFrom', '');
    lid := null;

    -- 同一個對話網址視為同一份紀錄，不會每次直送都開新的一份
    if cf is not null then
      select id into lid from logs
       where owner = tk.owner and captured_from = cf
       limit 1;
    end if;

    if lid is null then
      insert into logs(owner, title, source, captured_from, scope)
      values (
        tk.owner,
        coalesce(nullif(j->>'title', ''), '未命名對話'),
        coalesce(nullif(j->>'source', ''), '外部工具擷取') || ' · 以匯入代碼直送',
        cf,
        'self'          -- 代碼開出來的紀錄一律是自主研究，老師看不到
      )
      returning id into lid;
    end if;

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

  -- 只回「寫進去幾段」。這個函式沒有任何讀取用途，
  -- 所以就算代碼外流，拿到的人也讀不到任何人的紀錄。
  return jsonb_build_object('ok', true, 'added', total);
end $$;

-- ---------- 權限 ----------
-- redeem 必須讓「還沒登入的呼叫者」也能用，那正是外部工具的處境。
-- mint / revoke 只有登入的人能用。
revoke all on function public.redeem_import_code(text, jsonb) from public;
grant execute on function public.redeem_import_code(text, jsonb) to anon, authenticated;

revoke all on function public.mint_import_code(int, text)  from public;
revoke all on function public.revoke_import_code(uuid)     from public;
grant execute on function public.mint_import_code(int, text) to authenticated;
grant execute on function public.revoke_import_code(uuid)    to authenticated;

-- ---------- 檢查 ----------
-- 跑完之後：
--   Table Editor 會多一張 import_tokens，標著 RLS enabled
--   turns 會多一欄 via_token
-- 想驗證「只能寫不能讀」：拿一組代碼去打 redeem，回傳永遠只有 {"ok":true,"added":n}。
