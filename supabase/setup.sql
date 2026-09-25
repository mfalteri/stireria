-- =====================================================================
-- Stireria Frequenze · database Supabase
--
-- Eseguire UNA volta in: Supabase → progetto "stireria" → SQL Editor
-- → New query → incolla tutto → Run.
-- Si può rieseguire senza danni: crea solo ciò che manca.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Profili: ruolo e sede di ogni utente
-- ---------------------------------------------------------------------
create table if not exists public.profili (
    id       uuid primary key references auth.users(id) on delete cascade,
    username text not null unique,
    ruolo    text not null check (ruolo in ('admin','sede')),
    sede     text check (sede in ('emporio','piazzetta')),
    constraint sede_coerente check (
        (ruolo = 'admin' and sede is null) or
        (ruolo = 'sede'  and sede is not null)
    )
);

create or replace function public.mio_ruolo() returns text
language sql stable security definer set search_path = public
as $$ select ruolo from public.profili where id = auth.uid() $$;

create or replace function public.mia_sede() returns text
language sql stable security definer set search_path = public
as $$ select sede from public.profili where id = auth.uid() $$;

-- Il profilo si crea da solo quando si aggiunge un utente in
-- Authentication → Users: admin@… diventa amministratore,
-- emporio@… e piazzetta@… diventano sedi. Altri indirizzi non hanno accesso.
create or replace function public.crea_profilo() returns trigger
language plpgsql security definer set search_path = public
as $$
declare
    nome text := lower(split_part(new.email, '@', 1));
begin
    if nome = 'admin' then
        insert into public.profili (id, username, ruolo, sede)
        values (new.id, nome, 'admin', null)
        on conflict (id) do nothing;
    elsif nome in ('emporio','piazzetta') then
        insert into public.profili (id, username, ruolo, sede)
        values (new.id, nome, 'sede', nome)
        on conflict (id) do nothing;
    end if;
    return new;
end $$;

drop trigger if exists crea_profilo on auth.users;
create trigger crea_profilo
after insert on auth.users
for each row execute function public.crea_profilo();

-- Utenti creati prima di eseguire questo script
insert into public.profili (id, username, ruolo, sede)
select id,
       lower(split_part(email,'@',1)),
       case when lower(split_part(email,'@',1)) = 'admin' then 'admin' else 'sede' end,
       case when lower(split_part(email,'@',1)) = 'admin' then null else lower(split_part(email,'@',1)) end
from auth.users
where lower(split_part(email,'@',1)) in ('admin','emporio','piazzetta')
on conflict (id) do nothing;


-- ---------------------------------------------------------------------
-- Impostazioni: tempi di stiratura e turni predefiniti
-- ---------------------------------------------------------------------
create table if not exists public.config (
    chiave text primary key,
    valore numeric not null check (valore >= 0)
);

insert into public.config (chiave, valore) values
    ('tempoCamicia', 25),
    ('tempoLenzuolo', 20),
    ('tempoCesta', 360),
    ('turniDefault', 6)
on conflict (chiave) do nothing;


-- ---------------------------------------------------------------------
-- Turni: solo i giorni diversi dal numero predefinito
-- ---------------------------------------------------------------------
create table if not exists public.turni (
    data  date primary key,
    turni numeric not null check (turni >= 0)
);


-- ---------------------------------------------------------------------
-- Ordini
-- ---------------------------------------------------------------------
create table if not exists public.ordini (
    id        bigint generated always as identity primary key,
    creato    timestamptz not null default now(),
    creato_da uuid references auth.users(id) default auth.uid(),
    data      date not null,                          -- giorno di consegna dei capi
    sede      text not null check (sede in ('emporio','piazzetta')),
    nome      text not null check (length(trim(nome)) > 0),
    cognome   text not null check (length(trim(cognome)) > 0),
    telefono  text not null check (telefono ~ '^[0-9]{8,15}$'),
    camicie   integer not null default 0 check (camicie  >= 0),
    lenzuola  integer not null default 0 check (lenzuola >= 0),
    ceste     integer not null default 0 check (ceste    >= 0),
    ritiro    date not null,                          -- giorno di ritiro scelto, dalle 14.00
    stato     text not null default 'lavorazione'
              check (stato in ('lavorazione','pronto','ritirato')),
    constraint almeno_un_capo check (camicie + lenzuola + ceste > 0),
    constraint ritiro_dopo_consegna check (ritiro > data)
);

create index if not exists ordini_data   on public.ordini (data);
create index if not exists ordini_ritiro on public.ordini (ritiro);
create index if not exists ordini_sede   on public.ordini (sede);


