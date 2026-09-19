-- ==========================================================================
--  تحديث ٥ — نافذة الإدخال اليومية (تبدأ ٥ مساءً) + وسم «متأخر»
--  الصقيه كاملاً في: Supabase ➜ SQL Editor ➜ New query ➜ Run
--  آمن: يضيف عمودًا واحدًا ويعدّل دوال، ولا يحذف أي بيانات. ويمكن تشغيله أكثر من مرة.
--
--  القواعد التي يطبّقها:
--   • كل يوم يفتح إدخاله الساعة ٥ مساءً ويستمر ٢٤ ساعة (إلى ٤:٥٩ من اليوم التالي)
--   • الخميس يمتد إلى الجمعة ١٠ مساءً
--   • الخميس: السرد التراكمي فقط، وباقي المهام مقفلة
--   • من سجّل داخل نافذة يومه = حضور، ومن سجّل بعدها = «متأخر» (الدرجات تُحتسب)
--   • الحضور يتصفّر تلقائيًا كل يوم عند الساعة ٥ مساءً
-- ==========================================================================

-- ------------------------- ١) عمود «متأخر» -------------------------
alter table qc_entries add column if not exists late boolean not null default false;

-- ------------------------- ٢) إعدادات النافذة -------------------------
update qc_settings set data = data || jsonb_build_object(
    'entry_start_hour', coalesce(data->'entry_start_hour', to_jsonb(17)),
    'extended_windows', coalesce(data->'extended_windows', '{"4":{"until_dow":5,"until_hour":22}}'::jsonb),
    'day_only_tasks',   coalesce(data->'day_only_tasks',   '{"4":["cumulative"]}'::jsonb)
  ), updated_at = now()
where id = 1;

-- ------------------------- ٣) «يوم البرنامج» المفتوح الآن -------------------------
-- يرجع تاريخ اليوم الذي نافذته مفتوحة في هذه اللحظة (بتوقيت الكويت).
create or replace function qc_program_day_at(p_now timestamp) returns date
language plpgsql stable security definer set search_path = public as $$
declare s jsonb; n timestamp; d date; prev date; h int; dw int; st int; k text; c jsonb;
begin
  s  := qc_conf();
  st := coalesce((s->>'entry_start_hour')::int, 17);
  n  := p_now;
  d  := n::date;
  h  := extract(hour from n)::int;
  dw := extract(dow from d)::int;
  prev := d - 1;

  -- أيام لها نافذة ممتدة (الخميس ← الجمعة ١٠ مساءً)
  for k, c in select key, value from jsonb_each(coalesce(s->'extended_windows', '{}'::jsonb)) loop
    if dw = (c->>'until_dow')::int
       and extract(dow from prev)::int = k::int
       and h < (c->>'until_hour')::int then
      return prev;
    end if;
  end loop;

  if h >= st then return d; else return prev; end if;
end $$;

create or replace function qc_program_day() returns date
language sql stable security definer set search_path = public as $$
  select qc_program_day_at((now() at time zone 'Asia/Kuwait')::timestamp);
$$;

-- ------------------------- ٤) الحفظ: النافذة + وسم المتأخر -------------------------
create or replace function app_save_day(p_token text, p_date date, p_tasks jsonb, p_note text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare u uuid; s jsonb; back int; nback int; pts numeric; open_d date; only_t jsonb; is_late boolean; st int;
begin
  u := qc_uid(p_token);
  s := qc_conf();
  st     := coalesce((s->>'entry_start_hour')::int, 17);
  back   := coalesce((s->>'backfill_days')::int, 3);
  open_d := qc_program_day();
  p_tasks := coalesce(p_tasks, '{}'::jsonb);

  if not ((s->'task_days') @> to_jsonb(extract(dow from p_date)::int)) then
    raise exception 'هذا اليوم ليس يوم مهام';
  end if;

  if p_date > open_d then
    raise exception 'لم يبدأ إدخال مهام هذا اليوم بعد — يبدأ الساعة % مساءً',
      case when st > 12 then st - 12 else st end;
  end if;

  -- مهلة التسجيل المتأخر تُحسب بأيام المهام (لا بأيام التقويم)، حتى لا تأكلها الجمعة والسبت
  if p_date <> open_d then
    select count(*) into nback
      from generate_series(p_date + 1, open_d, interval '1 day') g(d)
     where (s->'task_days') @> to_jsonb(extract(dow from g.d)::int);
    if nback > back then
      raise exception 'انتهت مهلة التسجيل لهذا اليوم، راجعي المشرفة';
    end if;
  end if;

  -- أيام مقيَّدة بمهام معيّنة (الخميس: السرد التراكمي فقط) — تُستبعد بقية المهام
  only_t := coalesce(s->'day_only_tasks', '{}'::jsonb) -> (extract(dow from p_date)::int)::text;
  if only_t is not null and jsonb_typeof(only_t) = 'array' and jsonb_array_length(only_t) > 0 then
    select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) into p_tasks
      from jsonb_each(p_tasks) where only_t @> to_jsonb(key);
  end if;

  is_late := (p_date <> open_d);
  pts := qc_points(p_tasks);

  insert into qc_entries (student_id, entry_date, tasks, note, auto_points, late)
  values (u, p_date, p_tasks, coalesce(p_note,''), pts, is_late)
  on conflict (student_id, entry_date) do update
    set tasks = excluded.tasks, note = excluded.note, auto_points = excluded.auto_points,
        late = qc_entries.late or excluded.late, updated_at = now();

  return jsonb_build_object('auto_points', pts, 'late', is_late);
