-- لمسات | وردية لكل موظف: أكثر من وردية مفتوحة على الجهاز نفسه، واحدة لكل حساب.
drop index public.cash_sessions_one_open_per_device;
create unique index cash_sessions_one_open_per_user_device on public.cash_sessions (device_id, opened_by) where status = 'open';

-- تعديل موضعي لشرط «وردية مفتوحة على الجهاز» ليصبح «وردية مفتوحة لهذا المستخدم على الجهاز» في الدالتين،
-- بدل إعادة تعريفهما كاملتين. يفشل الترحيل إن لم يوجد النص المستهدف.
do $$
declare d text; f regprocedure; target constant text := 'where device_id = v_dev.id and status = ''open'';';
begin
  foreach f in array array['public.open_cash_session(uuid,uuid,bigint)'::regprocedure, 'public.resolve_device(text)'::regprocedure] loop
    d := pg_get_functiondef(f);
    if position(target in d) = 0 then raise exception 'patch target missing in %', f; end if;
    execute replace(d, target, 'where device_id = v_dev.id and status = ''open'' and opened_by = (select auth.uid());');
  end loop;
end $$;
