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

-- Numeri svizzeri scritti senza prefisso (079…) salvati in formato internazionale (4179…).
create or replace function public.normalizza_telefono(t text) returns text
language sql immutable set search_path = public
as $$
    select case
        when n like '00%' then substr(n, 3)
        when n like '0%'  then '41' || substr(n, 2)
        else n
    end
    from (select regexp_replace(coalesce(t, ''), '\D', '', 'g') as n) x
$$;

create or replace function public.prepara_ordine() returns trigger
language plpgsql set search_path = public
as $$
begin
    new.telefono := public.normalizza_telefono(new.telefono);
    if new.telefono like '410%' then
        new.telefono := '41' || substr(new.telefono, 4);
    end if;
    return new;
end $$;

drop trigger if exists prepara_ordine on public.ordini;
create trigger prepara_ordine
before insert on public.ordini
for each row execute function public.prepara_ordine();

create index if not exists ordini_data   on public.ordini (data);
create index if not exists ordini_ritiro on public.ordini (ritiro);
create index if not exists ordini_sede   on public.ordini (sede);


-- ---------------------------------------------------------------------
-- Calcolo del carico: la stireria è una sola, quindi la data di ritiro
-- tiene conto degli ordini di tutte le sedi. Le sedi non vedono gli
-- ordini delle altre: ricevono solo i totali per giorno, senza nomi.
-- Gli ordini segnati "pronto" o "ritirato" non pesano più sulle date
-- di ritiro: contano solo i capi "aperti" (ancora in lavorazione).
-- ---------------------------------------------------------------------
drop function if exists public.carico_giornaliero();
create function public.carico_giornaliero()
returns table (
    data date,
    camicie bigint, lenzuola bigint, ceste bigint,                 -- tutti i capi arrivati
    camicie_aperte bigint, lenzuola_aperte bigint, ceste_aperte bigint  -- solo ordini in lavorazione
)
language sql stable security definer set search_path = public
as $$
    select o.data,
           sum(o.camicie), sum(o.lenzuola), sum(o.ceste),
           sum(o.camicie)  filter (where o.stato = 'lavorazione'),
           sum(o.lenzuola) filter (where o.stato = 'lavorazione'),
           sum(o.ceste)    filter (where o.stato = 'lavorazione')
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

-- =====================================================================
-- Completi, mezze ceste, lavaggio, prezzi e pagamento
-- (ridefinisce alcune funzioni e permessi definiti sopra)
-- =====================================================================

-- ---------- Nuovi capi e dati dell'ordine ----------
alter table public.ordini
    add column if not exists completi    integer not null default 0 check (completi    >= 0),
    add column if not exists mezze_ceste integer not null default 0 check (mezze_ceste >= 0),
    add column if not exists lavare      boolean not null default false,
    add column if not exists pagato      boolean not null default false,
    add column if not exists importo     numeric(8,2) not null default 0 check (importo >= 0);

alter table public.ordini drop constraint if exists almeno_un_capo;
alter table public.ordini add constraint almeno_un_capo
    check (camicie + lenzuola + ceste + completi + mezze_ceste > 0);

-- ---------- Tempi e prezzi (CHF): solo stirato / stirato e lavato ----------
insert into public.config (chiave, valore) values
    ('tempoCompleto', 40),
    ('tempoMezzaCesta', 180),
    ('prezzoCamicia', 2.5),     ('prezzoCamiciaLavato', 3.5),
    ('prezzoLenzuolo', 5),      ('prezzoLenzuoloLavato', 10),
    ('prezzoCompleto', 10),     ('prezzoCompletoLavato', 10),
    ('prezzoMezzaCesta', 15),   ('prezzoMezzaCestaLavato', 20),
    ('prezzoCesta', 25),        ('prezzoCestaLavato', 35)
on conflict (chiave) do nothing;

-- Prezzo di un ordine secondo i prezzi attuali
create or replace function public.calcola_importo(
    camicie integer, lenzuola integer, ceste integer,
    completi integer, mezze_ceste integer, lavare boolean
) returns numeric
language sql stable set search_path = public
as $$
    with p as (select chiave, valore from public.config),
         v(k) as (select case when lavare then 'Lavato' else '' end)
    select round((
          camicie     * coalesce((select valore from p, v where chiave = 'prezzoCamicia'    || v.k), 0)
        + lenzuola    * coalesce((select valore from p, v where chiave = 'prezzoLenzuolo'   || v.k), 0)
        + ceste       * coalesce((select valore from p, v where chiave = 'prezzoCesta'      || v.k), 0)
        + completi    * coalesce((select valore from p, v where chiave = 'prezzoCompleto'   || v.k), 0)
        + mezze_ceste * coalesce((select valore from p, v where chiave = 'prezzoMezzaCesta' || v.k), 0)
    )::numeric, 2)
$$;

-- Alla registrazione: telefono in formato internazionale e importo calcolato dal database
create or replace function public.prepara_ordine() returns trigger
language plpgsql set search_path = public
as $$
begin
    new.telefono := public.normalizza_telefono(new.telefono);
    if new.telefono like '410%' then
        new.telefono := '41' || substr(new.telefono, 4);
    end if;
    new.importo := public.calcola_importo(
        new.camicie, new.lenzuola, new.ceste, new.completi, new.mezze_ceste, new.lavare
    );
    return new;
end $$;

-- Importo degli ordini già registrati (solo stiratura)
update public.ordini
set importo = public.calcola_importo(camicie, lenzuola, ceste, completi, mezze_ceste, lavare)
where importo = 0;

