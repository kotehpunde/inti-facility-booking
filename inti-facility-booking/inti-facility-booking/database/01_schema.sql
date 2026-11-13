-- =====================================================================
--  INTI Campus Facility Booking System — Supabase schema (Task 1)
--  Run the whole file once in Supabase Dashboard → SQL Editor.
--
--  Security model
--  ---------------
--  * The Android app only ever holds the public ANON key.
--  * The anon role gets NO direct access to any table (RLS on, no policies,
--    privileges revoked). password_hash can therefore never be read by the app.
--  * Everything goes through SECURITY DEFINER RPC functions:
--        rpc/register_student  -> validates against inti_roster, bcrypt-hashes
--        rpc/login             -> verifies bcrypt server-side, returns a session token
--        rpc/logout            -> revokes the session token
--  * RBAC: every future protected RPC calls app_require_role(token, 'admin'|'student')
--    so the role is enforced in the database, not trusted from the client.
-- =====================================================================

-- pgcrypto lives in the "extensions" schema on Supabase
create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- 1. Campus roster (mock records of real INTI students)
-- ---------------------------------------------------------------------
create table if not exists public.inti_roster (
    id          bigint generated always as identity primary key,
    student_id  varchar(9)   not null unique
                check (student_id ~ '^P[0-9]{8}$'),          -- e.g. P22014366
    full_name   text         not null,
    inti_email  text         not null unique
                check (inti_email ~* '^[a-z0-9._%+-]+@student\.newinti\.edu\.my$'),
    is_active   boolean      not null default true
);

insert into public.inti_roster (student_id, full_name, inti_email, is_active) values
    ('P22014366', 'Tan Wei Ming',        'p22014366@student.newinti.edu.my', true),
    ('P22015012', 'Nur Aisyah binti Rahman', 'p22015012@student.newinti.edu.my', true),
    ('P23010458', 'Rajesh a/l Kumar',    'p23010458@student.newinti.edu.my', true),
    ('P23011790', 'Lim Jia Hui',         'p23011790@student.newinti.edu.my', true),
    ('P21009933', 'Ahmad Faiz bin Ismail','p21009933@student.newinti.edu.my', false) -- inactive / graduated
on conflict (student_id) do nothing;

-- ---------------------------------------------------------------------
-- 2. Application accounts
-- ---------------------------------------------------------------------
create table if not exists public.users (
    id             uuid        primary key default gen_random_uuid(),
    student_id     varchar(9)  unique
                   references public.inti_roster (student_id) on update cascade,
    name           text        not null,
    email          text        not null unique,
    password_hash  text        not null,                    -- bcrypt ($2a$)
    role           text        not null default 'student'
                   check (role in ('student', 'admin')),
    created_at     timestamptz not null default now(),
    -- students must be linked to the roster; admins are staff and need not be
    constraint student_requires_roster
        check (role = 'admin' or student_id is not null)
);

create unique index if not exists users_email_lower_idx on public.users (lower(email));

-- ---------------------------------------------------------------------
-- 3. Sessions (opaque tokens; only the SHA-256 of the token is stored)
-- ---------------------------------------------------------------------
create table if not exists public.user_sessions (
    token_hash  text        primary key,
    user_id     uuid        not null references public.users (id) on delete cascade,
    created_at  timestamptz not null default now(),
    expires_at  timestamptz not null default now() + interval '7 days'
);

create index if not exists user_sessions_user_idx on public.user_sessions (user_id);

-- ---------------------------------------------------------------------
-- 4. Seed admin  (email: admin@newinti.edu.my  /  password: admin123)
--    CHANGE THIS PASSWORD before any demo / submission.
-- ---------------------------------------------------------------------
insert into public.users (student_id, name, email, password_hash, role)
values (
    null,
    'System Administrator',
    'admin@newinti.edu.my',
    extensions.crypt('admin123', extensions.gen_salt('bf', 10)),
    'admin'
)
on conflict (email) do nothing;

-- ---------------------------------------------------------------------
-- 5. Lock the tables down
-- ---------------------------------------------------------------------
alter table public.inti_roster   enable row level security;
alter table public.users         enable row level security;
alter table public.user_sessions enable row level security;
-- No policies are created on purpose: anon/authenticated get zero rows.

revoke all on public.inti_roster, public.users, public.user_sessions from anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. Internal helper: resolve a session token and enforce a role (RBAC)
--    Not callable from the app — used inside other RPCs.
-- ---------------------------------------------------------------------
create or replace function public.app_require_role(p_token text, p_role text default null)
returns public.users
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_user public.users;
begin
    select u.* into v_user
    from public.user_sessions s
    join public.users u on u.id = s.user_id
    where s.token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex')
      and s.expires_at > now();

    if v_user.id is null then
        raise exception 'Session expired or invalid' using errcode = '28000';
    end if;

    if p_role is not null and v_user.role <> p_role then
        raise exception 'Forbidden: % role required', p_role using errcode = '42501';
    end if;

    return v_user;
