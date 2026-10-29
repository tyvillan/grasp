-- GRASP feedback: run once in your Supabase project (SQL Editor -> New query -> Run).
-- Run it AFTER schema.sql if you use sync. It is safe to run twice.
--
-- What it makes:
--   * public.feedback            one row per piece of feedback, written by the app
--   * public.feedback_inbox      a read-only view for you, newest first
--   * storage bucket             feedback-screenshots (private), for the optional picture
--
-- Who can do what: the app sends feedback with only the public (anon) key and no
-- sign-in, so it acts as the `anon` role. That role can INSERT feedback rows and
-- INSERT screenshots, and nothing else: no select, update or delete, on rows or
-- pictures. You read everything in the dashboard (the Table Editor and the Storage
-- browser use an admin role that row-level security does not apply to).

-- ---------------------------------------------------------------- table

create table if not exists public.feedback (
    id              uuid        primary key default gen_random_uuid(),
    created_at      timestamptz not null default now(),
    type            text        not null check (type in ('bug', 'confusing', 'idea', 'love')),
    rating          smallint    check (rating between 1 and 5),
    message         text        not null check (char_length(message) between 1 and 4000),
    anonymous       boolean     not null default true,
    name            text        check (char_length(name) <= 100),
    email           text        check (char_length(email) <= 254),
    screen          text        check (char_length(screen) <= 100),
    app_version     text        check (char_length(app_version) <= 40),
    build           text        check (char_length(build) <= 40),
    platform        text        check (platform in ('mac', 'iphone')),
    os_version      text        check (char_length(os_version) <= 60),
    device_model    text        check (char_length(device_model) <= 60),
    ai_mode         text        check (ai_mode in ('cloud', 'local', 'off')),
    install_id      text        check (char_length(install_id) <= 64),
    screenshot_path text        check (screenshot_path ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$'),
    status          text        not null default 'new' check (status in ('new', 'seen', 'done')),
    -- An anonymous row cannot carry a name or an email, whatever a client sends.
    constraint feedback_anonymous_has_no_contact check (not anonymous or (name is null and email is null))
);

create index if not exists feedback_created_at on public.feedback (created_at desc);
create index if not exists feedback_install on public.feedback (install_id, created_at);

-- ---------------------------------------------------------------- row-level security

alter table public.feedback enable row level security;

-- Start from nothing, then grant only INSERT, and only on the columns the app
-- sets. `created_at` and `status` are left out on purpose: the server fills
-- them, so a client cannot back-date a row or mark it 'done'.
revoke all on public.feedback from anon, authenticated;
grant insert (id, type, rating, message, anonymous, name, email, screen, app_version, build,
              platform, os_version, device_model, ai_mode, install_id, screenshot_path)
    on public.feedback to anon, authenticated;

drop policy if exists "Anyone can send feedback" on public.feedback;
create policy "Anyone can send feedback" on public.feedback
    for insert
    to anon, authenticated
    with check (true);
-- No select, update or delete policy exists, so none of those is possible for the app.

-- ---------------------------------------------------------------- flood guard

-- The anon key is public, so anyone can call the insert endpoint. This caps it:
-- 20 rows a day for one install id, and 100 rows an hour in total. A row over
-- the cap is refused with a plain message; the app keeps it and tries again later.
create or replace function public.feedback_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if (select count(*) from public.feedback where created_at > now() - interval '1 hour') >= 100 then
        raise exception 'Too much feedback right now. Try again later.';
    end if;
    if new.install_id is not null
       and (select count(*) from public.feedback
            where install_id = new.install_id and created_at > now() - interval '1 day') >= 20 then
        raise exception 'This install has sent a lot of feedback today. Try again tomorrow.';
    end if;
    return new;
end;
$$;

revoke all on function public.feedback_guard() from public, anon, authenticated;

drop trigger if exists feedback_guard on public.feedback;
create trigger feedback_guard
    before insert on public.feedback
    for each row execute function public.feedback_guard();

-- ---------------------------------------------------------------- the inbox

-- What you read. `security_invoker` makes it follow the caller's permissions,
-- and the revoke keeps the app out of it entirely.
create or replace view public.feedback_inbox
with (security_invoker = on)
as
select
    created_at,
    status,
    type,
    rating,
    message,
    case when anonymous then 'anonymous' else coalesce(name, '(no name)') end as from_name,
    case when anonymous then null else email end                              as email,
    screen,
    platform,
    app_version,
    build,
    os_version,
    device_model,
    ai_mode,
    screenshot_path,
    id
from public.feedback
order by created_at desc;

revoke all on public.feedback_inbox from anon, authenticated;

-- ---------------------------------------------------------------- screenshots

-- Private bucket, JPEG only, 600 KB at most (the app sends 500 KB at most).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('feedback-screenshots', 'feedback-screenshots', false, 600000, array['image/jpeg'])
on conflict (id) do update
    set public = false,
        file_size_limit = 600000,
        allowed_mime_types = array['image/jpeg'];

-- Insert only, into this bucket only, and only under a name that is a uuid plus
-- ".jpg" (the app names each picture after its feedback row's id). No select,
-- update or delete, so the app can neither list nor overwrite anyone's picture.
drop policy if exists "Send feedback screenshots" on storage.objects;
create policy "Send feedback screenshots" on storage.objects
    for insert
    to anon, authenticated
    with check (
        bucket_id = 'feedback-screenshots'
        and name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$'
    );
