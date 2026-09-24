# Seconda revisione: preparazione all'audit esterno

## Ultima decisione: nessuna capacità condivisa, ricarica o pausa ordinaria

L'utente rifiuta il token bucket perché crea competizione per una quota condivisa. Rimossi capacità,
refill e pausa obbligatoria per cambiare il massimo. Restano massimo per singola richiesta con
timelock e pausa d'emergenza guardian; nessun cap totale. Per aumentare senza bloccare la ricezione
si preparano prima le soglie incoming su entrambe le chain. Le soglie incoming non diminuiscono,
per preservare i messaggi precedenti. `docs/NO_RATE_LIMIT.md` descrive la versione corrente; le
sezioni successive sono cronologia. Il massimo singolo non è un limite al flusso aggregato.

Data: 23 settembre 2026. Revisione tecnica locale assistita da AI; non è un audit indipendente di terza parte.

Aggiornamento del 24 settembre: il presente rapporto contiene la cronologia della baseline e delle
verifiche successive. Il destinatario delle fee è ora modificabile dalla governance; vedere
`docs/TREASURY_CHANGE.md` e `audit/treasury-review-snapshot.json` per la modifica. L’ultimo aggiornamento fork è in `docs/TWELVE_ASSET_VALIDATION.md`.
Le affermazioni precedenti di sorgenti invariati e i conteggi precedenti si riferiscono alle rispettive
fasi storiche. Il pacchetto corrente viene rigenerato con la nuova versione; la baseline precedente
è conservata separatamente come `audit/baseline-pre-treasury-20260923.tar.gz`.

## Giudizio

**Preparazione all'audit finale: da completare con decisioni esplicite e verifiche pre-deployment. Nessun deployment mainnet è un prerequisito dell'audit.** Il criterio richiesto è una release che, dopo l'audit esterno e la correzione dei suoi rilievi, possa essere distribuita in produzione senza ulteriori scelte architetturali. Non ho riprodotto nuove vulnerabilità Critical/High/Medium sfruttabili da un soggetto privo delle autorità fidate nel perimetro esaminato. Questo risultato non dimostra l'assenza di vulnerabilità.

Non emergono correzioni bloccanti nuove ai contratti da questa seconda lettura. Restano decisioni sul modello di fiducia e verifiche da associare alla fase corretta. Una scelta di governance o una dipendenza esterna accettata non è automaticamente un bug da correggere. La precedente formulazione che richiedeva prove pubbliche della coppia Synthra prima dell'audit era troppo restrittiva ed è ritirata. L'utente esclude la pubblicazione mainnet prima dell'audit, anche per evitare di esporre anticipatamente gli indirizzi del progetto.

### Condizioni per cambiare il giudizio

| Blocco | Evidenza richiesta prima dell'audit finale |
| --- | --- |
| Integrazione pre-deployment | Test locali completi con VAA binarie firmate e verifica upstream; fork dei Core/token reali, parametri realistici, errori e retry. Dichiarare esplicitamente le parti simulate; nessun invio pubblico richiesto |
| Governance ancora da scegliere | Modello definitivo approvato e documentato; eventuali vincoli aggiuntivi su delay, ownership e riapertura implementati e testati prima del congelamento del codice |
| Recupero dopo scadenza/interruzione | Modello di recupero scelto; test di scadenza, quorum con chiavi effettivamente diverse, retry e replay in entrambe le direzioni; procedura documentata per la dipendenza dal servizio esterno |
| Configurazione e dipendenze reali | Asset/reti e policy definiti, parametri ammessi e vincoli verificati nei test; valori finali e indirizzi inseriti e controllati prima del deployment. Nessuna necessità di pubblicarli prima dell'audit |
| Operatività | Definire il perimetro di relay/keeper e monitoraggio. Se incluso nell'audit, codice completo e test con fault injection; disponibilità del servizio e connessioni produttive da verificare prima dell'attivazione |
| Release finale | Sorgenti e configurazione congelati, evidenze riproducibili e perimetro dell'audit comprensivo delle dipendenze operative; controllo conclusivo dei deployment effettivi prima dell'attivazione |

Il deployment produttivo avviene dopo l'audit e la chiusura dei rilievi. La verifica dei bytecode distribuiti, delle autorità effettive, della configurazione abbinata e il collaudo iniziale mainnet precedono l'apertura del servizio. I test pre-audit possono usare indirizzi sintetici con gli stessi ruoli e vincoli. Testnet è un'opzione se utile e autorizzata, non un obbligo implicito. Nessuna transazione pubblica è stata autorizzata o eseguita nell'ambito di questa revisione.

## Identità e perimetro

Archivio baseline esaminato, ora conservato come `audit/baseline-pre-treasury-20260923.tar.gz`.

