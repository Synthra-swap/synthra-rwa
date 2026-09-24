# Requisiti e proposte dopo le risposte dell'utente

## Ultima decisione: nessuna capacità condivisa, ricarica o pausa ordinaria

L'utente rifiuta il token bucket perché crea competizione per una quota condivisa. Rimossi capacità,
refill e pausa obbligatoria per cambiare il massimo. Restano massimo per singola richiesta con
timelock e pausa d'emergenza guardian; nessun cap totale. Per aumentare senza bloccare la ricezione
si preparano prima le soglie incoming su entrambe le chain. Le soglie incoming non diminuiscono,
per preservare i messaggi precedenti. `docs/NO_RATE_LIMIT.md` descrive la versione corrente; le
sezioni successive sono cronologia. Il massimo singolo non è un limite al flusso aggregato.

## Ultimo aggiornamento: massimo modificabile tramite timelock

L'utente accetta il riferimento iniziale di un importo equivalente in token alla configurazione
(circa 100.000 USD proposti) e richiede modificabilità tramite timelock. Implementato il cambio del
massimo delle nuove richieste entro la capacità fissa del bucket, senza cap totale. Capacità e
refill restano immutabili; i valori numerici produttivi vanno ancora determinati per stock. Il refill
di un'ora negli esempi è un tempo di rigenerazione, non una latenza minima di ogni trasferimento.
Il massimo storico in ingresso preserva le richieste precedenti; per i dettagli e i test vedere
`docs/TRANSFER_LIMIT_GOVERNANCE.md`. Le sezioni seguenti registrano le decisioni precedenti.

## Decisione corrente: rimuovere solo il cap totale

Nell'ultima risposta del 24 settembre l'utente richiede di togliere il tetto cumulativo, mantenendo
un massimo per trasferimento possibilmente alto. Implementato: nessun `reserveCap`/`supplyCap`;
restano massimo per operazione e bucket temporale. Il massimo alto va dimensionato per asset
insieme alla capacità del bucket; valori raw, senza oracolo USD. Nessun numero produttivo è stato
approvato implicitamente. Le precedenti scelte riportate sotto sono cronologia, non requisiti attuali.
Vedere `docs/TOTAL_CAP_REMOVAL.md` per modifica e verifiche.

## Cronologia precedente

Data: 23 settembre 2026; aggiornamento 24 settembre. Nessun deployment o invio di transazioni pubbliche.

## Requisiti espressi

- Accesso quanto più permissionless possibile, mantenendo la sicurezza.
- Modello attuale di retry/recupero: il 24 settembre l'utente ha esplicitamente accettato la dipendenza da Wormhole dopo la spiegazione dei limiti di disponibilità. Non richiedere nuovamente questa conferma; non descriverla come garanzia incondizionata di recupero o come accettazione indistinta di altri rischi.
- Almeno dieci stock iniziali, con possibilità di aggiungerne altri.
- Preferenza iniziale per nessun cap/massimo, superata il 24 settembre: l'utente accetta di mantenerli
  se motivati dalla sicurezza. La raccomandazione applicata è conservare cap, massimo e token bucket
  come difese aggiuntive; non limitano l'accesso a particolari utenti. I valori numerici di esempio
  non diventano per questo limiti produttivi approvati.
- Durata metadata: proposta di mantenere 24 ore; i valori definitivi vanno inclusi nella configurazione.
- Il 24 settembre l'utente ha richiesto la possibilità di cambiare il destinatario delle fee. Implementata
  in `SourceVault.setFeeRecipient`: solo owner, quindi timelock nel deployment previsto, per le sole fee
  future. Il guardian continua a poter mettere in pausa immediatamente senza attendere il timelock.

I contratti conservano cap, massimo e token bucket, coerentemente con la decisione aggiornata.
Non è più pianificata la loro rimozione. Separare la scelta del meccanismo dal dimensionamento dei
valori produttivi: i limiti sono immutabili per coppia e la loro verifica precede il deployment.

## Permissionless e autorità

Il timelock ritarda le operazioni amministrative, non impone 48 ore di attesa ai depositi o ai riscatti ordinari. L'accesso degli utenti può essere aperto pur mantenendo un guardian capace di sospendere una coppia in emergenza. Questo potere introduce comunque una dipendenza amministrativa: non promettere assenza assoluta di censura o di interruzioni.

Proposta da chiarire con l'utente: nessuna allowlist utenti, nessun prelievo amministrativo, nessun upgrade dei contratti; guardian multisig con solo potere di pausa; governance con almeno 48 ore permanenti per le operazioni amministrative. La gestione precisa della riapertura dopo una nuova pausa resta da scegliere; non è stata modificata.

Il requisito di treasury modificabile è implementato, con annuncio tramite evento e verifica nel
preflight. Le garanzie permanenti sulle 48 ore restano una proposta, non una proprietà del codice.
La pausa guardian non è mai passata dal timelock: il ritardo amministrativo non si applica al suo
intervento d'emergenza. Vedere `docs/TREASURY_CHANGE.md` per poteri e tempi effettivi.

## Limiti

