-- =====================================================================
--  admin_enhancements.sql — run in Supabase → SQL Editor
--  (after ALL the earlier files, admin_suite.sql last)
--
--  Adds three admin features:
--    1. Student Directory & Account Suspension
--    2. Counter Check-In ("Hand over keys") & No-Show slot release
--    3. Facility Utilization Analytics (last 30 days)
--
--  Booking statuses after this file:
--    confirmed        booked, student not here yet        → slot TAKEN
--    checked_in       admin handed over keys / equipment  → slot TAKEN
--    no_show          admin released it (student absent)  → slot FREE
--    cancelled        student cancelled                   → slot FREE
--    admin_cancelled  admin force-cancelled               → slot FREE
--
--  Because 'checked_in' is also an active booking, every function that
--  looked for status = 'confirmed' to find taken slots is re-created here
--  to look for status in ('confirmed', 'checked_in').
--
--  New error codes:
--    INT13  account suspended (login + create_booking)
--    INT60  check-in not allowed right now (wrong day / too early / ended)
--    INT61  booking not found, or not in 'confirmed' state any more
--    INT62  no-show release not allowed right now
--    INT63  student account not found
--
--  Safe to re-run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Schema changes
-- ---------------------------------------------------------------------
alter table public.users
    add column if not exists is_suspended boolean not null default false;

alter table public.bookings drop constraint if exists bookings_status_check;
alter table public.bookings
    add constraint bookings_status_check
    check (status in ('confirmed', 'cancelled', 'admin_cancelled', 'checked_in', 'no_show'));

alter table public.bookings add column if not exists checked_in_at timestamptz;

-- No double bookings: a slot is taken while it is confirmed OR checked in.
-- A no-show / cancelled slot drops out of the index, so it can be re-booked.
drop index if exists public.bookings_no_double_booking;
create unique index bookings_no_double_booking
    on public.bookings (facility_type, unit_name, booking_date, start_time)
    where status in ('confirmed', 'checked_in');