SHA-256: `d73adc2b2c1b0c596aec41cc7edbb0ff5035d3a282db30aac28e404c530d0ed0`.

Verificati tutti i 147 file del manifest contro il filesystem e contro i membri dell'archivio: nessuna differenza. Il manifest interno coincide con quello locale. Questo rapporto è un allegato successivo, escluso dall'archivio identificato sopra; l'archivio non è stato rigenerato.

Lettura manuale degli otto file Solidity in `src/`, di `script/Deploy.s.sol`, dei test, dei principali strumenti di preflight/relay, del packaging, della CI e dei documenti di sicurezza. Controlli principali: autenticazione e domini VAA, replay per emitter/sequence, fee e backing netto, rollback, reentrancy, mint/burn, limiti e pause, metadata, configurazione e autorità.

## Questioni aperte, per priorità

### R1 — Prova di integrazione completa ancora assente

**Categoria: lacuna di validazione; necessaria prima del lancio.**

`integration/LiveFork.t.sol:84` usa attestazioni mock per il round trip. La VAA reale presente nel pacchetto appartiene a un altro emitter, parte da Robinhood e usa consistency 202. Non dimostra un trasferimento Synthra né la pubblicazione/osservazione Arc → Robinhood con i parametri previsti. L'assenza di messaggi nella ricerca storica limitata non dimostra che Arc non sia supportata.

La documentazione Wormhole consultata riporta finalità a livello 0 per Arc e Robinhood; questo è un riferimento di configurazione, non una prova operativa della coppia. Prima dell'audit si verifica la compatibilità con test locali e fork, documentando le assunzioni sui Guardian. La prova pubblica con endpoint Synthra e Guardian reali va pianificata dopo l'audit e prima dell'apertura del servizio, comprendendo fee, retry e riconciliazione. La sua assenza pre-audit non è, da sola, un blocco alla revisione finale dei contratti.

