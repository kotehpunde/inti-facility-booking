-- =====================================================================
--  facilities.sql — run in Supabase → SQL Editor (after schema.sql)
--
--  Campus facilities shown on the "Select a Facility" screen.
--  Facility info is public, so the app's anon key may READ active rows.
--  Nobody can insert/update/delete from the app; admin tools come later.
--  Safe to re-run: existing rows are updated, not duplicated.
-- =====================================================================

create table if not exists public.facilities (
    id            text        primary key check (id ~ '^[a-z0-9_]+$'),  -- e.g. music_room
    name          text        not null,
    caption       text        not null default '',          -- one-liner for the dashboard carousel
    tags          text[]      not null default '{}',        -- e.g. {Level 1, Open Capacity}
    status_label  text        not null default 'Open for Booking',
    status_tone   text        not null default 'success'
                  check (status_tone in ('success', 'info', 'quiet')),
    icon_key      text        not null default 'room'
                  check (icon_key in ('music', 'pool', 'library', 'room')),
    image_url     text,                                     -- optional banner photo (e.g. Supabase Storage)
    sort_order    int         not null default 0,
    is_active     boolean     not null default true,
    created_at    timestamptz not null default now()
);

insert into public.facilities
    (id, name, caption, tags, status_label, status_tone, icon_key, sort_order)
values
    ('music_room', 'Music Room',
     'Music Room: Acoustic studio open to all students',
     array['Level 1', 'Open Capacity', 'Acoustic Studio'],
     'Open for Booking', 'success', 'music', 1),
    ('pool_table', 'Pool Tables',
     'Recreation Corner: Unwind with a game between classes',
     array['Level 2', '2 Tables Available', 'Max 4 Pax/Table'],
     '2 Tables On-Site', 'info', 'pool', 2),
    ('library_room', 'Library Discussion Rooms',
     'Discussion Rooms: Quiet study spaces available',
     array['Level 6', '6 Study Rooms', 'Rooms 1–4: 4 Pax', 'Rooms 5–6: 6 Pax'],
     'Quiet Study Zone', 'quiet', 'library', 3)
on conflict (id) do update set
    name = excluded.name,
    caption = excluded.caption,
    tags = excluded.tags,
    status_label = excluded.status_label,
    status_tone = excluded.status_tone,
    icon_key = excluded.icon_key,
    sort_order = excluded.sort_order;

-- Row Level Security: read-only for the app, active facilities only.
alter table public.facilities enable row level security;

drop policy if exists "App can view active facilities" on public.facilities;
create policy "App can view active facilities"
    on public.facilities
    for select
    to anon, authenticated
    using (is_active);

revoke all on public.facilities from anon, authenticated;
grant select on public.facilities to anon, authenticated;

notify pgrst, 'reload schema';
