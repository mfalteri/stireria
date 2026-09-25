/*
Blocca l'accesso all'app a chi non si collega dalla Svizzera.

Cloudflare conosce il paese di ogni visitatore (request.cf.country).
I paesi ammessi si possono cambiare senza toccare il codice con la
variabile d'ambiente PAESI_CONSENTITI del progetto Pages, es. "CH,LI".
*/
const PAESI_PREDEFINITI = "CH";

const PAGINA_BLOCCATA = `<!DOCTYPE html>
<html lang="it">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Accesso non disponibile</title>
<style>
body{margin:0;min-height:100vh;display:grid;place-items:center;padding:24px;background:#EFF0EC;color:#16181B;font-family:"Helvetica Neue",Arial,sans-serif;}
main{max-width:420px;padding:32px 28px;border-radius:18px;background:#fff;box-shadow:0 10px 30px -14px rgba(20,24,30,.3);}
h1{margin:0 0 12px;font-size:24px;}
p{margin:0;line-height:1.5;color:#4B5058;}
</style>
</head>
<body>
<main>
<h1>Accesso non disponibile</h1>
<p>La Stireria Frequenze è raggiungibile solo da una connessione in Svizzera. Se sei in sede e vedi questo messaggio, disattiva eventuali VPN e riprova.</p>
</main>
</body>
</html>`;

export async function onRequest(context){
    const paesi = String(context.env.PAESI_CONSENTITI || PAESI_PREDEFINITI)
        .split(",")
        .map(p => p.trim().toUpperCase())
        .filter(Boolean);

    const paese = context.request.cf && context.request.cf.country;

    if(!paese || !paesi.includes(paese)){
        return new Response(PAGINA_BLOCCATA, {
            status: 403,
            headers: {
                "Content-Type": "text/html; charset=utf-8",
                "Cache-Control": "no-store",
                "X-Robots-Tag": "noindex, nofollow",
                "X-Frame-Options": "DENY",
                "X-Content-Type-Options": "nosniff"
            }
        });
    }

    return context.next();
}