end;
$$;

-- ---------------------------------------------------------------------
-- 7. RPC: register_student  (POST /rest/v1/rpc/register_student)
-- ---------------------------------------------------------------------
create or replace function public.register_student(
    p_student_id text,
    p_email      text,
    p_password   text
)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_roster public.inti_roster;
    v_user   public.users;
begin
    select * into v_roster
    from public.inti_roster
    where student_id = upper(trim(p_student_id));

    if v_roster.id is null then
        raise exception 'Student ID not found in INTI records';
    end if;
    if not v_roster.is_active then
        raise exception 'Student record is inactive';
    end if;
    if lower(trim(p_email)) <> lower(v_roster.inti_email) then
        raise exception 'Email does not match INTI records for this Student ID';
    end if;
    if length(coalesce(p_password, '')) < 8 then
        raise exception 'Password must be at least 8 characters';
    end if;
    if exists (select 1 from public.users where student_id = v_roster.student_id) then
        raise exception 'An account already exists for this Student ID';
    end if;

    insert into public.users (student_id, name, email, password_hash, role)
    values (v_roster.student_id, v_roster.full_name, lower(v_roster.inti_email),
            crypt(p_password, gen_salt('bf', 10)), 'student')
    returning * into v_user;

    return json_build_object(
        'id', v_user.id, 'student_id', v_user.student_id, 'name', v_user.name,
        'email', v_user.email, 'role', v_user.role, 'created_at', v_user.created_at
    );
end;
$$;

-- ---------------------------------------------------------------------
-- 8. RPC: login  (POST /rest/v1/rpc/login)
--    Verifies bcrypt in Postgres; the hash never leaves the database.
-- ---------------------------------------------------------------------
create or replace function public.login(p_email text, p_password text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_user  public.users;
    v_token text;
begin
    select * into v_user
    from public.users
    where lower(email) = lower(trim(p_email));

    -- same message for "no such user" and "wrong password" (no user enumeration)
    if v_user.id is null
       or v_user.password_hash <> crypt(coalesce(p_password, ''), v_user.password_hash) then
        raise exception 'Invalid email or password' using errcode = '28P01';
    end if;

    -- students whose roster record was deactivated can no longer sign in
    if v_user.role = 'student' and not exists (
        select 1 from public.inti_roster r
        where r.student_id = v_user.student_id and r.is_active
    ) then
        raise exception 'Student record is inactive' using errcode = '28000';
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
            'email', v_user.email, 'role', v_user.role, 'created_at', v_user.created_at
        )
    );
end;
$$;

-- ---------------------------------------------------------------------
-- 9. RPC: logout  (POST /rest/v1/rpc/logout)
-- ---------------------------------------------------------------------
create or replace function public.logout(p_token text)
returns void
language sql
security definer
set search_path = public, extensions
as $$
    delete from public.user_sessions
    where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex');
$$;

-- ---------------------------------------------------------------------
-- 10. RPC: me  (POST /rest/v1/rpc/me) — validate a stored token on app start
-- ---------------------------------------------------------------------
create or replace function public.me(p_token text)
returns json
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
    v_user public.users := public.app_require_role(p_token, null);
begin
    return json_build_object(
        'id', v_user.id, 'student_id', v_user.student_id, 'name', v_user.name,
        'email', v_user.email, 'role', v_user.role, 'created_at', v_user.created_at
    );
end;
$$;

-- ---------------------------------------------------------------------
-- 11. Function privileges: only the public RPCs are callable by the app
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function public.register_student(text, text, text) to anon;
grant execute on function public.login(text, text)                  to anon;
grant execute on function public.logout(text)                       to anon;
grant execute on function public.me(text)                           to anon;
-- app_require_role is intentionally NOT granted.

-- ---------------------------------------------------------------------
-- Example of an admin-only RPC for later tasks (pattern to copy):
--
-- create or replace function public.admin_list_users(p_token text)
-- returns setof json language plpgsql security definer
-- set search_path = public, extensions as $$
-- begin
--     perform public.app_require_role(p_token, 'admin');
--     return query select json_build_object('id', id, 'name', name,
--                         'email', email, 'role', role) from public.users;
-- end; $$;
-- grant execute on function public.admin_list_users(text) to anon;
-- ---------------------------------------------------------------------

notify pgrst, 'reload schema';
