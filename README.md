# Stireria Frequenze

Web app per registrare gli ordini di stiratura delle sedi (Emporio, Piazzetta)
e organizzare il lavoro della stireria. Database e accessi su Supabase.

## Configurazione di Supabase

1. **Progetto** — su supabase.com, organizzazione *frequenze* → **New project**
   - Nome: `stireria`
   - Database password: premi *Generate a password* e salvala nel gestore password
   - Regione: Europa (Zurigo se disponibile, altrimenti Francoforte)

2. **Database** — nel progetto: **SQL Editor** → *New query* → incolla
   il contenuto di [`supabase/setup.sql`](supabase/setup.sql) → **Run**.

3. **Blocca le iscrizioni libere** — **Authentication → Sign In / Providers**:
   disattiva *Allow new users to sign up*. Gli utenti li crea solo l'amministratore.

4. **Utenti** — **Authentication → Users → Add user → Create new user**,
   con *Auto Confirm User* attivo:

   | Utente    | Email da inserire              | Accesso                                   |
   |-----------|--------------------------------|-------------------------------------------|
   | admin     | `admin@stireria.frequenze.ch`     | tutto, modifica tempi e turni, stampe     |
   | emporio   | `emporio@stireria.frequenze.ch`   | solo ordini e consegne dell'Emporio       |
   | piazzetta | `piazzetta@stireria.frequenze.ch` | solo ordini e consegne della Piazzetta    |

   Nell'app si entra scrivendo solo `admin`, `emporio` o `piazzetta`: il
   dominio `@stireria.frequenze.ch` lo aggiunge l'app. Gli indirizzi non devono
   esistere davvero (con *Auto Confirm* non viene inviata nessuna email).
   Il ruolo e la sede vengono assegnati automaticamente dallo script.

   Supabase richiede password di **almeno 6 caratteri**.

5. **Chiavi per l'app** — **Project Settings → API**: copia *Project URL* e la
   chiave *anon / publishable*. Sono pubbliche per natura e vanno nel codice
   dell'app. **Non** usare mai la chiave *service_role / secret*.

## Pubblicazione su Cloudflare Pages

Il sito è statico: nessuna compilazione.

- **Workers & Pages → Create → Pages → Connect to Git** → questo repository
- Framework preset: *None* · Build command: *(vuoto)* · Build output directory: `/`
- Ogni push su `main` pubblica una nuova versione.

### Sicurezza

| Protezione | Dove |
|---|---|
| Accesso solo da connessioni in Svizzera (variabile `PAESI_CONSENTITI`, predefinito `CH`) | [`functions/_middleware.js`](functions/_middleware.js) |
| Content-Security-Policy, HSTS, anti-iframe, niente referrer, `noindex` | [`_headers`](_headers) |
| Librerie esterne verificate con impronta SRI | `index.html` |
| Permessi sui dati per ruolo e sede (Row Level Security) | [`supabase/setup.sql`](supabase/setup.sql) |
| Iscrizioni libere disattivate | Supabase → Authentication |

## Permessi

| | admin | emporio / piazzetta |
|---|---|---|
| Registrare ordini | per tutte le sedi | solo per la propria sede |
| Vedere ordini | tutti | solo della propria sede |
| Cambiare stato | tutti gli stati | *In lavorazione → Pronto → Ritirato*, solo per la propria sede |
| Eliminare ordini | sì | no |
| Tempi e turni | modifica | no |
| Piano di lavoro e stampe | sì | no |
| Piano consegne | tutte le sedi | solo la propria sede |

Il calcolo della data di ritiro usa il carico di **tutte** le sedi (la stireria
è una sola): le sedi ricevono i totali per giorno, mai nomi o telefoni degli
ordini altrui.
