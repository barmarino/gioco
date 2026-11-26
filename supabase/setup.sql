-- =====================================================================
-- Bar Marino: database del gioco per le famiglie
-- Da incollare una volta sola in Supabase > SQL Editor > New query > Run.
-- Si può rieseguire: non cancella dati già presenti.
-- =====================================================================

-- ---------- Tabelle ----------

-- Una riga per scuola: il giorno in cui si apre ciascuna delle 4 settimane
create table if not exists public.scuole (
  id        text primary key,
  nome      text,
  apertura  date[] not null check (array_length(apertura, 1) = 4)
);

-- Una riga per famiglia. Niente nomi: la tabella codice ↔ nome resta al team, fuori da qui.
-- Niente braccio di trattamento: si unisce dopo, in Stata, con il codice.
create table if not exists public.famiglie (
  codice    text primary key check (codice ~ '^[A-Z0-9]{4,10}$'),
  scuola    text not null references public.scuole(id),
  seed      int  not null check (seed > 0),          -- codice dei dadi
  speculari boolean not null default false,          -- dadi speculari (7 − faccia)
  nota      text,
  attiva    boolean not null default true,           -- false = il codice non entra più
  azzerata  timestamptz                              -- quando il team ha azzerato la partita
);

-- Una riga per partita: il documento che il gioco riscrive dopo ogni azione
create table if not exists public.partite (
  codice     text primary key references public.famiglie(codice) on delete cascade,
  doc        jsonb not null,
  decisioni  int not null default 0,
  dadi       int not null default 0,
  creata     timestamptz not null default now(),
  aggiornata timestamptz not null default now()
);

-- Le email dei ricercatori che possono usare il pannello
create table if not exists public.ricercatori (
  email text primary key
);

-- ---------- Accessi ----------
-- Con la sicurezza a livello di riga attiva e nessuna regola per il pubblico,
-- dal browser nessuno legge o scrive queste tabelle direttamente.
-- Le famiglie passano solo dalle due funzioni qui sotto, che chiedono il codice.
alter table public.scuole      enable row level security;
alter table public.famiglie    enable row level security;
alter table public.partite     enable row level security;
alter table public.ricercatori enable row level security;

-- Permessi espliciti, così il risultato è lo stesso qualunque sia l'opzione
-- "Grant API access to new tables automatically" scelta alla creazione del progetto.
-- Pubblico (anon): nessun accesso alle tabelle. Utenti autenticati: solo ciò che serve al pannello,
-- e le regole qui sotto lo limitano comunque ai ricercatori.
revoke all on public.scuole, public.famiglie, public.partite, public.ricercatori from anon, authenticated;
grant select on public.scuole, public.famiglie, public.partite to authenticated;
grant update (azzerata) on public.famiglie to authenticated;
grant delete on public.partite to authenticated;

