-- =====================================================================
-- Bar Marino: database for the family game
-- Paste once into Supabase > SQL Editor > New query > Run.
-- Safe to run again: it does not delete existing data.
-- =====================================================================

-- ---------- Tables ----------

-- One row per school: the day each of the 4 weeks opens
create table if not exists public.schools (
  id             text primary key,
  name           text,
  opening_dates  date[] not null check (array_length(opening_dates, 1) = 4)
);

-- One row per family. No names: the code ↔ name key stays with the team, outside this database.
-- No treatment arm either: it is merged later, in Stata, on the code.
create table if not exists public.families (
  code           text primary key check (code ~ '^[A-Z0-9]{4,10}$'),
  school         text not null references public.schools(id),
  seed           int  not null check (seed > 0),         -- dice code
  mirrored_dice  boolean not null default false,         -- mirrored dice (7 − face)
  note           text,
  active         boolean not null default true,          -- false = the code can no longer enter
  reset_at       timestamptz                             -- when the team last reset this family's game
);

-- One row per game: the document the game rewrites after every action
create table if not exists public.games (
  code        text primary key references public.families(code) on delete cascade,
  game        jsonb not null,
  decisions   int not null default 0,
  dice        int not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

-- Emails of the researchers who can use the panel
create table if not exists public.researchers (
  email text primary key
);

-- ---------- Access ----------
-- Row-level security on, and no rule for the public: from the browser nobody reads or writes
-- these tables directly. Families only go through the two functions below, which take the code.
alter table public.schools     enable row level security;
alter table public.families    enable row level security;
alter table public.games       enable row level security;
alter table public.researchers enable row level security;

-- Explicit privileges, so the result is the same whatever "Grant API access to new tables
-- automatically" was set to when the project was created.
-- Public (anon): no table access. Signed-in users: only what the panel needs,
-- and the rules below restrict it to researchers anyway.
revoke all on public.schools, public.families, public.games, public.researchers from anon, authenticated;
grant select on public.schools, public.families, public.games to authenticated;
grant update (reset_at) on public.families to authenticated;
grant delete on public.games to authenticated;

-- A researcher is someone signed in with email and password whose email is in researchers
create or replace function public.is_researcher() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.researchers r
    where lower(r.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

drop policy if exists "researchers read schools" on public.schools;
create policy "researchers read schools" on public.schools
  for select to authenticated using (public.is_researcher());

drop policy if exists "researchers read families" on public.families;
create policy "researchers read families" on public.families
  for select to authenticated using (public.is_researcher());

drop policy if exists "researchers reset families" on public.families;
create policy "researchers reset families" on public.families
  for update to authenticated using (public.is_researcher()) with check (public.is_researcher());

drop policy if exists "researchers read games" on public.games;
create policy "researchers read games" on public.games
  for select to authenticated using (public.is_researcher());

drop policy if exists "researchers delete games" on public.games;
create policy "researchers delete games" on public.games
  for delete to authenticated using (public.is_researcher());

-- When the panel resets a game, the reset time is the server's, not the researcher's computer's
create or replace function public.set_reset_at_server_time() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.reset_at is distinct from old.reset_at and new.reset_at is not null then new.reset_at := now(); end if;
  return new;
end $$;
drop trigger if exists set_reset_at_server_time on public.families;
create trigger set_reset_at_server_time before update on public.families
  for each row execute function public.set_reset_at_server_time();

-- ---------- Functions for families ----------

-- enter_game(code): the family's data, the school calendar, the saved game, today's date (Italian time)
-- and the server's exact time (the game uses it to correct the phone's clock in the times it logs).
-- Returns null if the code does not exist or is not active.
create or replace function public.enter_game(p_code text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  f public.families;
  s public.schools;
  g public.games;
begin
  select * into f from public.families where code = upper(p_code) and active;
  if not found then return null; end if;
  select * into s from public.schools where id = f.school;
  select * into g from public.games   where code = f.code;
  return jsonb_build_object(
    'family', jsonb_build_object('school', f.school, 'seed', f.seed, 'mirrored_dice', f.mirrored_dice, 'reset_at', f.reset_at),
    'school', case when s.id is null then null else jsonb_build_object('name', s.name, 'opening_dates', to_jsonb(s.opening_dates)) end,
    'game',   g.game,
    'today',  to_char((now() at time zone 'Europe/Rome')::date, 'YYYY-MM-DD'),
    'now',    to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
  );
end $$;

-- save_game(code, game): rewrites the game. Refuses:
--   a code that does not exist or is not active;
--   a document larger than 200 KB;
--   decisions in a week that the school has not opened yet (by the server's clock).
-- If the server already has a more advanced game (another phone played further), it does not
-- overwrite it and returns it, so the phone that is behind continues from there.
create or replace function public.save_game(p_code text, p_game jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  f public.families;
  s public.schools;
  cur public.games;
  v_dec  int;
  v_dice int;
  today  date := (now() at time zone 'Europe/Rome')::date;
begin
  select * into f from public.families where code = upper(p_code) and active;
  if not found then raise exception 'invalid code' using errcode = '28000'; end if;
  if octet_length(p_game::text) > 200000 then raise exception 'game document too large' using errcode = '22023'; end if;
  v_dec  := coalesce((p_game ->> 'decisions')::int, 0);
  v_dice := coalesce(jsonb_array_length(p_game -> 'dice_rolled'), 0);
  if v_dec < 0 or v_dec > 20 then raise exception 'decisions out of range' using errcode = '22023'; end if;
  select * into s from public.schools where id = f.school;
  if v_dec > 0 and s.opening_dates is not null and s.opening_dates[((v_dec - 1) / 5) + 1] > today then
    raise exception 'week not open yet' using errcode = '22023';
  end if;
  select * into cur from public.games where code = f.code for update;
  if found and cur.decisions * 20 + cur.dice > v_dec * 20 + v_dice then
    return jsonb_build_object('ok', false, 'reason', 'behind', 'game', cur.game);
  end if;
  insert into public.games as t (code, game, decisions, dice, updated_at)
  values (f.code, p_game, v_dec, v_dice, now())
  on conflict (code) do update
    set game = excluded.game, decisions = excluded.decisions, dice = excluded.dice, updated_at = now();
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.enter_game(text)       from public;
revoke all on function public.save_game(text, jsonb) from public;
revoke all on function public.is_researcher()        from public;
grant execute on function public.enter_game(text)       to anon, authenticated;
grant execute on function public.save_game(text, jsonb) to anon, authenticated;
grant execute on function public.is_researcher()        to authenticated;

-- ---------- Test data ----------
-- Two fake schools and six fake codes. Before the field, delete them
-- (delete from public.families; delete from public.schools;) and load the real codes.
insert into public.schools (id, name, opening_dates) values
  ('TEST-OPEN',     'Test school: all weeks open',  array[current_date, current_date, current_date, current_date]),
  ('TEST-CALENDAR', 'Test school: one week at a time', array[current_date, current_date + 7, current_date + 14, current_date + 21])
on conflict (id) do nothing;

insert into public.families (code, school, seed, mirrored_dice, note) values
  ('K7P3A', 'TEST-OPEN',     1, false, 'all weeks open · normal dice'),
  ('M4R9C', 'TEST-OPEN',     1, true,  'all weeks open · mirrored dice'),
  ('T3H7E', 'TEST-OPEN',     2, false, 'all weeks open · other dice'),
  ('W9C4F', 'TEST-CALENDAR', 1, false, 'calendar · normal dice'),
  ('R3N7H', 'TEST-CALENDAR', 1, true,  'calendar · mirrored dice'),
  ('E7X4L', 'TEST-CALENDAR', 3, false, 'calendar · other dice')
on conflict (code) do nothing;

-- ---------- Researchers ----------
-- After creating the user in Authentication > Users, add their email here
-- (remove the two dashes and write the real email):
-- insert into public.researchers (email) values ('name.surname@unibocconi.it') on conflict do nothing;