end $$;

-- ------------------------- ٥) قراءة اليوم مع وسمه -------------------------
create or replace function app_get_day(p_token text, p_date date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare u uuid; e qc_entries;
begin
  u := qc_uid(p_token);
  select * into e from qc_entries where student_id = u and entry_date = p_date;
  if e.id is null then
    return jsonb_build_object('tasks','{}'::jsonb,'note','','auto_points',0,'late',false);
  end if;
  return jsonb_build_object('tasks', e.tasks, 'note', coalesce(e.note,''),
                            'auto_points', e.auto_points, 'late', coalesce(e.late,false));
end $$;

-- ------------------------- ٦) السلسلة تُحسب على اليوم المفتوح -------------------------
create or replace function qc_streak(u uuid) returns int
language plpgsql stable security definer set search_path = public as $$
declare s jsonb; d date; today_d date; n int := 0; i int := 0; cnt int; dw int;
begin
  s := qc_conf(); today_d := qc_program_day(); d := today_d;
  while i < 120 loop
    dw := extract(dow from d)::int;
    if not ((s->'task_days') @> to_jsonb(dw)) then d := d - 1; i := i + 1; continue; end if;
    select qc_done_count(tasks) into cnt from qc_entries where student_id = u and entry_date = d;
    if coalesce(cnt,0) > 0 then n := n + 1;
    elsif d = today_d then null;                 -- اليوم المفتوح لم ينتهِ بعد فلا يكسر السلسلة
    else exit;
    end if;
    d := d - 1; i := i + 1;
  end loop;
  return n;
end $$;

-- ------------------------- ٧) أسبوع الحافظة: يبيّن الأيام المتأخرة -------------------------
create or replace function app_my_week(p_token text, p_week date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare u uuid; days jsonb; manual jsonb; auto numeric; mtot numeric;
begin
  u := qc_uid(p_token);
  select coalesce(jsonb_agg(jsonb_build_object(
           'date', g.d::date, 'count', coalesce(qc_done_count(e.tasks),0),
           'points', coalesce(e.auto_points,0), 'late', coalesce(e.late,false)
         ) order by g.d), '[]'::jsonb)
    into days
    from generate_series(p_week, p_week + 6, interval '1 day') g(d)
    left join qc_entries e on e.student_id = u and e.entry_date = g.d::date;

  select coalesce(sum(e.auto_points),0) into auto
    from qc_entries e where e.student_id = u and e.entry_date between p_week and p_week + 6;

  -- سطر التصحيح مخفي عن الحافظة، لكنه محسوب في المجموع
  select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'points', points))
                    filter (where kind <> 'penalty'), '[]'::jsonb),
         coalesce(sum(points),0)
    into manual, mtot
    from qc_scores where student_id = u and week_start = p_week;

  return jsonb_build_object('days', days, 'auto', auto, 'manual', manual,
                            'manual_total', mtot, 'total', auto + mtot, 'streak', qc_streak(u));
end $$;

-- ------------------------- ٨) لوحة المشرفة: من سجّلت متأخرة -------------------------
create or replace function app_admin_data(p_token text, p_week date, p_date date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare students jsonb; scores jsonb; present jsonb; entries jsonb;
begin
  perform qc_admin(p_token);
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'review_amount', review_amount,
           'address', address, 'whatsapp', whatsapp, 'active', active,
           'created_at', created_at) order by name), '[]'::jsonb) into students from qc_students;

  select coalesce(jsonb_agg(jsonb_build_object('student_id', student_id, 'kind', kind, 'points', points)), '[]'::jsonb)
    into scores from qc_scores where week_start = p_week;

  select coalesce(jsonb_agg(student_id), '[]'::jsonb) into present
    from qc_entries where entry_date = p_date and qc_done_count(tasks) > 0;

  select coalesce(jsonb_agg(jsonb_build_object('student_id', student_id, 'note', note,
           'count', qc_done_count(tasks), 'points', auto_points, 'late', coalesce(late,false))), '[]'::jsonb)
    into entries from qc_entries where entry_date = p_date;

  return jsonb_build_object('settings', qc_conf(), 'students', students, 'rows', qc_week_rows(p_week),
                            'scores', scores, 'present', present, 'day_entries', entries,
                            'program_day', qc_program_day());
end $$;

-- ------------------------- الصلاحيات -------------------------
grant execute on function
  qc_program_day(),
  qc_program_day_at(timestamp),
  app_save_day(text,date,jsonb,text),
  app_get_day(text,date),
  app_my_week(text,date),
  app_admin_data(text,date,date)
to anon, authenticated;
