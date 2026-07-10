-- Schema for the Docker e2e's local Supabase project (DDL only; data is in
-- seed.sql). Deliberately awkward: every shape the database/ tree has to
-- render is represented, so the e2e proves paging, ordering, escaping and
-- schema handling against a real Postgres + PostgREST rather than fixtures.

-- A second exposed schema: the tree must show database/app next to
-- database/public (the shim's postgrest config names both; config.toml
-- makes the local PostgREST actually serve it).
create schema app;

-- The original simple case.
create table public.todos (
  id serial primary key,
  title text not null,
  done boolean not null default false
);

-- Multi-page: seeded with 1200 rows (> 2 pages at the default 500/page),
-- ordered by primary key so page boundaries are deterministic. jsonb and
-- array columns must render as JSON-encoded CSV fields.
create table public.events (
  id bigint primary key,
  at timestamptz not null,
  payload jsonb,
  tags text[]
);

-- CSV-escaping nasties: commas, double quotes, embedded newlines, unicode,
-- NULLs (empty CSV fields), numerics. RLS is enabled with no policies —
-- supablock reads with service_role by default, which bypasses RLS, so the
-- rows must still appear.
create table public.customers (
  id serial primary key,
  name text not null,
  note text,
  balance numeric(10, 2),
  meta jsonb
);

alter table public.customers enable row level security;

-- No primary key: pages carry no order clause (PostgREST order unspecified).
create table public.audit_log (
  happened_at timestamptz not null,
  action text not null
);

-- Composite primary key: pages order by (order_id, line).
create table public.order_items (
  order_id int not null,
  line int not null,
  sku text not null,
  qty int not null,
  primary key (order_id, line)
);

-- Zero rows: the table's folder must list no page files at all.
create table public.empty_table (
  id serial primary key,
  nothing text
);

-- Views are tables to PostgREST — the tree must list and page them too.
create view public.open_todos as
  select id, title from public.todos where not done;

create table app.settings (
  key text primary key,
  value text not null
);

grant usage on schema app to anon, authenticated, service_role;
grant select on all tables in schema public to anon, authenticated, service_role;
grant select on all tables in schema app to anon, authenticated, service_role;