-- ---------------------------------------------------------------------
-- Calcolo del carico: la stireria è una sola, quindi la data di ritiro
-- tiene conto degli ordini di tutte le sedi. Le sedi non vedono gli
-- ordini delle altre: ricevono solo i totali per giorno, senza nomi.
-- ---------------------------------------------------------------------
create or replace function public.carico_giornaliero()
returns table (data date, camicie bigint, lenzuola bigint, ceste bigint)
language sql stable security definer set search_path = public
as $$
    select o.data, sum(o.camicie), sum(o.lenzuola), sum(o.ceste)
    from public.ordini o
    where public.mio_ruolo() is not null
    group by o.data
    order by o.data
$$;

-- Numero che avrà il prossimo ordine (mostrato sul cartellino prima di confermare)
create or replace function public.prossimo_numero()
returns bigint
language sql stable security definer set search_path = public
as $$
    select case when public.mio_ruolo() is null then null
                else coalesce(max(id), 0) + 1 end
    from public.ordini
$$;

revoke all on function public.carico_giornaliero() from public, anon;
revoke all on function public.prossimo_numero()    from public, anon;
grant execute on function public.carico_giornaliero() to authenticated;
grant execute on function public.prossimo_numero()    to authenticated;


-- ---------------------------------------------------------------------
-- Permessi (Row Level Security)
--   admin:            vede e modifica tutto
--   emporio/piazzetta: vede e registra solo gli ordini della propria sede,
--                      può segnarli "pronto" e poi "ritirato" (un passo alla volta)
-- ---------------------------------------------------------------------
alter table public.profili enable row level security;
alter table public.config  enable row level security;
alter table public.turni   enable row level security;
alter table public.ordini  enable row level security;

revoke all on public.profili, public.config, public.turni, public.ordini from anon;

drop policy if exists "profilo proprio, admin tutti" on public.profili;
create policy "profilo proprio, admin tutti" on public.profili
    for select to authenticated
    using (id = auth.uid() or public.mio_ruolo() = 'admin');

drop policy if exists "config: lettura" on public.config;
create policy "config: lettura" on public.config
    for select to authenticated
    using (public.mio_ruolo() is not null);

drop policy if exists "config: modifica admin" on public.config;
create policy "config: modifica admin" on public.config
    for update to authenticated
    using (public.mio_ruolo() = 'admin')
    with check (public.mio_ruolo() = 'admin');

drop policy if exists "turni: lettura" on public.turni;
create policy "turni: lettura" on public.turni
    for select to authenticated
    using (public.mio_ruolo() is not null);

drop policy if exists "turni: modifica admin" on public.turni;
create policy "turni: modifica admin" on public.turni
    for all to authenticated
    using (public.mio_ruolo() = 'admin')
    with check (public.mio_ruolo() = 'admin');

drop policy if exists "ordini: lettura" on public.ordini;
create policy "ordini: lettura" on public.ordini
    for select to authenticated
    using (public.mio_ruolo() = 'admin' or sede = public.mia_sede());

drop policy if exists "ordini: registrazione" on public.ordini;
create policy "ordini: registrazione" on public.ordini
    for insert to authenticated
    with check (
        stato = 'lavorazione' and
        (public.mio_ruolo() = 'admin' or sede = public.mia_sede())
    );

drop policy if exists "ordini: cambio stato" on public.ordini;
create policy "ordini: cambio stato" on public.ordini
    for update to authenticated
    using (
        public.mio_ruolo() = 'admin' or
        (sede = public.mia_sede() and stato in ('lavorazione','pronto'))
    )
    with check (
        public.mio_ruolo() = 'admin' or
        (sede = public.mia_sede() and stato in ('pronto','ritirato'))
    );

-- Per le sedi lo stato avanza solo di un passo: lavorazione → pronto → ritirato.
create or replace function public.controlla_cambio_stato() returns trigger
language plpgsql security definer set search_path = public
as $$
begin
    if public.mio_ruolo() = 'sede' and new.stato is distinct from old.stato and not (
        (old.stato = 'lavorazione' and new.stato = 'pronto') or
        (old.stato = 'pronto'      and new.stato = 'ritirato')
    ) then
        raise exception 'Passaggio di stato non consentito: % → %', old.stato, new.stato;
    end if;
    return new;
end $$;

drop trigger if exists controlla_cambio_stato on public.ordini;
create trigger controlla_cambio_stato
before update on public.ordini
for each row execute function public.controlla_cambio_stato();

drop policy if exists "ordini: eliminazione admin" on public.ordini;
create policy "ordini: eliminazione admin" on public.ordini
    for delete to authenticated
    using (public.mio_ruolo() = 'admin');

-- Dopo la registrazione di un ordine si può cambiare solo lo stato.
revoke update on public.ordini from authenticated;
grant  update (stato) on public.ordini to authenticated;
