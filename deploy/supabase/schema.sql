
-- =====================================================================
--  Alpha LogicX (الصف العاشر) — منصة المدرسة على Supabase
--  شغّل هذا الملف كاملاً مرة واحدة من: Supabase → SQL Editor → New query → Run
--  آمن للتشغيل أكثر من مرة (لا يحذف بياناتك).
--
--  ينشئ: الحسابات والأدوار (أستاذ/طالب) + الواجبات والمشاريع + الحلول
--        + الشات + الاجتماعات + الكاردات + تخزين الملفات + صلاحيات الوقت الحقيقي
--  أول من يسجّل باسم المستخدم «samer» أو «mohammad» يصبح أستاذاً تلقائياً (الأسماء في جدول teacher_names)،
--  وبعد ذلك لا يستطيع أحد أخذ الاسم نفسه (يختار الطالب اسماً آخر).
-- =====================================================================

-- ---------- 1) الجداول ----------
-- أسماء حسابات الأساتذة (من يسجّل بها أولاً يصبح أستاذاً). لإضافة أستاذ: insert into public.teacher_names values ('اسم');
create table if not exists public.teacher_names (username text primary key check (username ~ '^[a-z0-9._-]{2,20}$'));
insert into public.teacher_names (username) values ('samer'), ('mohammad'), ('ghost') on conflict do nothing;
alter table public.teacher_names enable row level security;
revoke all on public.teacher_names from anon, authenticated;

create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  username    text not null unique check (username ~ '^[a-z0-9][a-z0-9._-]{1,19}$'),
  name        text not null default '' check (char_length(name) <= 40),
  avatar      text not null default '' check (char_length(avatar) <= 16),
  role        text not null default 'student' check (role in ('teacher', 'student')),
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists public.cards (
  id          text primary key default gen_random_uuid()::text,
  ic          text not null default '📌' check (char_length(ic) <= 16),
  t           text not null check (char_length(t) between 1 and 60),
  d           text not null default '' check (char_length(d) <= 120),
  body        text not null default '' check (char_length(body) <= 5000),
  b           boolean not null default false,          -- كارد أساسي (لا يُحذف)
  ord         int not null default 100,
  created_at  timestamptz not null default now()
);

create table if not exists public.assignments (
  id          uuid primary key default gen_random_uuid(),
  kind        text not null default 'hw' check (kind in ('hw', 'project')),
  title       text not null check (char_length(title) between 1 and 150),
  descr       text not null default '' check (char_length(descr) <= 10000),
  ins         text not null default '' check (char_length(ins) <= 10000),
  link        text not null default '' check (char_length(link) <= 500),
  xp          int  not null default 10 check (xp between 0 and 1000),
  re          boolean not null default true,           -- السماح بإعادة الإرسال
  pub         timestamptz not null default now(),      -- تاريخ النشر
  due         timestamptz,                             -- الموعد النهائي
  file        jsonb,
  created_by  uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at  timestamptz not null default now()
);

create table if not exists public.submissions (
  id          uuid primary key default gen_random_uuid(),
  aid         uuid not null references public.assignments(id) on delete cascade,
  uid         uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  text        text not null default '' check (char_length(text) <= 10000),
  file        jsonb,
  status      text not null default 'submitted' check (status in ('submitted', 'accepted', 'needs_revision')),
  xp          int  not null default 0,
  fb          text not null default '' check (char_length(fb) <= 5000),
  at          timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references public.profiles(id) on delete set null,
  unique (aid, uid)
);

create table if not exists public.messages (
  id          uuid primary key default gen_random_uuid(),
  uid         uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  t           text not null check (char_length(t) between 1 and 500),
  at          timestamptz not null default now()
);

create table if not exists public.meetings (
  id          uuid primary key default gen_random_uuid(),
  title       text not null check (char_length(title) between 1 and 120),
  kind        text not null default 'video' check (kind in ('video', 'audio')),
  notes       text not null default '' check (char_length(notes) <= 2000),
  host        uuid default auth.uid() references public.profiles(id) on delete set null,
  starts_at   timestamptz not null default now(),
  status      text not null default 'scheduled' check (status in ('scheduled', 'live', 'ended')),
  started_at  timestamptz,
  ended_at    timestamptz,
  created_at  timestamptz not null default now()
);

create index if not exists submissions_aid_idx on public.submissions (aid);
create index if not exists submissions_uid_idx on public.submissions (uid);
create index if not exists messages_at_idx on public.messages (at desc);
create index if not exists meetings_starts_idx on public.meetings (starts_at desc);

-- ---------- 2) دوال مساعدة ----------
create or replace function public.is_teacher() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'teacher' and active);
$$;

create or replace function public.is_active() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and active);
$$;

-- إنشاء الملف الشخصي تلقائياً عند التسجيل: أسماء الأساتذة من جدول teacher_names، والباقي طلاب
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  u text := lower(coalesce(nullif(new.raw_user_meta_data ->> 'username', ''), split_part(new.email, '@', 1)));
  r text := 'student';
begin
  if exists (select 1 from public.teacher_names t where t.username = u) then
    r := 'teacher';
  end if;
  insert into public.profiles (id, username, name, avatar, role)
  values (new.id, u,
          left(coalesce(nullif(trim(new.raw_user_meta_data ->> 'name'), ''), case when r = 'teacher' then 'الأستاذ' else u end), 40),
          left(coalesce(new.raw_user_meta_data ->> 'avatar', ''), 16),
          r);
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- حماية الملف الشخصي: الطالب لا يستطيع ترقية نفسه، ولا تغيير اسم المستخدم
create or replace function public.profiles_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.id <> old.id or new.username <> old.username or new.created_at <> old.created_at then
    raise exception 'لا يمكن تغيير اسم المستخدم';
  end if;
  if (new.role <> old.role or new.active <> old.active) and auth.uid() is not null then
    if not public.is_teacher() then raise exception 'فقط الأستاذ يغيّر الصلاحيات'; end if;
    if old.id = auth.uid() then raise exception 'لا يمكنك تغيير صلاحياتك بنفسك'; end if;
  end if;
  return new;
