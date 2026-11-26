# Bar Marino

Gioco per le famiglie del progetto di educazione finanziaria nelle scuole (versione 4c).

- **Pagina del gioco:** https://barmarino.github.io/gioco/ — link personale per una famiglia: `https://barmarino.github.io/gioco/?f=CODICE`
- **Pannello ricercatori:** https://barmarino.github.io/gioco/#pannello (email e password dell'utente Supabase; l'email deve essere nella tabella `ricercatori`)

## Come è fatto

- `index.html` è tutto il gioco in un solo file: caratteri e libreria di Supabase sono inclusi, quindi il telefono parla solo con GitHub Pages e con Supabase.
- I dati stanno su Supabase (progetto in UE, Francoforte). La struttura del database, le regole d'accesso e le due funzioni usate dalle famiglie (`entra`, `salva`) sono in `supabase/setup.sql`.
- Nel database non ci sono nomi né il braccio di trattamento: solo codici. La tabella codice ↔ nome resta al team.
- In `index.html` c'è la chiave *publishable* di Supabase: è fatta per stare in una pagina pubblica. La chiave segreta e la password del database non vanno mai messe qui.

## Aggiornare il gioco

Sostituire `index.html` con la nuova versione: GitHub Pages la pubblica in un paio di minuti. Ogni versione resta nella cronologia del repository, così si sa quale versione era online in ogni momento.