Decisione aggiornata: mantenere i tre controlli. Il cap limita l'esposizione totale per coppia, il
massimo limita una singola operazione e il token bucket limita il flusso nel tempo. Il massimo da solo
può essere aggirato dividendo il trasferimento e non sostituisce il bucket. Nessuno dei tre garantisce
la prevenzione di ogni perdita sotto una compromissione prolungata. Non sono necessari all'identità
contabile, ma sono difese aggiuntive utili per una prima release. Il ragionamento seguente spiega
perché l'alternativa senza limiti avrebbe richiesto un diverso compromesso.

Rimuovere soltanto `reserveCap`, `supplyCap` e `maxTransfer` lascerebbe un limite effettivo pari a `rateCapacity`: un trasferimento superiore alla capacità del bucket non potrebbe mai essere eseguito, neppure aspettando. Per avere trasferimenti senza massimo con esecuzione atomica va rimosso anche quel vincolo, oppure occorre progettare consegne parziali/codate. Quest'ultima opzione aggiunge stato e complessità, ed è esterna al modello attuale.

Rimuovere il token bucket non elimina la verifica delle firme, il replay protection, il controllo di backing o la protezione dalla reentrancy. Elimina però un freno quantitativo in caso di vulnerabilità o compromissione delle dipendenze. La pausa manuale non garantisce di intervenire prima di una singola transazione dannosa. Permissionless significa accesso senza autorizzazione individuale; non implica assenza di regole uguali per tutti.

## Recupero

I test dimostrano che, ottenuto un quorum valido del nuovo Guardian set, lo stesso messaggio può essere completato una sola volta anche dopo la scadenza delle firme precedenti. Non dimostrano che un quorum sarà sempre disponibile. Restano anche i poteri dell'emittente sui token originali: una pausa, un blocco o la sottrazione delle riserve può impedire il rilascio.

Un recupero incondizionato non è garantibile con il modello attuale. Le firme nuove non possono essere generate dal relayer senza le chiavi Guardian. Un rimborso unilaterale non è sicuro se il vecchio messaggio può ancora essere completato sull'altra chain. La dipendenza da Wormhole è stata chiarita e accettata dall'utente il 24 settembre; restano da definire i poteri amministrativi e la politica delle pause.

## Metadata

Proposta iniziale: mantenere `metadataMaxAge = 24 ore`, già usato negli esempi, con pubblicazione permissionless e un keeper operativo. Alla scadenza falliscono i getter/conversioni UI; saldi raw, trasferimenti e riscatti non dipendono dalla freshness. Questa scadenza non è un limite ai fondi o alla quantità trasferibile. Non usare i metadata come oracolo di prezzo.

## Asset iniziali e aggiunta successiva

Candidati iniziali: NVDA, META, PLTR, GOOGL, AAPL, MSFT, INTC, AMZN, AMD, TSLA, COIN e AVGO. Tutti e dodici sono attivi nel registro Robinhood letto durante questa verifica, con deployment sulla chain 4663. Indirizzi ufficiali, quote e pool osservati sono salvati in `initial-asset-candidates.json` e nei tre file `selection-*.json`.

La selezione è una proposta tra tredici candidati azionari principali esaminati; non una classifica completa dei token più scambiati. I dati DEX sono snapshot dei pool restituiti dal provider, non un aggregato di tutti i pool o una media storica. Il campo Robinhood `dailyTradingVolume` riguarda il sottostante, non il volume DEX del token. Le grandezze non sono state mescolate.

Ogni asset usa una propria coppia SourceVault/DestinationBridge e un proprio WrappedAsset. Si possono aggiungere nuove coppie senza modificare o migrare quelle esistenti; il codice può riutilizzare il template auditato, mentre configurazione e compatibilità del nuovo token richiedono verifica. Il frontend/registro delle coppie ufficiali è un'integrazione separata: poter distribuire una coppia non la rende automaticamente parte dell'elenco ufficiale.

`test/AssetExpansion.t.sol` aggiunge test locali per l'introduzione di una tredicesima coppia dopo dodici coppie finanziate e per l'isolamento dei messaggi e delle pause. I token sono mock: questi test provano l'isolamento del bridge, non la compatibilità dei dodici emittenti/indirizzi reali.

Fonti pubbliche:

- https://docs.robinhood.com/chain/stock-token-apis/
- https://api.robinhood.com/rhj/assets
- https://api.robinhood.com/rhj/prices
- https://docs.dexscreener.com/api/reference
- https://wormhole.com/docs/products/messaging/tutorials/replace-signatures/

## Esecuzione sui dodici token reali — 24 settembre

Completata la verifica richiesta sui dodici stock selezionati: 19 test fork superati, zero falliti o
saltati. Dodici percorsi nominali e quattro scenari di interferenza per ciascun asset, più SPY e due
controlli Core/VAA. Registro ufficiale e UID confrontati; identità dei dodici token registrate ai
blocchi fissati. Treasury rotation inclusa. Risultati e simulazioni dichiarate in
`docs/TWELVE_ASSET_VALIDATION.md`. Nessun deployment pubblico.
