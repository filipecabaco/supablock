-- Data for the Docker e2e (DML only — the CLI runs seed.sql as a prepared
-- batch, so DDL lives in the migration). See migration.sql for what each
-- table is exercising.

insert into public.todos (title, done) values
  ('write the docker e2e', true),
  ('ship it', false),
  ('handle, commas', false),
  ('say "quoted things"', false),
  -- Unicode spelled in \u escapes so this DML stays pure ASCII: the CLI's
  -- seeding connection double-encodes raw UTF-8 bytes, while server-side
  -- escape parsing stores the real codepoints.
  (E'emoji \u2705 and \u00FCn\u00EFc\u00F8d\u00E9', true);

-- 1200 rows -> rows-000000 / rows-000500 / rows-001000 at the default page
-- size; jsonb + text[] columns render as JSON-encoded CSV fields.
insert into public.events (id, at, payload, tags)
select g,
       timestamptz '2026-01-01 00:00:00+00' + make_interval(mins => g),
       jsonb_build_object('n', g, 'even', g % 2 = 0),
       array['tag' || (g % 3)::text, 'all']
from generate_series(1, 1200) as g;

insert into public.customers (name, note, balance, meta) values
  ('Ada Lovelace', 'first, among equals', 1815.12, '{"vip": true, "tags": ["math", "poetry"]}'),
  ('Grace "Amazing" Hopper', E'line one\nline two', 1906.00, '{"rank": "rear admiral"}'),
  ('Null Fields', null, null, null);

insert into public.audit_log (happened_at, action) values
  (timestamptz '2026-01-01 10:00:00+00', 'seeded'),
  (timestamptz '2026-01-02 10:00:00+00', 'checked');

insert into public.order_items (order_id, line, sku, qty) values
  (1, 1, 'SKU-A', 2),
  (1, 2, 'SKU-B', 1),
  (2, 1, 'SKU-A', 5);

insert into app.settings (key, value) values
  ('theme', 'dark'),
  ('retention_days', '30');
