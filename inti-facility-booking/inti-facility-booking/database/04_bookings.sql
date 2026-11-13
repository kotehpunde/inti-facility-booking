-- =====================================================================
--  bookings.sql — run in Supabase → SQL Editor
--  (after schema.sql, auth_v2.sql and facilities.sql)
--
--  Creates:
--    facility_units   which rooms/tables exist (Music Studio, Table 1-2, Room 1-6)
--    bookings         one row per booked 1-hour slot
--    enforce_two_hour_daily_limit()  trigger: max 2 h/day for music + library
--    RPCs the app calls:
--      get_slot_availability  booked hours for a unit + date (no names shown)
--      create_booking         books 1-2 back-to-back slots, first come first served
--      cancel_booking         cancels the student's own future booking
--      get_hourly_busyness    booking counts per hour, for the "Popular times" chart
--
--  Security: this app logs in with its own session tokens, not Supabase Auth,
--  so an RLS policy cannot tell which student is calling. The app therefore
--  gets NO direct access to `bookings`; every read/write goes through the
--  SECURITY DEFINER functions below, which check the session token first.
--
--  Safe to re-run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Bookable units of each facility
-- ---------------------------------------------------------------------
create table if not exists public.facility_units (
    facility_type text    not null check (facility_type in ('music', 'pool', 'library')),
    unit_name     text    not null,
    capacity      int,                         -- max people; null = open capacity
    sort_order    int     not null default 0,
    is_active     boolean not null default true,
    primary key (facility_type, unit_name)
);

insert into public.facility_units (facility_type, unit_name, capacity, sort_order) values
    ('music',   'Music Studio', null, 1),
    ('pool',    'Table 1',      4,    1),
    ('pool',    'Table 2',      4,    2),
    ('library', 'Room 1',       4,    1),
    ('library', 'Room 2',       4,    2),
    ('library', 'Room 3',       4,    3),
    ('library', 'Room 4',       4,    4),
    ('library', 'Room 5',       6,    5),
    ('library', 'Room 6',       6,    6)
on conflict (facility_type, unit_name) do update
    set capacity = excluded.capacity, sort_order = excluded.sort_order;

-- ---------------------------------------------------------------------
-- 2. Bookings: one row = one 1-hour slot
--    A 2-hour booking is 2 rows that share the same booking_ref.
-- ---------------------------------------------------------------------
create table if not exists public.bookings (
    id            uuid        primary key default gen_random_uuid(),
    booking_ref   uuid        not null default gen_random_uuid(),
    user_id       uuid        not null references public.users (id) on delete cascade,
    facility_type text        not null check (facility_type in ('music', 'pool', 'library')),
    unit_name     text        not null,
    booking_date  date        not null,
    start_time    time        not null,
    end_time      time        not null,
    status        text        not null default 'confirmed'
                  check (status in ('confirmed', 'cancelled')),
    created_at    timestamptz not null default now(),
    cancelled_at  timestamptz,

    foreign key (facility_type, unit_name)
        references public.facility_units (facility_type, unit_name),

    -- Slots are exactly 1 hour, on the hour, inside 08:00-18:00.
    constraint bookings_one_hour_slot
        check (end_time = start_time + interval '1 hour'),
    constraint bookings_on_the_hour
        check (extract(minute from start_time) = 0 and extract(second from start_time) = 0),
    constraint bookings_operating_hours
        check (start_time >= time '08:00' and end_time <= time '18:00')
);

-- No double bookings: one CONFIRMED booking per unit + date + start time.
-- (A partial unique index, so a cancelled slot can be booked again.
--  A plain UNIQUE(...) constraint would block the slot forever after a cancel.)
create unique index if not exists bookings_no_double_booking
    on public.bookings (facility_type, unit_name, booking_date, start_time)
    where status = 'confirmed';

create index if not exists bookings_user_day_idx
    on public.bookings (user_id, booking_date);
create index if not exists bookings_facility_day_idx
    on public.bookings (facility_type, booking_date);

-- ---------------------------------------------------------------------
-- 3. Trigger: max 2 hours per student per day (music + library only)
-- ---------------------------------------------------------------------
create or replace function public.enforce_two_hour_daily_limit()
returns trigger
language plpgsql
set search_path = public
as $$
declare
    v_existing_minutes int;
    v_new_minutes      int;
begin
    -- Pool tables have no daily limit; cancelled rows never count.
    if new.status <> 'confirmed' or new.facility_type not in ('music', 'library') then
        return new;
    end if;

    -- Lock per student + facility + day so two simultaneous requests
    -- can't both squeeze under the limit.
    perform pg_advisory_xact_lock(
        hashtext(new.user_id::text || ':' || new.facility_type || ':' || new.booking_date::text)
    );

    select coalesce(sum(extract(epoch from (end_time - start_time)) / 60), 0)::int
      into v_existing_minutes
      from public.bookings
     where user_id = new.user_id
       and facility_type = new.facility_type
       and booking_date = new.booking_date
       and status = 'confirmed'
       and id <> new.id;

    v_new_minutes := (extract(epoch from (new.end_time - new.start_time)) / 60)::int;

    if v_existing_minutes + v_new_minutes > 120 then
        raise exception 'Maximum booking limit for this facility is 2 hours per day.'
            using errcode = 'INT20';
    end if;

    return new;