end $$;

drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard before update on public.profiles
  for each row execute function public.profiles_guard();

-- حماية الحلول: الطالب يرسل/يعدّل حلّه فقط، والأستاذ وحده يقبل ويمنح XP (مرة واحدة)
create or replace function public.submissions_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare a public.assignments;
begin
  select * into a from public.assignments where id = new.aid;
  if a.id is null then raise exception 'الواجب غير موجود'; end if;
  if auth.uid() is null then return new; end if;            -- SQL Editor / service role

  if tg_op = 'UPDATE' and public.is_teacher() and old.uid <> auth.uid() then
    -- مراجعة الأستاذ
    if old.status = 'accepted' then raise exception 'تم قبول هذا الحل مسبقاً'; end if;
    if new.status not in ('accepted', 'needs_revision') then raise exception 'حالة غير صالحة'; end if;
    new.aid := old.aid; new.uid := old.uid; new.text := old.text; new.file := old.file; new.at := old.at;
    new.xp := case when new.status = 'accepted' then a.xp else 0 end;
    new.reviewed_at := now(); new.reviewed_by := auth.uid();
    return new;
  end if;

  if tg_op = 'INSERT' then
    if a.pub > now() then raise exception 'الواجب غير منشور بعد'; end if;
    if a.due is not null and a.due < now() then raise exception 'انتهى الموعد النهائي'; end if;
    new.uid := auth.uid(); new.fb := '';
  else
    if old.uid <> auth.uid() then raise exception 'غير مسموح'; end if;
    if old.status = 'accepted' then raise exception 'تم قبول هذا الحل مسبقاً'; end if;
    if not (old.status = 'needs_revision' or (a.re and (a.due is null or a.due >= now()))) then
      raise exception 'لا يمكن إعادة الإرسال';
    end if;
    new.aid := old.aid; new.uid := old.uid; new.fb := old.fb;
    new.reviewed_at := old.reviewed_at; new.reviewed_by := old.reviewed_by;
  end if;
  new.status := 'submitted'; new.xp := 0; new.at := now();
  return new;
end $$;

drop trigger if exists submissions_guard on public.submissions;
create trigger submissions_guard before insert or update on public.submissions
  for each row execute function public.submissions_guard();

create or replace function public.messages_stamp() returns trigger
language plpgsql as $$
begin
  if auth.uid() is not null then new.uid := auth.uid(); end if;
  new.at := now();
  return new;
end $$;

drop trigger if exists messages_stamp on public.messages;
create trigger messages_stamp before insert on public.messages
  for each row execute function public.messages_stamp();

-- لائحة المتصدرين (يراها الجميع دون كشف حلول الآخرين)
create or replace function public.leaderboard()
returns table (uid uuid, xp bigint, n bigint)
language sql stable security definer set search_path = public as $$
  select p.id,
         coalesce(sum(s.xp) filter (where s.status = 'accepted'), 0)::bigint,
         count(s.id) filter (where s.status = 'accepted')::bigint
  from public.profiles p
  left join public.submissions s on s.uid = p.id
  where p.role = 'student'
  group by p.id;
$$;

-- ---------- 3) الصلاحيات (Row Level Security) ----------
alter table public.profiles    enable row level security;
alter table public.cards       enable row level security;
alter table public.assignments enable row level security;
alter table public.submissions enable row level security;
alter table public.messages    enable row level security;
alter table public.meetings    enable row level security;

grant usage on schema public to authenticated;
grant select, insert, update, delete on public.profiles, public.cards, public.assignments,
  public.submissions, public.messages, public.meetings to authenticated;
revoke all on public.profiles, public.cards, public.assignments,
  public.submissions, public.messages, public.meetings from anon;
grant execute on function public.leaderboard(), public.is_teacher(), public.is_active() to authenticated;

-- profiles
drop policy if exists "profiles read" on public.profiles;
create policy "profiles read" on public.profiles for select to authenticated using (true);
drop policy if exists "profiles update" on public.profiles;
create policy "profiles update" on public.profiles for update to authenticated
  using (id = auth.uid() or public.is_teacher()) with check (id = auth.uid() or public.is_teacher());

-- cards (الأستاذ فقط يعدّل)
drop policy if exists "cards read" on public.cards;
create policy "cards read" on public.cards for select to authenticated using (true);
drop policy if exists "cards insert" on public.cards;
create policy "cards insert" on public.cards for insert to authenticated with check (public.is_teacher());
drop policy if exists "cards update" on public.cards;
create policy "cards update" on public.cards for update to authenticated using (public.is_teacher()) with check (public.is_teacher());
drop policy if exists "cards delete" on public.cards;
create policy "cards delete" on public.cards for delete to authenticated using (public.is_teacher() and not b);

-- assignments (الطالب يرى المنشور فقط)
drop policy if exists "assignments read" on public.assignments;
create policy "assignments read" on public.assignments for select to authenticated
  using (public.is_teacher() or pub <= now());
drop policy if exists "assignments insert" on public.assignments;
create policy "assignments insert" on public.assignments for insert to authenticated with check (public.is_teacher());
drop policy if exists "assignments update" on public.assignments;
create policy "assignments update" on public.assignments for update to authenticated using (public.is_teacher()) with check (public.is_teacher());
drop policy if exists "assignments delete" on public.assignments;
create policy "assignments delete" on public.assignments for delete to authenticated using (public.is_teacher());

-- submissions (الطالب يرى حلّه فقط، والأستاذ يرى الكل)
drop policy if exists "submissions read" on public.submissions;
create policy "submissions read" on public.submissions for select to authenticated
  using (uid = auth.uid() or public.is_teacher());