-- ---------- Carico giornaliero con i nuovi capi ----------
drop function if exists public.carico_giornaliero();
create function public.carico_giornaliero()
returns table (
    data date,
    camicie bigint, lenzuola bigint, ceste bigint, completi bigint, mezze_ceste bigint,
    camicie_aperte bigint, lenzuola_aperte bigint, ceste_aperte bigint,
    completi_aperte bigint, mezze_ceste_aperte bigint
)
language sql stable security definer set search_path = public
as $$
    select o.data,
           sum(o.camicie), sum(o.lenzuola), sum(o.ceste), sum(o.completi), sum(o.mezze_ceste),
           sum(o.camicie)     filter (where o.stato = 'lavorazione'),
           sum(o.lenzuola)    filter (where o.stato = 'lavorazione'),
           sum(o.ceste)       filter (where o.stato = 'lavorazione'),
           sum(o.completi)    filter (where o.stato = 'lavorazione'),
           sum(o.mezze_ceste) filter (where o.stato = 'lavorazione')
    from public.ordini o
    where public.mio_ruolo() is not null
    group by o.data
    order by o.data
$$;

revoke all on function public.carico_giornaliero() from public, anon;
grant execute on function public.carico_giornaliero() to authenticated;

-- ---------- Pagamento ----------
-- Dopo la registrazione si possono cambiare solo stato e pagamento.
revoke update on public.ordini from authenticated;
grant  update (stato, pagato) on public.ordini to authenticated;

-- Le sedi possono aggiornare anche gli ordini ritirati (per segnare il pagamento).
drop policy if exists "ordini: cambio stato" on public.ordini;
create policy "ordini: cambio stato" on public.ordini
    for update to authenticated
    using (public.mio_ruolo() = 'admin' or sede = public.mia_sede())
    with check (
        public.mio_ruolo() = 'admin' or
        (sede = public.mia_sede() and stato in ('pronto','ritirato'))
    );

-- Per le sedi: lo stato avanza di un passo alla volta e un pagamento non si annulla.
create or replace function public.controlla_cambio_stato() returns trigger
language plpgsql security definer set search_path = public
as $$
begin
    if public.mio_ruolo() = 'sede' then
        if new.stato is distinct from old.stato and not (
            (old.stato = 'lavorazione' and new.stato = 'pronto') or
            (old.stato = 'pronto'      and new.stato = 'ritirato')
        ) then
            raise exception 'Passaggio di stato non consentito: % → %', old.stato, new.stato;
        end if;
        if old.pagato and not new.pagato then
            raise exception 'Un pagamento registrato può essere annullato solo dall''amministratore';
        end if;
    end if;
    return new;
end $$;

-- =====================================================================
-- Lavaggio scelto per ogni tipo di capo (sostituisce calcola_importo)
-- =====================================================================
alter table public.ordini
    add column if not exists lavare_camicie     boolean not null default false,
    add column if not exists lavare_lenzuola    boolean not null default false,
    add column if not exists lavare_completi    boolean not null default false,
    add column if not exists lavare_mezze_ceste boolean not null default false,
    add column if not exists lavare_ceste       boolean not null default false;

-- Prezzo di un ordine: per ogni capo, prezzo "stirato" o "stirato e lavato"
create or replace function public.calcola_importo_ordine(o public.ordini) returns numeric
language sql stable set search_path = public
as $$
    with p as (select chiave, valore from public.config)
    select round((
          o.camicie     * coalesce((select valore from p where chiave = 'prezzoCamicia'    || case when o.lavare_camicie     then 'Lavato' else '' end), 0)
        + o.lenzuola    * coalesce((select valore from p where chiave = 'prezzoLenzuolo'   || case when o.lavare_lenzuola    then 'Lavato' else '' end), 0)
        + o.completi    * coalesce((select valore from p where chiave = 'prezzoCompleto'   || case when o.lavare_completi    then 'Lavato' else '' end), 0)
        + o.mezze_ceste * coalesce((select valore from p where chiave = 'prezzoMezzaCesta' || case when o.lavare_mezze_ceste then 'Lavato' else '' end), 0)
        + o.ceste       * coalesce((select valore from p where chiave = 'prezzoCesta'      || case when o.lavare_ceste       then 'Lavato' else '' end), 0)
    )::numeric, 2)
$$;

create or replace function public.prepara_ordine() returns trigger
language plpgsql set search_path = public
as $$
begin
    new.telefono := public.normalizza_telefono(new.telefono);
    if new.telefono like '410%' then
        new.telefono := '41' || substr(new.telefono, 4);
    end if;

    -- un capo si lava solo se c'è; "lavare" = almeno un capo da lavare
    new.lavare_camicie     := new.lavare_camicie     and new.camicie > 0;
    new.lavare_lenzuola    := new.lavare_lenzuola    and new.lenzuola > 0;
    new.lavare_completi    := new.lavare_completi    and new.completi > 0;
    new.lavare_mezze_ceste := new.lavare_mezze_ceste and new.mezze_ceste > 0;
    new.lavare_ceste       := new.lavare_ceste       and new.ceste > 0;
    new.lavare := new.lavare_camicie or new.lavare_lenzuola or new.lavare_completi
               or new.lavare_mezze_ceste or new.lavare_ceste;

    new.importo := public.calcola_importo_ordine(new);
    return new;
end $$;

drop function if exists public.calcola_importo(integer, integer, integer, integer, integer, boolean);