Riferimenti: `docs/INTEGRATION_REVIEW.md:16`, `:77`, `:96`; [finalità Wormhole](https://wormhole.com/docs/reference/consistency-levels/).

### R2 — Le 48 ore di timelock non sono una garanzia permanente

**Categoria: scelta di governance, confermata; non è un bypass accessibile a chiunque.**

La governance può ridurre il delay a zero o trasferire l'ownership fuori dal timelock. Una riapertura già maturata può essere eseguita subito dopo una nuova pausa del guardian. `unpause` non associa l'operazione a uno specifico episodio di pausa.

Confermati i tre casi di `test/InternalAudit.t.sol:174`, `:187` e `:198`. Riferimento implementativo: `src/WormholeEndpoint.sol:118` e le funzioni ereditate di ownership/TimelockController.

Prima di congelare il design, decidere se accettare esplicitamente questo modello e la procedura di cancellazione delle operazioni pendenti, oppure introdurre un vincolo permanente e/o una riapertura legata alla pausa corrente. La seconda opzione richiede modifiche da sottoporre all'audit.

### R3 — Un lungo ritardo può rendere inutilizzabile una VAA pendente

**Categoria: disponibilità esterna con possibile blocco indefinito dei fondi.**

La verifica passa dal Core: dopo la scadenza del Guardian set, la stessa VAA può non essere più accettata. Il test `test/SignedVAA.t.sol:213` conferma che la riconsegna fallisce e che nuove firme valide sullo stesso body ripristinano il completamento senza consentire replay.

Il test firma localmente con chiavi sintetiche: non dimostra la disponibilità del servizio reale di ri-osservazione. Non esistono un rimborso a timeout o un recupero amministrativo alternativo. Prima dell'audit si devono scegliere il modello di recupero e verificarne il comportamento nei test; la disponibilità del servizio esterno resta un'assunzione esplicita da controllare operativamente prima dell'attivazione. Aggiungere un rimborso unilaterale senza un protocollo di cancellazione remoto introdurrebbe un rischio di doppia spesa.

Riferimento esterno: [sostituzione firme Wormhole](https://wormhole.com/docs/products/messaging/tutorials/replace-signatures/).

### R4 — Parametri definitivi e controlli dell'emittente ancora da chiudere

**Categoria: requisito di configurazione e assunzione di fiducia.**

I file di deployment contengono placeholder. Peer e limiti sono immutabili dopo il setup previsto; un massimo remoto incompatibile può lasciare un deposito valido definitivamente non eseguibile. Il test `test/InternalAudit.t.sol:136` lo dimostra. `tools/preflight.py:38` già impedisce il mismatch dei limiti nei file: la mitigazione deve essere applicata anche ai valori effettivamente distribuiti prima dell'attivazione.

Il preflight richiede letture finalizzate; l'evidenza archiviata riporta che il provider Robinhood esaminato non serviva lo stato storico richiesto. Non ho rieseguito questa verifica di rete: non è una dichiarazione sullo stato corrente del provider.

Inoltre i token originali possono essere bloccati, messi in pausa, bruciati amministrativamente o aggiornati dall'emittente. In caso di deficit, `src/SourceVault.sol:79` blocca tutti i riscatti fino al ripristino del backing. È una protezione deliberata, ma non recupera le riserve sottratte. La compatibilità osservata di quattro token non sostituisce la scelta dell'asset, la revisione dei controller reali e l'accettazione del rischio dell'emittente.

Prima del perimetro definitivo: scegliere asset, Core/implementazioni, policy di finalità, limiti, treasury, Safe/guardian e modello di governance. Prima del lancio: preflight sulla coppia reale, monitoraggio, relay persistente, gestione incidenti e prova end-to-end.

## Verifiche rieseguite

| Verifica | Risultato |
| --- | --- |
| `FOUNDRY_PROFILE=audit forge test --use .tools/solc-0.8.28 --offline` | 81 test superati, 0 falliti, 0 saltati |
| Invarianti nel profilo audit | 512 run × 128 chiamate = 65.536; nessun revert inatteso |
| Test Python | 47 superati |
| `forge fmt --check` | Superato |
| `tools/verify_vendor.py` | 65 file corrispondenti ai checksum locali |
| Slither 0.11.3 sul codice attuale | 6 risultati Low sui timestamp; nessun High/Medium; tutti corrispondono al gate delle eccezioni già revisionate |
| Manifest e archivio | 147 file verificati, nessuna differenza |

Le chiamate dell'invariante includono no-op quando un'azione non è ammissibile; non equivalgono a 65.536 trasferimenti completati. Il modello usa attestazioni mock e non prova la sicurezza dei Guardian reali.

Toolchain verificata: Foundry 1.5.1, Solidity 0.8.28, Slither 0.11.3, Python 3.14.6. I log di questa esecuzione sono allegati nella directory `audit/readiness-review/`.

Non rieseguiti in questa seconda revisione: test live-fork, mutation campaign, download byte-per-byte degli upstream, coverage e gas report. Le relative evidenze preesistenti sono state esaminate come evidenze archiviate, non presentate come nuove esecuzioni. Il checksum locale delle dipendenze non equivale a una nuova verifica upstream. Nessun deploy, firma o transazione pubblica è stato effettuato.

Consultati anche la [specifica ERC-8056](https://eips.ethereum.org/EIPS/eip-8056), l'[elenco ufficiale dei bug Solidity](https://raw.githubusercontent.com/ethereum/solidity/develop/docs/bugs.json) e gli [advisory OpenZeppelin](https://github.com/OpenZeppelin/openzeppelin-contracts/security/advisories). Non è stata riprodotta una vulnerabilità applicabile ai contratti da queste verifiche; ciò non costituisce un audit delle dipendenze o dei Core live.

## Consegna all'auditor

Prima dell'audit finale chiudere le decisioni di progetto, completare i test pertinenti e congelare sorgenti, schema di configurazione, vincoli dei parametri e procedure. Non occorre distribuire Synthra in mainnet o rendere pubblici gli indirizzi operativi. Dopo l'audit restano la correzione e il retest dei rilievi, il deployment verificato, i controlli della configurazione effettiva e il collaudo iniziale prima dell'apertura del servizio. I limiti dei test sulle dipendenze esterne devono essere dichiarati, senza trasformarli in richieste di pubblicazione pre-audit.

I contratti e gli script operativi non sono stati modificati. Nel seguito della revisione sono stati aggiunti due test di rotazione con chiavi Guardian diverse per mint e riscatto in `test/SignedVAA.t.sol`; l'archivio precedente resta la baseline e dovrà essere rigenerato alla chiusura del lavoro. Il confronto dei 147 file descritto sopra si riferisce allo stato precedente a questa aggiunta.

### Esito dei test aggiunti

La suite firmata ora contiene 15 test, tutti superati. Il profilo audit completo è stato rieseguito: **83 test superati, 0 falliti, 0 saltati**, incluse le 65.536 chiamate dell'invariante. Il controllo di formattazione del file modificato è superato. Log: `audit/readiness-review/forge-audit-expanded.log`.

Le prove aggiunte verificano separatamente il mint pendente e il rilascio delle riserve dopo la rotazione verso quattro chiavi diverse: la VAA scaduta fallisce, le vecchie chiavi non autorizzano il nuovo set, il quorum nuovo completa la richiesta originale e il replay non produce un secondo mint o pagamento. Le firme sono generate solo nel test e verificate dal codice Wormhole upstream incluso. Non rappresentano una prova di disponibilità del servizio pubblico.

Restano in attesa delle risposte dell'utente il modello definitivo di governance, la scelta del recupero e la definizione dei parametri della release. Nessuna scelta architetturale è stata applicata implicitamente.

### Aggiornamento dopo le preferenze dell'utente

L'utente richiede accesso quanto più permissionless possibile, nessun cap totale, nessun massimo per trasferimento e almeno dieci stock estendibili. Il recupero attuale è accettabile per l'utente solo se sicuro: va distinta la correttezza del retry dalla disponibilità futura dei Guardian e dell'emittente. Il token bucket resta una decisione da risolvere perché una capacità finita introduce un massimo effettivo anche senza `maxTransfer`.

Requisiti, proposte e ricerca sui dodici candidati attivi sono in `readiness-review/PRODUCT_DECISIONS.md` e `readiness-review/initial-asset-candidates.json`. Non sono ancora modifiche ai contratti di produzione. Sono stati aggiunti due test di espansione e isolamento delle coppie con token sintetici. Il profilo audit aggiornato supera **85 test, 0 fallimenti e 0 test saltati**; formattazione dei due file di test modificati verificata. Log: `readiness-review/forge-audit-assets.log`. L'archivio baseline non è stato rigenerato e non include queste aggiunte.

### Treasury modificabile e pausa immediata — 24 settembre

Su richiesta dell'utente è stato aggiunto `SourceVault.setFeeRecipient(next)`: solo owner,
protetto dalla reentrancy, indirizzi non validi rifiutati, evento con destinatario precedente e nuovo.
Il deployment assegna l'ownership al timelock. Il cambio si applica alle fee dei depositi successivi,
senza modificare aliquota, backing, richieste pendenti o fee già pagate. Il guardian mantiene il
potere di pausa immediata e non può cambiare treasury o riaprire le operazioni.

Verifiche aggiornate: **92 test Solidity, 49 test Python, 17 mutazioni rilevate**, sei avvisi Low di
Slither già revisionati e nessun High/Medium. Anche coverage, gas, demo locale e formattazione
sono stati rieseguiti con `tools/check.sh`. I test live-fork precedenti non sono stati rieseguiti.
La dipendenza da Wormhole è stata esplicitamente accettata dall'utente. Restano separati i requisiti
sui limiti quantitativi e le proposte di rendere permanente il minimo del timelock: non sono stati
implementati nel cambiamento della treasury.

## Aggiornamento: limiti conservati e dodici stock verificati — 24 settembre

La preferenza iniziale di eliminare cap e massimo è superata: l’utente accetta di mantenerli per
sicurezza. Cap, massimo per trasferimento e token bucket restano nel codice; i valori produttivi
vanno ancora dimensionati. Non è necessaria una riscrittura per eliminare questi controlli.

Eseguita la suite fork sul codice corrente: **19 test superati, 0 falliti, 0 saltati**. Tutti i dodici
stock scelti passano deposito, fee, rotazione treasury, metadata e ritorno con attestazioni simulate,
oltre a quattro scenari di interferenza per asset. Registro e identità verificati; nessuna transazione
pubblica. La precedente indicazione di mancata riesecuzione fork non descrive più lo stato attuale.
Vedere `docs/TWELVE_ASSET_VALIDATION.md` e `audit/twelve-asset-review-snapshot.json`. La baseline
locale 92/49/17 resta riferita agli stessi sorgenti; gli hash degli input della campagna mutation
sono stati ricontrollati. Questo chiude la verifica di compatibilità richiesta, senza certificare
disponibilità futura dei Guardian, autorizzazioni dell’emittente o configurazione di lancio.

## Ultima decisione: rimozione del solo cap totale — 24 settembre

La decisione di mantenere tutti e tre i limiti è stata superata da una nuova richiesta esplicita.
Rimossi `reserveCap`, `supplyCap`, relativi controlli e parametro di deployment `capRaw`; restano
massimo per trasferimento e bucket temporale. Aggiornati deploy, preflight e test di conservazione.
Questa revisione modifica SourceVault e DestinationBridge e richiede evidenze nuove per l'audit.
Il checkpoint precedente è conservato in `audit/baseline-before-total-cap-removal-20260924.tar.gz`.
Risultati della nuova versione e limiti residui: `docs/TOTAL_CAP_REMOVAL.md`.

## Massimo modificabile tramite timelock — 24 settembre

Aggiunto `WormholeEndpoint.setMaxTransfer`, solo owner/timelock, nonReentrant e con outbound in pausa.
La capacità e il refill non cambiano; i bucket non vengono ricaricati. `inboundMaxTransfer` conserva
il massimo storico affinché riduzioni successive non rendano non eseguibili le richieste precedenti.
La modifica richiede coordinamento tra le chain e preflight dei due valori. Rimane assente il cap totale.
Il checkpoint precedente è in `audit/baseline-before-mutable-transfer-limit-20260924.tar.gz`.
Dettagli e verifiche aggiornate: `docs/TRANSFER_LIMIT_GOVERNANCE.md`.