drop policy if exists "submissions insert" on public.submissions;
create policy "submissions insert" on public.submissions for insert to authenticated
  with check (uid = auth.uid() and public.is_active());
drop policy if exists "submissions update" on public.submissions;
create policy "submissions update" on public.submissions for update to authenticated
  using ((uid = auth.uid() and public.is_active()) or public.is_teacher())
  with check ((uid = auth.uid() and public.is_active()) or public.is_teacher());
drop policy if exists "submissions delete" on public.submissions;
create policy "submissions delete" on public.submissions for delete to authenticated using (public.is_teacher());

-- messages
drop policy if exists "messages read" on public.messages;
create policy "messages read" on public.messages for select to authenticated using (true);
drop policy if exists "messages insert" on public.messages;
create policy "messages insert" on public.messages for insert to authenticated
  with check (uid = auth.uid() and public.is_active());
drop policy if exists "messages delete" on public.messages;
create policy "messages delete" on public.messages for delete to authenticated
  using (uid = auth.uid() or public.is_teacher());

-- meetings (الأستاذ ينشئ ويدير، والجميع ينضم)
drop policy if exists "meetings read" on public.meetings;
create policy "meetings read" on public.meetings for select to authenticated using (true);
drop policy if exists "meetings insert" on public.meetings;
create policy "meetings insert" on public.meetings for insert to authenticated with check (public.is_teacher());
drop policy if exists "meetings update" on public.meetings;
create policy "meetings update" on public.meetings for update to authenticated using (public.is_teacher()) with check (public.is_teacher());
drop policy if exists "meetings delete" on public.meetings;
create policy "meetings delete" on public.meetings for delete to authenticated using (public.is_teacher());

-- ---------- 4) الكاردات الأساسية ----------
insert into public.cards (id, ic, t, d, b, ord) values
  ('assignments', '📚', 'الواجبات والمشاريع', 'اعرض الواجبات والمشاريع وأرسل حلولك', true, 1),
  ('meet', '🎥', 'الاجتماعات والمكالمات', 'اجتماعات فيديو ومكالمات صوتية مع الصف', true, 2),
  ('chat', '💬', 'شات نقل المعرفة', 'تبادل المعرفة مع زملائك', true, 3),
  ('board', '🏆', 'لائحة المتصدرين', 'ترتيب الطلاب حسب XP', true, 4)
on conflict (id) do nothing;

-- ---------- 5) تخزين الملفات (حتى 10MB للملف) ----------
insert into storage.buckets (id, name, public, file_size_limit)
values ('alx-files', 'alx-files', false, 10485760)
on conflict (id) do update set file_size_limit = excluded.file_size_limit;

drop policy if exists "alx files read" on storage.objects;
create policy "alx files read" on storage.objects for select to authenticated
  using (bucket_id = 'alx-files' and (
    (storage.foldername(objects.name))[1] = auth.uid()::text
    or public.is_teacher()
    or exists (select 1 from public.profiles p
               where p.id::text = (storage.foldername(objects.name))[1] and p.role = 'teacher')));
drop policy if exists "alx files upload" on storage.objects;
create policy "alx files upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'alx-files' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "alx files delete" on storage.objects;
create policy "alx files delete" on storage.objects for delete to authenticated
  using (bucket_id = 'alx-files' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_teacher()));

-- ---------- 6) الوقت الحقيقي (تحديث فوري + قنوات الاجتماعات) ----------
do $$
declare t text;
begin
  foreach t in array array['profiles', 'cards', 'assignments', 'submissions', 'messages', 'meetings'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;

-- قنوات الاجتماعات والمكالمات للمسجّلين فقط، وأوامر التحكم (ctl:) للأستاذ فقط
drop policy if exists "alx realtime read" on realtime.messages;
create policy "alx realtime read" on realtime.messages for select to authenticated using (true);
drop policy if exists "alx realtime write" on realtime.messages;
create policy "alx realtime write" on realtime.messages for insert to authenticated
  with check (realtime.topic() not like 'ctl:%' or public.is_teacher());

-- =====================================================================
--  7) الحضور والغياب + طلبات التسجيل + صفوف الأساتذة
--  شغّل هذا القسم (أو الملف كاملاً) من: Supabase → SQL Editor → New query → Run
--  آمن للتشغيل أكثر من مرة ولا يحذف بياناتك.
--
--  ما ينشئه:
--   • classes            الصفوف (العاشر ← الأستاذان samer وmohammad) + توقيت الحضور الافتراضي
--   • student_info       بيانات تسجيل الطالب (المرحلة، المدرسة، الرقم المدرسي) + حالة الموافقة
--   • attendance_days    استثناءات يوم محدد (عطلة / توقيت مختلف)
--   • attendance_records تسجيلات الحضور (الطالب يسجّل ← الأستاذ يوافق)
--   • absence_reports    تقارير الغياب بعذر
--  كل الكتابة تتم عبر دوال RPC محمية؛ الطالب لا يستطيع كتابة أي شيء مباشرة.
-- =====================================================================

-- ---------- 1) الجداول ----------
create table if not exists public.classes (
  id               text primary key check (id ~ '^[a-z0-9_-]{2,30}$'),
  name             text not null check (char_length(name) between 2 and 60),
  grade_key        text not null check (grade_key in ('g10', 't1', 't2')),
  track            text not null default 'it' check (track in ('it', 'eng', 'agri', 'biz', 'sport')),  -- تخصص BTEC
  teacher_username text not null,                                  -- الأستاذ المسؤول عن الصف
  att_open         time not null default '07:00',                  -- بداية تسجيل الحضور
  att_close        time not null default '08:00',                  -- نهاية التسجيل
  att_late         time,                                           -- بعد هذا الوقت يُحسب متأخراً (اختياري)
  att_days         int[] not null default '{0,1,2,3,4}',           -- أيام الدوام: 0=الأحد … 6=السبت
  tz               text not null default 'Asia/Amman',
  created_at       timestamptz not null default now(),
  check (att_open < att_close),
  check (att_late is null or (att_late > att_open and att_late <= att_close)),
  check (cardinality(att_days) >= 1 and att_days <@ array[0, 1, 2, 3, 4, 5, 6])
);