-- È un ricercatore chi è entrato con email e password ed è nella tabella ricercatori
create or replace function public.e_ricercatore() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.ricercatori r
    where lower(r.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

drop policy if exists "ricercatori leggono le scuole" on public.scuole;
create policy "ricercatori leggono le scuole" on public.scuole
  for select to authenticated using (public.e_ricercatore());

drop policy if exists "ricercatori leggono le famiglie" on public.famiglie;
create policy "ricercatori leggono le famiglie" on public.famiglie
  for select to authenticated using (public.e_ricercatore());

drop policy if exists "ricercatori azzerano le famiglie" on public.famiglie;
create policy "ricercatori azzerano le famiglie" on public.famiglie
  for update to authenticated using (public.e_ricercatore()) with check (public.e_ricercatore());

drop policy if exists "ricercatori leggono le partite" on public.partite;
create policy "ricercatori leggono le partite" on public.partite
  for select to authenticated using (public.e_ricercatore());

drop policy if exists "ricercatori cancellano le partite" on public.partite;
create policy "ricercatori cancellano le partite" on public.partite
  for delete to authenticated using (public.e_ricercatore());

-- Quando il pannello azzera una partita, l'ora dell'azzeramento la mette il server, non il computer del ricercatore
create or replace function public.azzerata_ora_server() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.azzerata is distinct from old.azzerata and new.azzerata is not null then new.azzerata := now(); end if;
  return new;
end $$;
drop trigger if exists azzerata_ora_server on public.famiglie;
create trigger azzerata_ora_server before update on public.famiglie
  for each row execute function public.azzerata_ora_server();

-- ---------- Funzioni per le famiglie ----------

-- entra(codice): dati della famiglia, calendario della scuola, partita salvata, data di oggi (ora italiana)
-- e ora esatta del server (il gioco la usa per correggere l'orologio del telefono negli orari che registra).
-- Restituisce null se il codice non esiste o non è attivo.
create or replace function public.entra(p_codice text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  f public.famiglie;
  s public.scuole;
  p public.partite;
begin
  select * into f from public.famiglie where codice = upper(p_codice) and attiva;
  if not found then return null; end if;
  select * into s from public.scuole  where id = f.scuola;
  select * into p from public.partite where codice = f.codice;
  return jsonb_build_object(
    'famiglia', jsonb_build_object('scuola', f.scuola, 'seed', f.seed, 'speculari', f.speculari, 'azzerata', f.azzerata),
    'scuola',   case when s.id is null then null else jsonb_build_object('nome', s.nome, 'apertura', to_jsonb(s.apertura)) end,
    'partita',  p.doc,
    'oggi',     to_char((now() at time zone 'Europe/Rome')::date, 'YYYY-MM-DD'),
    'ora',      to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')
  );
end $$;

-- salva(codice, documento): riscrive la partita. Rifiuta:
--   un codice inesistente o non attivo;
--   un documento più grande di 200 KB;
--   decisioni di una settimana che, per la scuola, non è ancora aperta (vale l'orologio del server).
-- Se il server ha già una partita più avanti (un altro telefono ha giocato dopo), non la sovrascrive
-- e restituisce quella, così il telefono rimasto indietro riparte da lì.
create or replace function public.salva(p_codice text, p_doc jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  f public.famiglie;
  s public.scuole;
  cur public.partite;
  v_dec  int;
  v_dadi int;
  oggi   date := (now() at time zone 'Europe/Rome')::date;
begin
  select * into f from public.famiglie where codice = upper(p_codice) and attiva;
  if not found then raise exception 'codice non valido' using errcode = '28000'; end if;
  if octet_length(p_doc::text) > 200000 then raise exception 'documento troppo grande' using errcode = '22023'; end if;
  v_dec  := coalesce((p_doc ->> 'decisioni')::int, 0);
  v_dadi := coalesce(jsonb_array_length(p_doc -> 'dadi_tirati'), 0);
  if v_dec < 0 or v_dec > 20 then raise exception 'decisioni fuori intervallo' using errcode = '22023'; end if;
  select * into s from public.scuole where id = f.scuola;
  if v_dec > 0 and s.apertura is not null and s.apertura[((v_dec - 1) / 5) + 1] > oggi then
    raise exception 'settimana non ancora aperta' using errcode = '22023';
  end if;
  select * into cur from public.partite where codice = f.codice for update;
  if found and cur.decisioni * 20 + cur.dadi > v_dec * 20 + v_dadi then
    return jsonb_build_object('ok', false, 'motivo', 'indietro', 'partita', cur.doc);
  end if;
  insert into public.partite as t (codice, doc, decisioni, dadi, aggiornata)
  values (f.codice, p_doc, v_dec, v_dadi, now())
  on conflict (codice) do update
    set doc = excluded.doc, decisioni = excluded.decisioni, dadi = excluded.dadi, aggiornata = now();
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.entra(text)        from public;
revoke all on function public.salva(text, jsonb) from public;
revoke all on function public.e_ricercatore()    from public;
grant execute on function public.entra(text)        to anon, authenticated;
grant execute on function public.salva(text, jsonb) to anon, authenticated;
grant execute on function public.e_ricercatore()    to authenticated;

-- ---------- Dati di prova ----------
-- Due scuole finte e sei codici finti, come nella versione di prova. Prima del campo si cancellano
-- (delete from public.famiglie; delete from public.scuole;) e si caricano i codici veri.
insert into public.scuole (id, nome, apertura) values
  ('PROVA-LIBERA',     'Scuola di prova: tutte le settimane aperte', array[current_date, current_date, current_date, current_date]),
  ('PROVA-CALENDARIO', 'Scuola di prova: una settimana alla volta',  array[current_date, current_date + 7, current_date + 14, current_date + 21])
on conflict (id) do nothing;

insert into public.famiglie (codice, scuola, seed, speculari, nota) values
  ('K7P3A', 'PROVA-LIBERA',     1, false, 'tutte aperte · dadi normali'),
  ('M4R9C', 'PROVA-LIBERA',     1, true,  'tutte aperte · dadi speculari'),
  ('T3H7E', 'PROVA-LIBERA',     2, false, 'tutte aperte · altri dadi'),
  ('W9C4F', 'PROVA-CALENDARIO', 1, false, 'a calendario · dadi normali'),
  ('R3N7H', 'PROVA-CALENDARIO', 1, true,  'a calendario · dadi speculari'),
  ('E7X4L', 'PROVA-CALENDARIO', 3, false, 'a calendario · altri dadi')
on conflict (codice) do nothing;

-- ---------- Ricercatori ----------
-- Dopo aver creato l'utente in Authentication > Users, aggiungete qui la sua email
-- (togliete i due trattini davanti e scrivete l'email vera):
-- insert into public.ricercatori (email) values ('nome.cognome@unibocconi.it') on conflict do nothing;
