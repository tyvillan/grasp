-- GRASP sync: run once in your Supabase project (SQL Editor -> New query -> Run).
--
-- One table holds every synced row from every device, one row per
-- (account, table, row key). The app sends each row whole as JSON, so the
-- server never needs to know GRASP's schema -- a new column in a future
-- version of the app just appears in `data`.

create table if not exists public.sync_rows (
    user_id     uuid        not null default auth.uid()
                            references auth.users (id) on delete cascade,
    table_name  text        not null,
    row_key     text        not null,
    data        jsonb,                              -- null when deleted
    deleted     boolean     not null default false,
    device_id   text,                               -- which device last wrote it
    updated_at  timestamptz not null default clock_timestamp(),
    primary key (user_id, table_name, row_key)
);

-- Pulls ask for "everything this account changed since <time>".
create index if not exists sync_rows_user_updated
    on public.sync_rows (user_id, updated_at, table_name, row_key);

-- Every write gets a fresh server time, whatever the device's clock says:
-- pulls page on this, so it has to come from one clock.
create or replace function public.sync_rows_touch()
returns trigger language plpgsql as $$
begin
    new.updated_at := clock_timestamp();
    return new;
end;
$$;

drop trigger if exists sync_rows_touch on public.sync_rows;
create trigger sync_rows_touch
    before insert or update on public.sync_rows
    for each row execute function public.sync_rows_touch();

-- Row-level security: a signed-in account can only ever see and change its
-- own rows. The app's key is public by design; this is what protects data.
alter table public.sync_rows enable row level security;

drop policy if exists "Own rows only" on public.sync_rows;
create policy "Own rows only" on public.sync_rows
    for all
    to authenticated
    using (auth.uid() = user_id)
    with check (auth.uid() = user_id);
