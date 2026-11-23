-- =====================================================================
--  Alpha LogicX — قاعدة بيانات واحدة لكل الصفوف (العاشر g10 · الأول ثانوي t1 · الثاني ثانوي t2)
--  يُشغَّل بعد schema.sql. آمن للتشغيل أكثر من مرة.
--  الفكرة: كل واجب/رسالة/اجتماع يحمل «grade»، وكل مستخدم يرى صفه فقط:
--    • الطالب ← صفه من student_info
--    • الأستاذ ← صفه من teacher_names.grade (فارغ = كل الصفوف، مثل ghost)
-- =====================================================================

-- 1) الأساتذة وصفوفهم
alter table public.teacher_names add column if not exists grade text check (grade in ('g10', 't1', 't2'));
insert into public.teacher_names (username, grade) values
  ('samer', 'g10'), ('mohammad', 'g10'), ('yasser', 't1'), ('ghost', null)
on conflict (username) do update set grade = excluded.grade;

-- 2) الصفوف (شعبة IT لكل مرحلة)
insert into public.classes (id, name, grade_key, track, teacher_username) values
  ('t1-it', 'الأول ثانوي — تكنولوجيا المعلومات', 't1', 'it', 'yasser'),
  ('t2-it', 'الثاني ثانوي — تكنولوجيا المعلومات', 't2', 'it', '*')
on conflict (id) do nothing;

-- 3) صف المستخدم الحالي
create or replace function public.my_grade() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select s.grade from public.student_info s where s.uid = auth.uid()),
    (select t.grade from public.teacher_names t join public.profiles p on p.username = t.username
      where p.id = auth.uid() and p.role = 'teacher'));
$$;

-- أستاذ لكل الصفوف (لا صف محدد له)
create or replace function public.all_grades() returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_teacher() and public.my_grade() is null;
$$;

create or replace function public.grade_ok(g text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.all_grades() or g = public.my_grade();
$$;
grant execute on function public.my_grade(), public.all_grades(), public.grade_ok(text) to authenticated;

-- 4) عمود الصف على المحتوى المشترك (القيمة تلقائياً = صف من أنشأه)
do $$
declare t text;
begin
  foreach t in array array['assignments', 'messages', 'meetings'] loop
    execute format('alter table public.%I add column if not exists grade text', t);
    execute format('update public.%I set grade = ''g10'' where grade is null', t);
    execute format('alter table public.%I alter column grade set default coalesce(public.my_grade(), ''g10'')', t);
    execute format('alter table public.%I alter column grade set not null', t);
    execute format('create index if not exists %I on public.%I (grade)', t || '_grade_idx', t);
    execute format('drop policy if exists "grade scope" on public.%I', t);
    execute format('create policy "grade scope" on public.%I as restrictive for all to authenticated using (public.grade_ok(grade)) with check (public.grade_ok(grade))', t);
  end loop;
end $$;

-- الحلول تتبع صف الواجب
drop policy if exists "grade scope" on public.submissions;
create policy "grade scope" on public.submissions as restrictive for all to authenticated
  using (exists (select 1 from public.assignments a where a.id = aid and public.grade_ok(a.grade)))
  with check (exists (select 1 from public.assignments a where a.id = aid and public.grade_ok(a.grade)));

-- 5) الأستاذ مسؤول عن صفوف مرحلته فقط
create or replace function public.teaches_class(cid text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.my_username() is not null and exists (
    select 1 from public.classes c where c.id = cid and (public.all_grades() or c.grade_key = public.my_grade()));
$$;

-- 6) لائحة المتصدرين: طلاب نفس الصف فقط
create or replace function public.leaderboard()
returns table (uid uuid, xp bigint, n bigint)
language sql stable security definer set search_path = public as $$
  select p.id,
         coalesce(sum(s.xp) filter (where s.status = 'accepted'), 0)::bigint,
         count(s.id) filter (where s.status = 'accepted')::bigint
  from public.profiles p
  join public.student_info si on si.uid = p.id
  left join public.submissions s on s.uid = p.id
  where p.role = 'student' and public.grade_ok(si.grade)
  group by p.id;
$$;

notify pgrst, 'reload schema';