-- إن كان الجدول موجوداً من تشغيل سابق
alter table public.classes add column if not exists track text not null default 'it' check (track in ('it', 'eng', 'agri', 'biz', 'sport'));

insert into public.classes (id, name, grade_key, track, teacher_username)
values ('g10-it', 'العاشر — تكنولوجيا المعلومات', 'g10', 'it', '*')
on conflict (id) do nothing;

create table if not exists public.student_info (
  uid           uuid primary key references public.profiles(id) on delete cascade,
  grade         text not null check (grade in ('g10', 't1', 't2')),
  track         text not null default 'it' check (track in ('it', 'eng', 'agri', 'biz', 'sport')),
  school        text not null default '' check (char_length(school) <= 60),
  school_no     text not null default '' check (char_length(school_no) <= 20),
  class_id      text references public.classes(id) on delete set null,
  reg_status    text not null default 'pending' check (reg_status in ('pending', 'approved', 'rejected')),
  reg_note      text not null default '' check (char_length(reg_note) <= 300),
  requested_at  timestamptz not null default now(),
  approved_at   timestamptz,
  reviewed_by   uuid references public.profiles(id) on delete set null,
  reviewed_at   timestamptz
);
alter table public.student_info add column if not exists track text not null default 'it' check (track in ('it', 'eng', 'agri', 'biz', 'sport'));
create index if not exists student_info_class_idx on public.student_info (class_id, reg_status);

-- الطلاب الحاليون (قبل هذا التحديث) يُعتمدون تلقائياً في العاشر، وتبدأ سجلاتهم من الآن
insert into public.student_info (uid, grade, class_id, reg_status, approved_at)
select p.id, 'g10', 'g10-it', 'approved', now()
from public.profiles p where p.role = 'student'
on conflict (uid) do nothing;

create table if not exists public.attendance_days (
  class_id  text not null references public.classes(id) on delete cascade,
  day       date not null,
  is_off    boolean not null default false,                         -- عطلة / لا دوام
  open_t    time,
  close_t   time,
  late_t    time,
  primary key (class_id, day)
);

create table if not exists public.attendance_records (
  id           uuid primary key default gen_random_uuid(),
  class_id     text not null references public.classes(id) on delete cascade,
  uid          uuid not null references public.profiles(id) on delete cascade,
  day          date not null,
  status       text not null check (status in ('present', 'late', 'absent', 'excused')),
  approval     text not null default 'pending' check (approval in ('pending', 'approved', 'rejected')),
  source       text not null default 'self' check (source in ('self', 'teacher', 'report')),
  note         text not null default '' check (char_length(note) <= 300),
  at           timestamptz not null default now(),
  reviewed_by  uuid references public.profiles(id) on delete set null,
  reviewed_at  timestamptz,
  unique (uid, day)
);
create index if not exists attendance_records_class_day_idx on public.attendance_records (class_id, day desc);

create table if not exists public.absence_reports (
  id           uuid primary key default gen_random_uuid(),
  class_id     text not null references public.classes(id) on delete cascade,
  uid          uuid not null references public.profiles(id) on delete cascade,
  day_from     date not null,
  day_to       date not null,
  kind         text not null check (kind in ('sick', 'family', 'emergency', 'transport', 'other')),
  note         text not null default '' check (char_length(note) <= 500),
  status       text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  teacher_note text not null default '' check (char_length(teacher_note) <= 300),
  created_at   timestamptz not null default now(),
  reviewed_by  uuid references public.profiles(id) on delete set null,
  reviewed_at  timestamptz,
  check (day_to >= day_from)
);
create index if not exists absence_reports_class_idx on public.absence_reports (class_id, created_at desc);

-- ---------- 2) دوال الصلاحيات ----------
create or replace function public.my_username() returns text
language sql stable security definer set search_path = public as $$
  select username from public.profiles where id = auth.uid() and role = 'teacher' and active;
$$;

-- هل الأستاذ الحالي مسؤول عن هذا الصف؟
create or replace function public.teaches_class(cid text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.my_username() is not null and exists (select 1 from public.classes c where c.id = cid);
$$;

-- هل الطالب في صف يديره الأستاذ الحالي؟
create or replace function public.teaches_student(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.student_info s where s.uid = sid and public.teaches_class(s.class_id));
$$;

-- حساب فعّال: أستاذ، أو طالب معتمد (الطالب بلا سجل تسجيل قديم يُعتبر معتمداً)
create or replace function public.is_approved() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.active and (
      p.role = 'teacher'
      or not exists (select 1 from public.student_info s where s.uid = p.id)
      or exists (select 1 from public.student_info s where s.uid = p.id and s.reg_status = 'approved')
    )
  );
$$;

create or replace function public.my_class_id() returns text
language sql stable security definer set search_path = public as $$
  select s.class_id from public.student_info s where s.uid = auth.uid() and s.reg_status = 'approved';
$$;

-- الطالب غير المعتمد لا يستطيع الإرسال/الكتابة في أي مكان في المنصة
create or replace function public.is_active() returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_approved();
$$;

-- ---------- 3) إنشاء الحساب: طالب جديد = بانتظار موافقة أستاذ الصف ----------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  u  text := lower(coalesce(nullif(new.raw_user_meta_data ->> 'username', ''), split_part(new.email, '@', 1)));
  r  text := 'student';
  g  text := coalesce(new.raw_user_meta_data ->> 'grade', '');
  tr text := coalesce(nullif(new.raw_user_meta_data ->> 'track', ''), 'it');
  sc text := left(trim(coalesce(new.raw_user_meta_data ->> 'school', '')), 60);
  sn text := left(trim(coalesce(new.raw_user_meta_data ->> 'school_no', '')), 20);
  cid text;