end;
$$;

drop trigger if exists bookings_two_hour_daily_limit on public.bookings;
create trigger bookings_two_hour_daily_limit
    before insert or update of status on public.bookings
    for each row execute function public.enforce_two_hour_daily_limit();

-- ---------------------------------------------------------------------
-- 4. Lock the tables down (see Security note at the top)
-- ---------------------------------------------------------------------
alter table public.facility_units enable row level security;
alter table public.bookings       enable row level security;

-- Unit list is public information: read-only for the app.
drop policy if exists "App can view active units" on public.facility_units;
create policy "App can view active units"
    on public.facility_units for select
    to anon, authenticated
    using (is_active);

revoke all on public.facility_units, public.bookings from anon, authenticated;
grant select on public.facility_units to anon, authenticated;
-- bookings: no policies and no grants → only the functions below can touch it.

-- ---------------------------------------------------------------------
-- 5. RPC: get_slot_availability  (POST /rest/v1/rpc/get_slot_availability)
--    Returns which hours are taken, which of those are the caller's own,
--    and how many hours the caller already has that day for this facility.
-- ---------------------------------------------------------------------
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
               and status = 'confirmed'), '[]'::json),
        'mine', coalesce((
            select json_agg(extract(hour from start_time)::int order by start_time)
              from public.bookings
             where facility_type = p_facility_type
               and unit_name = p_unit_name
               and booking_date = p_date
               and status = 'confirmed'
               and user_id = v_user.id), '[]'::json),
        'my_hours_today', (
            select count(*)::int
              from public.bookings
             where facility_type = p_facility_type
               and booking_date = p_date
               and status = 'confirmed'
               and user_id = v_user.id)
    );
end;
$$;

-- ---------------------------------------------------------------------
-- 6. RPC: create_booking  (POST /rest/v1/rpc/create_booking)
--    p_start_hours: e.g. {10} or {10,11} (back-to-back only).
--    Error codes the app understands:
--      INT20 daily 2-hour limit   INT21 slot just taken
--      INT22 invalid date/time    INT23 unknown unit   28000 session expired
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

    -- First come, first served: the unique index rejects a slot someone
    -- else confirmed a moment earlier. The trigger checks the 2-hour limit.
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
-- 7. RPC: cancel_booking  (used by "My Bookings" in a later task)
-- ---------------------------------------------------------------------
create or replace function public.cancel_booking(p_token text, p_booking_ref uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_user  public.users := public.app_require_role(p_token, null);
    v_now   timestamp    := now() at time zone 'Asia/Kuala_Lumpur';
    v_count int;
begin
    update public.bookings
       set status = 'cancelled', cancelled_at = now()
     where booking_ref = p_booking_ref
       and user_id = v_user.id
       and status = 'confirmed'
       and (booking_date + start_time) > v_now;   -- only slots that haven't started

    get diagnostics v_count = row_count;
    if v_count = 0 then
        raise exception 'This booking can no longer be cancelled.' using errcode = 'INT24';
    end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 8. RPC: get_hourly_busyness  (no login needed: counts only, no names)
--    Confirmed bookings per start hour over the last 8 weeks, 08:00-17:00.
-- ---------------------------------------------------------------------
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
             and status = 'confirmed'
             and booking_date >= (now() at time zone 'Asia/Kuala_Lumpur')::date - 56
           group by 1
      ) c on c.hr = h.hour;
$$;

-- ---------------------------------------------------------------------
-- 9. Function permissions
-- ---------------------------------------------------------------------
revoke execute on function public.enforce_two_hour_daily_limit()                  from public, anon, authenticated;
revoke execute on function public.get_slot_availability(text, text, text, date)   from public, anon, authenticated;
revoke execute on function public.create_booking(text, text, text, date, int[])   from public, anon, authenticated;
revoke execute on function public.cancel_booking(text, uuid)                      from public, anon, authenticated;
revoke execute on function public.get_hourly_busyness(text)                       from public, anon, authenticated;

grant execute on function public.get_slot_availability(text, text, text, date)    to anon;
grant execute on function public.create_booking(text, text, text, date, int[])    to anon;
grant execute on function public.cancel_booking(text, uuid)                       to anon;
grant execute on function public.get_hourly_busyness(text)                        to anon;

notify pgrst, 'reload schema';

-- ---------------------------------------------------------------------
-- Quick test in the SQL Editor (optional): should list 10 zeros at first.
--   select public.get_hourly_busyness('music');
-- ---------------------------------------------------------------------