-- ---------------------------------------------------------------------
-- 2a. login — now refuses suspended accounts (INT13)
--     (Checked AFTER the password, so a wrong password never reveals
--      whether an account is suspended.)
-- ---------------------------------------------------------------------
create or replace function public.login(p_identifier text, p_password text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_ident text := trim(coalesce(p_identifier, ''));
    v_user  public.users;
    v_token text;
begin
    select * into v_user
    from public.users
    where lower(email) = lower(v_ident)
       or student_id   = upper(v_ident)
    limit 1;

    if v_user.id is null then
        raise exception 'Account does not exist.' using errcode = 'INT10';
    end if;

    if v_user.password_hash <> crypt(coalesce(p_password, ''), v_user.password_hash) then
        raise exception 'Incorrect password.' using errcode = 'INT11';
    end if;

    if v_user.role = 'student' and not exists (
        select 1 from public.inti_roster r
        where r.student_id = v_user.student_id and r.is_active
    ) then
        raise exception 'This student record is no longer active.' using errcode = 'INT12';
    end if;

    if v_user.is_suspended then
        raise exception 'Account has been suspended by campus administration. Please visit the admin counter.'
            using errcode = 'INT13';
    end if;

    delete from public.user_sessions where user_id = v_user.id and expires_at <= now();

    v_token := encode(gen_random_bytes(32), 'hex');
    insert into public.user_sessions (token_hash, user_id)
    values (encode(digest(v_token, 'sha256'), 'hex'), v_user.id);

    return json_build_object(
        'token', v_token,
        'expires_at', now() + interval '7 days',
        'user', json_build_object(
            'id', v_user.id, 'student_id', v_user.student_id, 'name', v_user.name,
            'display_name', v_user.display_name,
            'email', v_user.email, 'role', v_user.role, 'created_at', v_user.created_at
        )
    );
end;
$$;

-- ---------------------------------------------------------------------
-- 2b. create_booking — now refuses suspended accounts (INT13)
-- ---------------------------------------------------------------------
create or replace function public.create_booking(
    p_token         text,
    p_facility_type text,
    p_unit_name     text,
    p_date          date,
    p_start_hours   int[]
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_user  public.users;
    v_now   timestamp := now() at time zone 'Asia/Kuala_Lumpur';  -- campus clock
    v_today date      := (now() at time zone 'Asia/Kuala_Lumpur')::date;
    v_hours int[];
    v_count int;
    v_ref   uuid      := gen_random_uuid();
    v_h     int;
begin
    v_user := public.app_require_role(p_token, 'student');

    if v_user.is_suspended then
        raise exception 'Account has been suspended by campus administration. Please visit the admin counter.'
            using errcode = 'INT13';
    end if;

    if not exists (
        select 1 from public.facility_units
         where facility_type = p_facility_type
           and unit_name = p_unit_name
           and is_active
    ) then
        raise exception 'That room or table is not available.' using errcode = 'INT23';
    end if;

    select array_agg(distinct h order by h) into v_hours from unnest(p_start_hours) as h;
    v_count := coalesce(array_length(v_hours, 1), 0);

    if v_count = 0 then
        raise exception 'Please choose a time slot.' using errcode = 'INT22';
    end if;
    if p_facility_type = 'pool' and v_count > 1 then
        raise exception 'Pool tables are booked one hour at a time.' using errcode = 'INT22';
    end if;
    if v_count > 2 then
        raise exception 'Maximum booking limit for this facility is 2 hours per day.'
            using errcode = 'INT20';
    end if;
    if v_count = 2 and v_hours[2] <> v_hours[1] + 1 then
        raise exception 'Please choose back-to-back time slots.' using errcode = 'INT22';
    end if;
    if v_hours[1] < 8 or v_hours[v_count] > 17 then
        raise exception 'Facilities operate 8:00 AM – 6:00 PM.' using errcode = 'INT22';
    end if;
    if p_date < v_today or p_date > v_today + 14 then
        raise exception 'You can book from today up to 14 days ahead.' using errcode = 'INT22';
    end if;
    if p_date = v_today and v_hours[1] <= extract(hour from v_now) then
        raise exception 'That time slot has already started. Please pick a later one.'
            using errcode = 'INT22';
    end if;

    begin
        foreach v_h in array v_hours loop
            insert into public.bookings
                (booking_ref, user_id, facility_type, unit_name, booking_date, start_time, end_time)
            values
                (v_ref, v_user.id, p_facility_type, p_unit_name, p_date,
                 make_time(v_h, 0, 0), make_time(v_h + 1, 0, 0));
        end loop;
    exception when unique_violation then
        raise exception 'Sorry, that slot was just booked by someone else. Please pick another time.'
            using errcode = 'INT21';
    end;

    return json_build_object(
        'booking_ref',   v_ref,
        'facility_type', p_facility_type,
        'unit_name',     p_unit_name,
        'booking_date',  p_date,
        'start_hour',    v_hours[1],
        'end_hour',      v_hours[v_count] + 1
    );
end;
$$;

-- ---------------------------------------------------------------------
-- 2c. Existing functions: treat 'checked_in' as an active booking
-- ---------------------------------------------------------------------

-- 2-hour daily limit: checked-in hours still count towards the limit.
create or replace function public.enforce_two_hour_daily_limit()
returns trigger
language plpgsql
set search_path = public
as $$
declare
    v_existing_minutes int;
    v_new_minutes      int;
begin
    -- Only new / re-confirmed bookings are checked. Check-in, no-show and
    -- cancel updates never add hours, so they skip the check.
    if new.status <> 'confirmed' or new.facility_type not in ('music', 'library') then
        return new;
    end if;

    perform pg_advisory_xact_lock(
        hashtext(new.user_id::text || ':' || new.facility_type || ':' || new.booking_date::text)
    );

    select coalesce(sum(extract(epoch from (end_time - start_time)) / 60), 0)::int
      into v_existing_minutes
      from public.bookings
     where user_id = new.user_id
       and facility_type = new.facility_type
       and booking_date = new.booking_date
       and status in ('confirmed', 'checked_in')
       and id <> new.id;

    v_new_minutes := (extract(epoch from (new.end_time - new.start_time)) / 60)::int;

    if v_existing_minutes + v_new_minutes > 120 then
        raise exception 'Maximum booking limit for this facility is 2 hours per day.'
            using errcode = 'INT20';
    end if;

    return new;
end;
$$;

-- Slot picker: checked-in slots are still taken.
create or replace function public.get_slot_availability(
    p_token         text,
    p_facility_type text,
    p_unit_name     text,
    p_date          date
)
returns json
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
    v_user public.users := public.app_require_role(p_token, null);
begin
    return json_build_object(
        'booked', coalesce((
            select json_agg(extract(hour from start_time)::int order by start_time)
              from public.bookings
             where facility_type = p_facility_type
               and unit_name = p_unit_name
               and booking_date = p_date
               and status in ('confirmed', 'checked_in')), '[]'::json),
        'mine', coalesce((
            select json_agg(extract(hour from start_time)::int order by start_time)
              from public.bookings
             where facility_type = p_facility_type
               and unit_name = p_unit_name
               and booking_date = p_date
               and status in ('confirmed', 'checked_in')
               and user_id = v_user.id), '[]'::json),
        'my_hours_today', (
            select count(*)::int
              from public.bookings
             where facility_type = p_facility_type
               and booking_date = p_date
               and status in ('confirmed', 'checked_in')
               and user_id = v_user.id)
    );
end;
$$;

-- "Popular times" chart.
create or replace function public.get_hourly_busyness(p_facility_type text)
returns json
language sql
stable
security definer
set search_path = public
as $$
    select json_agg(coalesce(c.n, 0) order by h.hour)
      from generate_series(8, 17) as h(hour)
      left join (
          select extract(hour from start_time)::int as hr, count(*)::int as n
            from public.bookings
           where facility_type = p_facility_type
             and status in ('confirmed', 'checked_in')
             and booking_date >= (now() at time zone 'Asia/Kuala_Lumpur')::date - 56
           group by 1
      ) c on c.hr = h.hour;
$$;

-- My Bookings: checked in = still a normal booking for the student;
-- a released no-show shows as cancelled (its reminder is removed).
create or replace function public.get_my_bookings(p_token text)
returns json
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
    v_user public.users := public.app_require_role(p_token, null);
begin
    return coalesce((
        select json_agg(t order by t.booking_date desc, t.start_hour desc)
          from (
              select booking_ref,
                     facility_type,
                     unit_name,
                     booking_date,
                     min(extract(hour from start_time))::int as start_hour,
                     max(extract(hour from end_time))::int   as end_hour,
                     case when bool_or(status in ('confirmed', 'checked_in'))
                          then 'confirmed' else 'cancelled' end as status,
                     min(created_at)                          as created_at
                from public.bookings
               where user_id = v_user.id
                 and booking_date >= (now() at time zone 'Asia/Kuala_Lumpur')::date - 60
               group by booking_ref, facility_type, unit_name, booking_date
          ) as t
    ), '[]'::json);
end;
$$;

-- Master Schedule (first names only).
create or replace function public.get_master_schedule(p_token text)
returns json
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
    v_user  public.users := public.app_require_role(p_token, null);
    v_today date         := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
    return coalesce((
        select json_agg(t order by t.booking_date, t.start_hour, t.facility_type, t.unit_name)
          from (
              select b.booking_ref,
                     b.facility_type,
                     b.unit_name,
                     b.booking_date,
                     min(extract(hour from b.start_time))::int as start_hour,
                     max(extract(hour from b.end_time))::int   as end_hour,
                     split_part(regexp_replace(trim(u.name), '\s+', ' ', 'g'), ' ', 1)
                                                               as first_name,
                     bool_or(b.user_id = v_user.id)            as is_mine
                from public.bookings b
                join public.users u on u.id = b.user_id
               where b.status in ('confirmed', 'checked_in')
                 and b.booking_date between v_today and v_today + 14
               group by b.booking_ref, b.facility_type, b.unit_name,
                        b.booking_date, u.name
          ) as t
    ), '[]'::json);
end;
$$;

-- Admin dashboard numbers.
create or replace function public.admin_dashboard_stats(p_token text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
    v_monday date;
begin
    perform public.app_require_role(p_token, 'admin');
    v_monday := v_today - (extract(isodow from v_today)::int - 1);

    return json_build_object(
        'today', v_today,
        'week_start', v_monday,
        'bookings_today', (
            select count(distinct booking_ref) from public.bookings
             where booking_date = v_today and status in ('confirmed', 'checked_in')),
        'pending_resets', (
            select count(*) from public.password_resets where status = 'pending'),
        'closed_facilities', (
            (select count(*) from public.facilities where not is_active)
          + (select count(*) from public.facility_units where not is_active)),
        'active_announcements', (
            select count(*) from public.announcements where is_active),
        'weekly', (
            select json_agg(coalesce(c.n, 0) order by d.day)
              from generate_series(v_monday, v_monday + 6, interval '1 day') as d(day)
              left join (
                  select booking_date, count(distinct booking_ref)::int as n
                    from public.bookings
                   where status in ('confirmed', 'checked_in')
                     and booking_date between v_monday and v_monday + 6
                   group by booking_date
              ) c on c.booking_date = d.day::date)
    );
end;
$$;

-- Admin bookings list.
--   today     all of today's bookings that are still on (confirmed /
--             checked in) or were released as a no-show today
--   upcoming  confirmed bookings after today
--   cancelled cancelled, force-cancelled and no-shows (last 30 days)
create or replace function public.admin_list_bookings(p_token text, p_scope text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_today date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
    perform public.app_require_role(p_token, 'admin');

    return coalesce((
        select json_agg(t order by t.booking_date, t.start_hour, t.facility_type, t.unit_name)
          from (
              select b.booking_ref, b.facility_type, b.unit_name, b.booking_date,
                     min(extract(hour from b.start_time))::int as start_hour,
                     max(extract(hour from b.end_time))::int   as end_hour,
                     max(b.status)                             as status,
                     max(b.cancel_reason)                      as cancel_reason,
                     max(b.checked_in_at)                      as checked_in_at,
                     u.name as full_name, u.student_id, u.email
                from public.bookings b
                join public.users u on u.id = b.user_id
               where case p_scope
                       when 'today'     then b.booking_date = v_today
                                         and b.status in ('confirmed', 'checked_in', 'no_show')
                       when 'upcoming'  then b.booking_date > v_today
                                         and b.status = 'confirmed'
                       when 'cancelled' then b.booking_date >= v_today - 30
                                         and b.status in ('cancelled', 'admin_cancelled', 'no_show')
                       else false
                     end
               group by b.booking_ref, b.facility_type, b.unit_name, b.booking_date,
                        u.name, u.student_id, u.email
          ) as t
    ), '[]'::json);
end;
$$;

-- ---------------------------------------------------------------------
-- 3a. Admin: student directory
--     p_search matches Student ID, name, nickname or email (any part).
-- ---------------------------------------------------------------------
create or replace function public.admin_list_students(p_token text, p_search text default null)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_q text := nullif(lower(trim(coalesce(p_search, ''))), '');
begin
    perform public.app_require_role(p_token, 'admin');

    return coalesce((
        select json_agg(t order by t.name)
          from (
              select u.id, u.student_id, u.name, u.display_name, u.email,
                     u.is_suspended, u.created_at,
                     (select count(distinct b.booking_ref)
                        from public.bookings b
                       where b.user_id = u.id)::int                       as booking_count,
                     (select count(distinct b.booking_ref)
                        from public.bookings b
                       where b.user_id = u.id and b.status = 'no_show')::int as no_show_count
                from public.users u
               where u.role = 'student'
                 -- strpos instead of LIKE, so typing % or _ is matched literally
                 and (v_q is null
                      or strpos(lower(coalesce(u.student_id, '')), v_q) > 0
                      or strpos(lower(u.name), v_q) > 0
                      or strpos(lower(coalesce(u.display_name, '')), v_q) > 0
                      or strpos(lower(u.email), v_q) > 0)
               order by u.name
               limit 200
          ) as t
    ), '[]'::json);
end;
$$;

-- ---------------------------------------------------------------------
-- 3b. Admin: suspend / unsuspend a student
--     Suspending deletes all of the student's sessions, so the app sends
--     them back to Login on their next action, and login then refuses
--     them (INT13). Their existing bookings are kept; cancel them in
--     Master Bookings if needed.
-- ---------------------------------------------------------------------
create or replace function public.admin_toggle_student_suspension(
    p_token   text,
    p_user_id uuid,
    p_suspend boolean
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_count int;
begin
    perform public.app_require_role(p_token, 'admin');

    update public.users
       set is_suspended = coalesce(p_suspend, false)
     where id = p_user_id
       and role = 'student';            -- admins can never be suspended here

    get diagnostics v_count = row_count;
    if v_count = 0 then
        raise exception 'Student account not found.' using errcode = 'INT63';
    end if;

    if p_suspend then
        delete from public.user_sessions where user_id = p_user_id;
    end if;

    return json_build_object('id', p_user_id, 'is_suspended', coalesce(p_suspend, false));
end;
$$;

-- ---------------------------------------------------------------------
-- 3c. Admin: verify check-in ("Hand over keys")
--     Allowed on the day of the booking, from 30 minutes before it
--     starts until it ends.
-- ---------------------------------------------------------------------
create or replace function public.admin_verify_check_in(p_token text, p_booking_ref uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_now   timestamp := now() at time zone 'Asia/Kuala_Lumpur';
    v_date  date;
    v_start timestamp;
    v_end   timestamp;
begin
    perform public.app_require_role(p_token, 'admin');

    select min(booking_date), min(booking_date + start_time), max(booking_date + end_time)
      into v_date, v_start, v_end
      from public.bookings
     where booking_ref = p_booking_ref
       and status = 'confirmed';

    if v_start is null then
        raise exception 'This booking was not found, or it is already checked in, released or cancelled.'
            using errcode = 'INT61';
    end if;
    if v_date <> v_now::date then
        raise exception 'Check-in is only possible on the day of the booking.'
            using errcode = 'INT60';
    end if;
    if v_now < v_start - interval '30 minutes' then
        raise exception 'Check-in opens at %, 30 minutes before the booking starts.',
            to_char(v_start - interval '30 minutes', 'FMHH12:MI AM')
            using errcode = 'INT60';
    end if;
    if v_now >= v_end then
        raise exception 'This booking has already ended.' using errcode = 'INT60';
    end if;

    update public.bookings
       set status = 'checked_in',
           checked_in_at = now()
     where booking_ref = p_booking_ref
       and status = 'confirmed';
end;
$$;

-- ---------------------------------------------------------------------
-- 3d. Admin: release a no-show
--     Allowed on the day of the booking, from 10 minutes after it starts
--     (a short grace period) until it ends. The slot is free again
--     immediately, because 'no_show' is not in the unique index.
-- ---------------------------------------------------------------------
create or replace function public.admin_release_no_show(p_token text, p_booking_ref uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_admin public.users := public.app_require_role(p_token, 'admin');
    v_grace interval     := interval '10 minutes';   -- change here if needed
    v_now   timestamp    := now() at time zone 'Asia/Kuala_Lumpur';
    v_date  date;
    v_start timestamp;
    v_end   timestamp;
begin
    select min(booking_date), min(booking_date + start_time), max(booking_date + end_time)
      into v_date, v_start, v_end
      from public.bookings
     where booking_ref = p_booking_ref
       and status = 'confirmed';

    if v_start is null then
        raise exception 'This booking was not found, or it is already checked in, released or cancelled.'
            using errcode = 'INT61';
    end if;
    if v_date <> v_now::date then
        raise exception 'No-shows can only be released on the day of the booking.'
            using errcode = 'INT62';
    end if;
    if v_now < v_start + v_grace then
        raise exception 'The student still has until % to arrive.',
            to_char(v_start + v_grace, 'FMHH12:MI AM')
            using errcode = 'INT62';
    end if;
    if v_now >= v_end then
        raise exception 'This booking has already ended, so there is no time left to release.'
            using errcode = 'INT62';
    end if;

    update public.bookings
       set status = 'no_show',
           cancelled_at = now(),
           cancelled_by = v_admin.id,
           cancel_reason = 'No-show: keys/equipment not claimed'
     where booking_ref = p_booking_ref
       and status = 'confirmed';
end;
$$;

-- ---------------------------------------------------------------------
-- 3e. Admin: facility utilization analytics (last 30 days, incl. today)
--     Counts booked HOURS (one row = one hour) that were confirmed or
--     checked in.
--       facilities       share of booked hours per facility (%)
--       top_unit         room/table with the most booked hours
--       peak_start_hour  start of the busiest 2-hour window (8–18)
--       no_show_count    bookings released as no-shows
-- ---------------------------------------------------------------------
create or replace function public.admin_facility_analytics(p_token text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_today      date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
    v_from       date;
    v_total      int;
    v_peak_start int;
begin
    perform public.app_require_role(p_token, 'admin');
    v_from := v_today - 29;

    select count(*)::int into v_total
      from public.bookings
     where booking_date between v_from and v_today
       and status in ('confirmed', 'checked_in');

    -- Busiest 2 back-to-back hours (ties → earliest).
    with hourly as (
        select h.hour, coalesce(c.n, 0) as n
          from generate_series(8, 17) as h(hour)
          left join (
              select extract(hour from start_time)::int as hr, count(*)::int as n
                from public.bookings
               where booking_date between v_from and v_today
                 and status in ('confirmed', 'checked_in')
               group by 1
          ) c on c.hr = h.hour
    )
    select a.hour into v_peak_start
      from hourly a
      join hourly b on b.hour = a.hour + 1
     order by a.n + b.n desc, a.hour
     limit 1;

    return json_build_object(
        'from', v_from,
        'to', v_today,
        'total_hours', v_total,
        'facilities', (
            select json_agg(json_build_object(
                       'facility_type', f.facility_type,
                       'hours', coalesce(c.n, 0),
                       'percent', case when v_total = 0 then 0
                                       else round(coalesce(c.n, 0) * 100.0 / v_total, 1) end)
                   order by f.ord)
              from (values ('music', 1), ('pool', 2), ('library', 3)) as f(facility_type, ord)
              left join (
                  select facility_type, count(*)::int as n
                    from public.bookings
                   where booking_date between v_from and v_today
                     and status in ('confirmed', 'checked_in')
                   group by facility_type
              ) c on c.facility_type = f.facility_type),
        'top_unit', (
            select json_build_object('facility_type', facility_type,
                                     'unit_name', unit_name,
                                     'hours', count(*))
              from public.bookings
             where booking_date between v_from and v_today
               and status in ('confirmed', 'checked_in')
             group by facility_type, unit_name
             order by count(*) desc, facility_type, unit_name
             limit 1),
        'peak_start_hour', case when v_total > 0 then v_peak_start end,
        'peak_end_hour',   case when v_total > 0 then v_peak_start + 2 end,
        'no_show_count', (
            select count(distinct booking_ref)::int
              from public.bookings
             where status = 'no_show'
               and booking_date between v_from and v_today)
    );
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Permissions (the anon key may CALL these; each checks the admin token)
--    Re-created functions above keep the permissions they already had.
-- ---------------------------------------------------------------------
revoke execute on function public.admin_list_students(text, text)                       from public, anon, authenticated;
revoke execute on function public.admin_toggle_student_suspension(text, uuid, boolean)  from public, anon, authenticated;
revoke execute on function public.admin_verify_check_in(text, uuid)                     from public, anon, authenticated;
revoke execute on function public.admin_release_no_show(text, uuid)                     from public, anon, authenticated;
revoke execute on function public.admin_facility_analytics(text)                        from public, anon, authenticated;

grant execute on function public.admin_list_students(text, text)                        to anon;
grant execute on function public.admin_toggle_student_suspension(text, uuid, boolean)   to anon;
grant execute on function public.admin_verify_check_in(text, uuid)                      to anon;
grant execute on function public.admin_release_no_show(text, uuid)                      to anon;
grant execute on function public.admin_facility_analytics(text)                         to anon;

notify pgrst, 'reload schema';
