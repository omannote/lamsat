-- لمسات | تثبيت search_path للدوال المساعدة (توصية فاحص الأمان في Supabase)
alter function app.fail(text, jsonb) set search_path = '';
alter function app.round_baisa(numeric) set search_path = '';
alter function app.forbid_change() set search_path = '';
