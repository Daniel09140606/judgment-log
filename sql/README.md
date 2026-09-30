# 資料庫結構

在 Supabase → SQL Editor，把下面的檔案**照編號依序**各貼一次執行。
每一支都寫成可以重複執行，跑第二次不會壞、也不會把資料弄不見。

| # | 檔案 | 做什麼 |
|---|---|---|
| 01 | `01-schema.sql` | 基本結構：`profiles`、`logs`、`turns`、RLS、新使用者的 trigger |
| 02 | `02-import-code.sql` | 匯入代碼：`mint` / `revoke` / `redeem`。只能寫、會過期、可撤銷 |
| 03 | `03-fix-duplicates.sql` | 合併重複的紀錄，加上 `logs(owner, captured_from)` 唯一索引 |
| 04 | `04-categories.sql` | 分類、垃圾桶（14 天）、課程範圍的紀錄不准丟 |
| 05 | `05-teacher.sql` | 老師端：建立課程、班級總覽（含「看不到幾份」的數字） |
| 06 | `06-role.sql` | 註冊時就分老師／學生 |
| 07 | `07-realtime.sql` | 把 `turns`、`logs` 加進 Realtime 的發布清單 |
| 08 | `08-why-edit.sql` | 補充說明可改但留痕；**原文與時間寫入後不可修改** |
| 09 | `09-duplicate-check.sql` | `jl_duplicates()`：查得出重複，但不自動刪 |
| 10 | `10-one-turn-one-record.sql` | 同一輪只記一筆（外掛優先），被擋的完整留在 `turn_skips` |

## 幾個看得出設計意圖的地方

**08 是地基。** 它讓「原文與擷取時間不可修改」變成資料庫擋的事，而不是介面沒做那個按鈕。整套系統的可信度建立在這一條上——介面沒做不等於做不到。

**09 只查不刪。** 重複紀錄要刪哪一筆是人的決定，不是系統的。

**10 只認問句，不認回答。** 因為同一輪被兩個寫入者記下來時，`q` 一樣但 `a` 不一樣（一個全文、一個節錄），拿 `a` 比對永遠比不出來。而且短句（12 字以下，像「好了」「同意」）不套用時間窗規則——那種話你同一段時間裡真的會講很多次。

**02 的 redeem 只回傳一個數字。** 它沒有任何讀取路徑，所以代碼外洩也讀不到任何人的紀錄。

## 驗一下有沒有真的擋住

```sql
-- 原文應該改不動
update turns set q = '改改看' where id = '任一段的 id';
-- → ERROR: 對話原文與擷取時間寫入後不可修改

-- 去重有沒有在運作
select reason, count(*) from turn_skips group by reason;

-- 還有沒有重複
select * from jl_duplicates();
```

換成自己的 Supabase 專案時，**務必用另一個帳號登入驗一次 RLS**：確認讀不到別人的任何一列。這份原始碼是公開的，anon key 也是公開的——防線只有 RLS。