begin
  if exists (select 1 from public.teacher_names t where t.username = u) then
    r := 'teacher';
  end if;

  if r = 'student' then
    if g not in ('g10', 't1', 't2') then raise exception 'اختر المرحلة الدراسية'; end if;
    if tr not in ('it', 'eng', 'agri', 'biz', 'sport') then raise exception 'اختر التخصص'; end if;
    select c.id into cid from public.classes c where c.grade_key = g and c.track = tr order by c.created_at limit 1;
    if cid is null then raise exception 'لم يتوفر هذا الصف أو التخصص بعد'; end if;
    if char_length(sc) < 2 then raise exception 'اكتب اسم المدرسة'; end if;
    if char_length(sn) < 1 then raise exception 'اكتب رقم الطالب المدرسي'; end if;
  end if;

  insert into public.profiles (id, username, name, avatar, role)
  values (new.id, u,
          left(coalesce(nullif(trim(new.raw_user_meta_data ->> 'name'), ''), case when r = 'teacher' then 'الأستاذ' else u end), 40),
          left(coalesce(new.raw_user_meta_data ->> 'avatar', ''), 16),
          r);

  if r = 'student' then
    insert into public.student_info (uid, grade, track, school, school_no, class_id, reg_status)
    values (new.id, g, tr, sc, sn, cid, 'pending');
  end if;
  return new;
end $$;

-- لائحة المتصدرين: الطلاب المعتمدون فقط
create or replace function public.leaderboard()
returns table (uid uuid, xp bigint, n bigint)
language sql stable security definer set search_path = public as $$
  select p.id,
         coalesce(sum(s.xp) filter (where s.status = 'accepted'), 0)::bigint,
         count(s.id) filter (where s.status = 'accepted')::bigint
  from public.profiles p
  left join public.submissions s on s.uid = p.id
  where p.role = 'student'
    and (not exists (select 1 from public.student_info i where i.uid = p.id)
         or exists (select 1 from public.student_info i where i.uid = p.id and i.reg_status = 'approved'))
  group by p.id;
$$;

-- ---------- 4) نافذة الحضور ليوم معيّن (الإعداد الافتراضي + الاستثناء) ----------
create or replace function public.att_window(p_class text, p_day date)
returns table (school_day boolean, opens timestamptz, closes timestamptz, late timestamptz)
language sql stable security definer set search_path = public as $$
  select
    case when o.class_id is not null then not o.is_off
         else extract(dow from p_day)::int = any (c.att_days) end,
    ((p_day + coalesce(o.open_t, c.att_open)) at time zone c.tz),
    ((p_day + coalesce(o.close_t, c.att_close)) at time zone c.tz),
    case when coalesce(o.late_t, c.att_late) is null then null
         else ((p_day + coalesce(o.late_t, c.att_late)) at time zone c.tz) end
  from public.classes c
  left join public.attendance_days o on o.class_id = c.id and o.day = p_day
  where c.id = p_class;
$$;

-- الحالة الفعلية لكل طالب في كل يوم دوام. من لم يسجّل بعد انتهاء الوقت = غائب تلقائياً.
create or replace function public.att_sheet_core(p_class text, p_uid uuid, p_from date, p_to date)
returns table (uid uuid, day date, eff text, rec_id uuid, rec_status text, approval text, source text, note text, at timestamptz, reviewed_at timestamptz)
language sql stable security definer set search_path = public as $$
  select s.uid, d.day,
    case
      when r.id is not null and r.approval = 'approved' then r.status
      when r.id is not null and r.approval = 'pending'  then 'pending'
      when w.closes < now() then 'absent'
      else 'none'
    end,
    r.id, r.status, r.approval, r.source, r.note, r.at, r.reviewed_at
  from public.classes c
  join public.student_info s on s.class_id = c.id and s.reg_status = 'approved'
  join public.profiles p on p.id = s.uid and p.active
  cross join lateral generate_series(
      greatest(p_from, (coalesce(s.approved_at, s.requested_at) at time zone c.tz)::date)::timestamp,
      least(p_to, (now() at time zone c.tz)::date)::timestamp,
      interval '1 day') as gs(ts)
  cross join lateral (select gs.ts::date as day) d
  left join public.attendance_records r on r.uid = s.uid and r.day = d.day
  cross join lateral public.att_window(c.id, d.day) w
  where c.id = p_class
    and (p_uid is null or s.uid = p_uid)
    and (w.school_day or r.id is not null)
  order by d.day desc, s.uid;
$$;

