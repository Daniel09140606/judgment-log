-- =========================================================
-- 判斷紀錄 · 即時更新
-- 在 Supabase → SQL Editor 貼上整段執行一次。可重複執行。
--
-- 為什麼需要這個：
--   外掛有兩條路把資料送進來——交給網頁那一頁寫、或拿匯入代碼自己寫。
--   走直送的時候，資料是繞過那一頁進資料庫的，那一頁根本不知道，
--   所以非得手動重新整理才看得到。那不叫即時。
--
--   跑了這一段之後，資料庫一有新段落就會主動推給開著的頁面，通常一秒內。
--   不跑也能用：網頁本身有每 6 秒對一次的保險機制，只是慢一點。
--
-- RLS 照樣有效——你只會收到自己看得到的那些列的通知。
-- =========================================================

do $$
begin
  alter publication supabase_realtime add table public.turns;
exception when duplicate_object then
  raise notice 'turns 已經在發布清單裡了';
end $$;

do $$
begin
  alter publication supabase_realtime add table public.logs;
exception when duplicate_object then
  raise notice 'logs 已經在發布清單裡了';
end $$;

-- ---------- 檢查 ----------
-- select tablename from pg_publication_tables where pubname = 'supabase_realtime';
-- 應該看得到 turns 跟 logs。