-- ---------- 5) دوال الأستاذ والطالب (RPC) ----------
-- لوحة الأستاذ: كل الطلاب × كل الأيام
create or replace function public.att_sheet(p_class text, p_from date, p_to date)
returns table (uid uuid, day date, eff text, rec_id uuid, rec_status text, approval text, source text, note text, at timestamptz, reviewed_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.teaches_class(p_class) then raise exception 'ليست لديك صلاحية على هذا الصف'; end if;
  if p_to - p_from > 1100 then raise exception 'المدة المطلوبة طويلة جداً'; end if;
  return query select * from public.att_sheet_core(p_class, null, p_from, p_to);
end $$;

-- سجل الطالب نفسه
create or replace function public.att_mine(p_from date, p_to date)
returns table (uid uuid, day date, eff text, rec_id uuid, rec_status text, approval text, source text, note text, at timestamptz, reviewed_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare v_class text := public.my_class_id();
begin
  if auth.uid() is null or v_class is null then raise exception 'حسابك غير مرتبط بصف معتمد'; end if;
  if p_to - p_from > 1100 then raise exception 'المدة المطلوبة طويلة جداً'; end if;
  return query select * from public.att_sheet_core(v_class, auth.uid(), p_from, p_to);
end $$;

-- حالة اليوم للطالب (الوقت من السيرفر وليس من جهاز الطالب)
create or replace function public.att_today() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_class text := public.my_class_id(); c public.classes; d date; w record; r public.attendance_records; st text;
begin
  if auth.uid() is null or v_class is null then raise exception 'حسابك غير مرتبط بصف معتمد'; end if;
  select * into c from public.classes where id = v_class;
  d := (now() at time zone c.tz)::date;
  select * into w from public.att_window(v_class, d);
  select * into r from public.attendance_records where attendance_records.uid = auth.uid() and attendance_records.day = d;
  st := case when not w.school_day then 'off'
             when now() < w.opens then 'before'
             when now() <= w.closes then 'open'
             else 'closed' end;
  return jsonb_build_object('class_id', v_class, 'class_name', c.name, 'tz', c.tz, 'day', d, 'now', now(),
    'state', st, 'opens', w.opens, 'closes', w.closes, 'late', w.late,
    'record', case when r.id is null then null else to_jsonb(r) end);
end $$;

-- حالة اليوم للأستاذ (لصفّه)
create or replace function public.att_class_today(p_class text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c public.classes; d date; w record; st text;
begin
  if not public.teaches_class(p_class) then raise exception 'ليست لديك صلاحية على هذا الصف'; end if;
  select * into c from public.classes where id = p_class;
  d := (now() at time zone c.tz)::date;
  select * into w from public.att_window(p_class, d);
  st := case when not w.school_day then 'off'
             when now() < w.opens then 'before'
             when now() <= w.closes then 'open'
             else 'closed' end;
  return jsonb_build_object('class_id', c.id, 'class_name', c.name, 'tz', c.tz, 'day', d, 'now', now(),
    'state', st, 'opens', w.opens, 'closes', w.closes, 'late', w.late);
end $$;

-- الطالب يسجّل حضوره (يُرسل للأستاذ ولا يُحسب إلا بعد موافقته)
create or replace function public.att_check_in(p_note text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_class text; c public.classes; d date; w record; r public.attendance_records; st text;
begin
  if auth.uid() is null or not public.is_approved() then raise exception 'حسابك غير مفعّل'; end if;
  v_class := public.my_class_id();
  if v_class is null then raise exception 'حسابك غير مرتبط بصف معتمد'; end if;
  select * into c from public.classes where id = v_class;
  d := (now() at time zone c.tz)::date;
  select * into w from public.att_window(v_class, d);
  if not w.school_day then raise exception 'لا يوجد دوام اليوم'; end if;
  if now() < w.opens then raise exception 'لم يبدأ وقت تسجيل الحضور بعد'; end if;
  if now() > w.closes then raise exception 'انتهى وقت تسجيل الحضور لهذا اليوم'; end if;

  select * into r from public.attendance_records where attendance_records.uid = auth.uid() and attendance_records.day = d;
  if r.id is not null and r.approval <> 'rejected' then
    raise exception '%', case when r.status = 'excused' then 'هذا اليوم مسجّل لك كغياب بعذر'
                              else 'سجّلت حضورك لهذا اليوم مسبقاً' end;
  end if;

  st := case when w.late is not null and now() > w.late then 'late' else 'present' end;
  insert into public.attendance_records (class_id, uid, day, status, approval, source, note, at)
  values (v_class, auth.uid(), d, st, 'pending', 'self', left(coalesce(p_note, ''), 300), now())
  on conflict (uid, day) do update
    set status = excluded.status, approval = 'pending', source = 'self', note = excluded.note,
        at = now(), reviewed_by = null, reviewed_at = null
  returning * into r;
  return to_jsonb(r);
end $$;

-- الأستاذ يسجّل/يعدّل حالة طالب في يوم (حاضر / متأخر / غائب / غياب بعذر)
create or replace function public.att_set(p_uid uuid, p_day date, p_status text, p_note text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_class text; v_tz text; r public.attendance_records;
begin
  if not public.teaches_student(p_uid) then raise exception 'ليست لديك صلاحية على هذا الطالب'; end if;
  if p_status not in ('present', 'late', 'absent', 'excused') then raise exception 'حالة غير صالحة'; end if;
  select s.class_id, c.tz into v_class, v_tz
  from public.student_info s join public.classes c on c.id = s.class_id where s.uid = p_uid;
  if p_day > (now() at time zone v_tz)::date then raise exception 'لا يمكن تسجيل يوم لم يأتِ بعد'; end if;
  insert into public.attendance_records (class_id, uid, day, status, approval, source, note, at, reviewed_by, reviewed_at)
  values (v_class, p_uid, p_day, p_status, 'approved', 'teacher', left(coalesce(p_note, ''), 300), now(), auth.uid(), now())
  on conflict (uid, day) do update
    set status = excluded.status, approval = 'approved', source = 'teacher', note = excluded.note,
        reviewed_by = auth.uid(), reviewed_at = now()
  returning * into r;
  return to_jsonb(r);
end $$;

-- مسح تسجيل (يعود اليوم لوضعه الافتراضي: غائب تلقائياً إن انتهى الوقت)
create or replace function public.att_clear(p_uid uuid, p_day date) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.teaches_student(p_uid) then raise exception 'ليست لديك صلاحية على هذا الطالب'; end if;
  delete from public.attendance_records where attendance_records.uid = p_uid and attendance_records.day = p_day;
end $$;

-- موافقة/رفض الأستاذ على تسجيل حضور أرسله الطالب
create or replace function public.att_review(p_id uuid, p_decision text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r public.attendance_records;
begin
  if p_decision not in ('approved', 'rejected') then raise exception 'قرار غير صالح'; end if;
  select * into r from public.attendance_records where id = p_id;
  if r.id is null then raise exception 'التسجيل غير موجود'; end if;
  if not public.teaches_class(r.class_id) then raise exception 'ليست لديك صلاحية على هذا الصف'; end if;
  if r.approval <> 'pending' then raise exception 'تمت مراجعة هذا التسجيل مسبقاً'; end if;
  update public.attendance_records set approval = p_decision, reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_id returning * into r;
  return to_jsonb(r);
end $$;

-- الطالب يرسل تقرير غياب بعذر
create or replace function public.att_report(p_from date, p_to date, p_kind text, p_note text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_class text; v_tz text; v_today date; rp public.absence_reports;
begin
  if auth.uid() is null or not public.is_approved() then raise exception 'حسابك غير مفعّل'; end if;
  v_class := public.my_class_id();
  if v_class is null then raise exception 'حسابك غير مرتبط بصف معتمد'; end if;
  if p_kind not in ('sick', 'family', 'emergency', 'transport', 'other') then raise exception 'اختر سبب الغياب'; end if;
  select tz into v_tz from public.classes where id = v_class;
  v_today := (now() at time zone v_tz)::date;
  if p_from is null or p_to is null or p_to < p_from then raise exception 'تاريخ غير صالح'; end if;
  if p_to - p_from > 13 then raise exception 'الحد الأقصى للتقرير الواحد 14 يوماً'; end if;
  if p_from < v_today - 14 then raise exception 'لا يمكن إرسال تقرير لأيام أقدم من 14 يوماً'; end if;
  if p_to > v_today + 30 then raise exception 'لا يمكن إرسال تقرير لأكثر من 30 يوماً قادمة'; end if;
  if p_kind = 'other' and char_length(trim(coalesce(p_note, ''))) < 3 then raise exception 'اكتب سبب الغياب'; end if;
  if (select count(*) from public.absence_reports x where x.uid = auth.uid() and x.status = 'pending') >= 10 then
    raise exception 'لديك تقارير كثيرة بانتظار الأستاذ';
  end if;
  insert into public.absence_reports (class_id, uid, day_from, day_to, kind, note)
  values (v_class, auth.uid(), p_from, p_to, p_kind, left(coalesce(p_note, ''), 500))
  returning * into rp;
  return to_jsonb(rp);
end $$;

-- الأستاذ يوافق/يرفض تقرير الغياب. الموافقة تحوّل أيام الدوام في الفترة إلى «غياب بعذر».
create or replace function public.att_report_review(p_id uuid, p_decision text, p_note text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare rp public.absence_reports; d date; w record;
begin
  if p_decision not in ('approved', 'rejected') then raise exception 'قرار غير صالح'; end if;
  select * into rp from public.absence_reports where id = p_id;
  if rp.id is null then raise exception 'التقرير غير موجود'; end if;
  if not public.teaches_class(rp.class_id) then raise exception 'ليست لديك صلاحية على هذا الصف'; end if;
  if rp.status <> 'pending' then raise exception 'تمت مراجعة هذا التقرير مسبقاً'; end if;
  update public.absence_reports
     set status = p_decision, teacher_note = left(coalesce(p_note, ''), 300), reviewed_by = auth.uid(), reviewed_at = now()
   where id = p_id returning * into rp;

  if p_decision = 'approved' then
    for d in select g::date from generate_series(rp.day_from::timestamp, rp.day_to::timestamp, interval '1 day') g loop
      select * into w from public.att_window(rp.class_id, d);
      if w.school_day then
        insert into public.attendance_records as ar (class_id, uid, day, status, approval, source, note, at, reviewed_by, reviewed_at)
        values (rp.class_id, rp.uid, d, 'excused', 'approved', 'report', left(rp.note, 300), now(), auth.uid(), now())
        on conflict (uid, day) do update
          set status = 'excused', approval = 'approved', source = 'report', note = excluded.note,
              reviewed_by = auth.uid(), reviewed_at = now()
          where not (ar.approval in ('approved', 'pending') and ar.status in ('present', 'late'));
      end if;
    end loop;
  end if;
  return to_jsonb(rp);
end $$;

-- الأستاذ يوافق/يرفض طلب إنشاء حساب طالب في صفه
create or replace function public.reg_review(p_uid uuid, p_decision text, p_note text default '') returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_decision not in ('approved', 'rejected') then raise exception 'قرار غير صالح'; end if;
  if not public.teaches_student(p_uid) then raise exception 'ليست لديك صلاحية على هذا الطالب'; end if;
  update public.student_info
     set reg_status = p_decision, reg_note = left(coalesce(p_note, ''), 300),
         reviewed_by = auth.uid(), reviewed_at = now(),
         approved_at = case when p_decision = 'approved' then now() else approved_at end
   where uid = p_uid and reg_status in ('pending', 'rejected');
  if not found then raise exception 'تمت مراجعة هذا الطلب مسبقاً'; end if;
end $$;

-- توقيت الحضور الافتراضي للصف
create or replace function public.att_save_schedule(p_class text, p_open time, p_close time, p_late time, p_days int[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.teaches_class(p_class) then raise exception 'ليست لديك صلاحية على هذا الصف'; end if;
  if p_open is null or p_close is null or p_open >= p_close then raise exception 'وقت البداية يجب أن يسبق وقت النهاية'; end if;
  if p_late is not null and (p_late <= p_open or p_late > p_close) then raise exception 'وقت التأخير يجب أن يقع داخل فترة التسجيل'; end if;
  if p_days is null or cardinality(p_days) < 1 or not (p_days <@ array[0, 1, 2, 3, 4, 5, 6]) then raise exception 'اختر يوم دوام واحداً على الأقل'; end if;
  update public.classes
     set att_open = p_open, att_close = p_close, att_late = p_late,
         att_days = (select array_agg(distinct x order by x) from unnest(p_days) x)
   where id = p_class;
end $$;

-- استثناء ليوم محدد: عطلة أو توقيت مختلف
create or replace function public.att_set_day(p_class text, p_day date, p_off boolean, p_open time, p_close time, p_late time) returns void
language plpgsql security definer set search_path = public as $$
declare c public.classes; v_open time; v_close time;
begin
  if not public.teaches_class(p_class) then raise exception 'ليست لديك صلاحية على هذا الصف'; end if;
  select * into c from public.classes where id = p_class;
  if p_day < (now() at time zone c.tz)::date - 365 then raise exception 'تاريخ قديم جداً'; end if;
  if not coalesce(p_off, false) then
    v_open := coalesce(p_open, c.att_open); v_close := coalesce(p_close, c.att_close);
    if v_open >= v_close then raise exception 'وقت البداية يجب أن يسبق وقت النهاية'; end if;
    if p_late is not null and (p_late <= v_open or p_late > v_close) then raise exception 'وقت التأخير يجب أن يقع داخل فترة التسجيل'; end if;
  end if;
  insert into public.attendance_days (class_id, day, is_off, open_t, close_t, late_t)
  values (p_class, p_day, coalesce(p_off, false), p_open, p_close, p_late)
  on conflict (class_id, day) do update
    set is_off = excluded.is_off, open_t = excluded.open_t, close_t = excluded.close_t, late_t = excluded.late_t;
end $$;

create or replace function public.att_del_day(p_class text, p_day date) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.teaches_class(p_class) then raise exception 'ليست لديك صلاحية على هذا الصف'; end if;
  delete from public.attendance_days where class_id = p_class and day = p_day;
end $$;

-- ---------- 6) الصلاحيات (RLS): القراءة فقط مباشرةً، والكتابة عبر الدوال ----------
alter table public.classes            enable row level security;
alter table public.student_info       enable row level security;
alter table public.attendance_days    enable row level security;
alter table public.attendance_records enable row level security;
alter table public.absence_reports    enable row level security;

revoke all on public.classes, public.student_info, public.attendance_days,
  public.attendance_records, public.absence_reports from anon, authenticated;
grant select on public.classes, public.student_info, public.attendance_days,
  public.attendance_records, public.absence_reports to authenticated;

drop policy if exists "classes read" on public.classes;
create policy "classes read" on public.classes for select to authenticated using (true);

drop policy if exists "student_info read" on public.student_info;
create policy "student_info read" on public.student_info for select to authenticated
  using (uid = auth.uid() or public.teaches_class(class_id));

drop policy if exists "attendance_days read" on public.attendance_days;
create policy "attendance_days read" on public.attendance_days for select to authenticated
  using (public.teaches_class(class_id) or (public.is_approved() and class_id = public.my_class_id()));

drop policy if exists "attendance_records read" on public.attendance_records;
create policy "attendance_records read" on public.attendance_records for select to authenticated
  using (uid = auth.uid() or public.teaches_class(class_id));

drop policy if exists "absence_reports read" on public.absence_reports;
create policy "absence_reports read" on public.absence_reports for select to authenticated
  using (uid = auth.uid() or public.teaches_class(class_id));

-- الدوال: للمسجّلين فقط (لا للزوار)، والدوال الداخلية مغلقة
do $$
declare f text;
begin
  foreach f in array array[
    'public.my_username()', 'public.teaches_class(text)', 'public.teaches_student(uuid)',
    'public.is_approved()', 'public.my_class_id()',
    'public.att_sheet(text,date,date)', 'public.att_mine(date,date)', 'public.att_today()',
    'public.att_class_today(text)', 'public.att_check_in(text)', 'public.att_set(uuid,date,text,text)',
    'public.att_clear(uuid,date)', 'public.att_review(uuid,text)', 'public.att_report(date,date,text,text)',
    'public.att_report_review(uuid,text,text)', 'public.reg_review(uuid,text,text)',
    'public.att_save_schedule(text,time,time,time,int[])', 'public.att_set_day(text,date,boolean,time,time,time)',
    'public.att_del_day(text,date)'
  ] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
  execute 'revoke all on function public.att_window(text,date) from public, anon, authenticated';
  execute 'revoke all on function public.att_sheet_core(text,uuid,date,date) from public, anon, authenticated';
end $$;

-- ---------- 7) إغلاق الباب على الطالب غير المعتمد في بقية المنصة ----------
drop policy if exists "profiles read" on public.profiles;
create policy "profiles read" on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_approved());

drop policy if exists "cards read" on public.cards;
create policy "cards read" on public.cards for select to authenticated using (public.is_approved());

drop policy if exists "assignments read" on public.assignments;
create policy "assignments read" on public.assignments for select to authenticated
  using (public.is_teacher() or (public.is_approved() and pub <= now()));

drop policy if exists "messages read" on public.messages;
create policy "messages read" on public.messages for select to authenticated using (public.is_approved());

drop policy if exists "meetings read" on public.meetings;
create policy "meetings read" on public.meetings for select to authenticated using (public.is_approved());

drop policy if exists "alx realtime read" on realtime.messages;
create policy "alx realtime read" on realtime.messages for select to authenticated using (public.is_approved());

-- ---------- 8) الوقت الحقيقي ----------
do $$
declare t text;
begin
  foreach t in array array['classes', 'student_info', 'attendance_days', 'attendance_records', 'absence_reports'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;
    end;
  end loop;
end $$;

-- =====================================================================
--  أوامر مفيدة لاحقاً (شغّلها عند الحاجة فقط):
--  جعل حساب أستاذاً:   update public.profiles set role = 'teacher' where username = 'اسم_المستخدم';
--  إرجاعه طالباً:      update public.profiles set role = 'student' where username = 'اسم_المستخدم';
-- =====================================================================
