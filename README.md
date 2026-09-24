# Synthra RWA Bridge — audit candidate

Protocollo permissionless per trasferire la rappresentazione di **un asset originale per coppia**
Robinhood → Arc e riscattarla sulla chain sorgente. Contratti non aggiornabili, saldi raw 1:1,
nessuna allowlist, blacklist o funzione di prelievo amministrativo nei contratti Synthra.
I token originali restano soggetti ai poteri di blocco, pausa, burn e upgrade dell’emittente.

**Commissione Synthra: 0,5% solo all'ingresso, inviata immediatamente al treasury.**
100 token depositati producono 99,5 wrapped e 0,5 token al treasury nella stessa transazione.
Il riscatto non applica fee Synthra. Fee native di rete e Wormhole restano separate.
La commissione è arrotondata per difetto nelle unità raw; l'aliquota è immutabile.
La governance può cambiare il destinatario delle fee future tramite timelock; riserve e fee già pagate
non vengono spostate. Il guardian può mettere in pausa immediatamente, senza attendere il timelock.

Questa è una **candidata per audit**, non una versione già auditata né un'autorizzazione al lancio.
Non è stato effettuato alcun deploy pubblico. La verifica iniziale di quattro token e dei Core reali è documentata; configurazione definitiva,
controlli dell’emittente e prova Synthra nelle due direzioni restano da completare.

## Documenti per l'auditor

- [Revisione interna avversa: rilievi, correzioni e condizioni aperte](docs/INTERNAL_AUDIT.md)
- [Verifiche su reti e token reali, poteri dell’emittente e limiti aperti](docs/INTEGRATION_REVIEW.md)
- [Perimetro, proprietà e dipendenze](docs/AUDIT_SCOPE.md)
- [Specifiche, formato messaggi e commissioni](docs/SPECIFICATION.md)
- [Modello di fiducia](docs/THREAT_MODEL.md)
- [Analisi statica e decisioni di sicurezza](docs/SECURITY_ANALYSIS.md)
- [Deployment, relay e risposta agli incidenti](docs/OPERATIONS.md)
- [Verifiche eseguite e limiti](docs/VALIDATION.md)
- [Manifest del pacchetto](audit/RELEASE_MANIFEST.json)

## Avvio e verifica

Prerequisiti: Foundry 1.5.1, Solidity 0.8.28, Python >=3.11. Per l'analisi statica: Slither 0.11.3.
Le dipendenze Solidity sono incluse con provenienza e checksum; non serve installare pacchetti npm.

```sh
cd /Users/jacopomosconi/uomi-swap/synthra-rwa-bridge
forge test
forge script script/LocalDemo.s.sol:LocalDemo
bash tools/check.sh
python3 tools/package_audit.py
```

In questo workspace il compilatore ufficiale è disponibile anche offline:

```sh
forge test --use .tools/solc-0.8.28 --offline
forge script script/LocalDemo.s.sol:LocalDemo --use .tools/solc-0.8.28 --offline
```

`tools/check.sh` seleziona automaticamente quel compilatore se presente. La demo non trasmette
transazioni: deposita 10 mock token, paga subito 0,05, conia 9,95 e ne riscatta 4.
Alla fine rimangono 5,95 token nel vault e 5,95 wrapped. Non aggiungere `--broadcast` alla demo.

## Architettura

| Componente | Responsabilità |
| --- | --- |
| `SourceVault` | Deposito, fee immediata, backing netto, riscatto, pubblicazione multiplier |
| `DestinationBridge` | Mint, burn, ricezione snapshot autenticati |
| `WrappedAsset` | ERC-20 permissionless; UI multiplier e conversioni separate dai saldi raw |
| `WormholeEndpoint` | Verifica VAA, domini EVM/Wormhole, peer immutabile dopo setup, replay, massimi per messaggio, pausa d’emergenza |
| `TimelockController` | Governance iniziale con ritardo minimo di 48 ore negli script di deployment |

Il guardian operativo può soltanto mettere in pausa una o entrambe le direzioni. La riapertura
richiede la governance. Le pause non congelano i trasferimenti ERC-20 del wrapped. Non è un
sistema privo di fiducia: emittente originale, finalità delle chain e Guardian/Core Wormhole
restano dipendenze; una pausa può ritardare i riscatti.

## Cosa comprende questa versione

- Lock netto / mint e burn / unlock completi, con consegna permissionless e retry.
- Fee atomica in token originale, senza diritto del treasury sulle riserve.
- Nessun cap totale di riserva/supply; massimo per trasferimento modificabile tramite timelock, senza quota condivisa o ricarica.
- Contratti inizialmente in pausa; peer configurabile una sola volta.
- Sincronizzazione di multiplier corrente e pianificato, protezione contro aggiornamenti fuori ordine,
  sostituzione/cancellazione della pianificazione, scadenza della metadata.
- Test con mock e con VAA binarie realmente firmate, verificate dal codice Wormhole upstream.
- Test stateful di solvibilità, tool di preflight a blocchi finalizzati e preparazione relay senza firma.
- Deployment di una coppia governance/endpoint per chain, CI e archivio audit riproducibile.

## Lavoro richiesto prima del lancio

L'audit può iniziare su questo perimetro. Per lanciare servono anche verifica dell'emittente e dei
contratti reali, configurazione firmata dagli operatori, test con Core/Guardian delle reti effettive,
revisione esterna e chiusura dei rilievi, monitoraggio e servizio di relay operativo.
Frontend, routing USDC e market making sono integrazioni separate dal perimetro dei contratti.
Nessun numero nel file `deployment.example.json` costituisce una raccomandazione di rischio per il lancio.

## Nessuna capacità condivisa o ricarica — 24 settembre 2026

Rimosso il token bucket: i trasferimenti non competono per una quota comune e non devono attendere
un refill. Resta il massimo per singola richiesta, modificabile tramite timelock senza pausa obbligatoria.
Prima degli aumenti si preparano le soglie di ricezione su entrambe le chain; quelle soglie non
scendono, così le richieste precedenti restano completabili. La pausa d'emergenza resta disponibile.
Il massimo singolo è divisibile in più richieste e non limita il flusso aggregato o le perdite totali.
Dettagli e test aggiornati in [NO_RATE_LIMIT.md](docs/NO_RATE_LIMIT.md).

## Cronologia: rimozione del cap totale — 24 settembre 2026

Rimossi i tetti cumulativi su riserve e supply e il parametro `capRaw`. Rimangono massimo per
trasferimento e token bucket: dopo il refill è possibile depositare ancora, senza un tetto al
totale accumulato. Conservate fee, backing, verifica dei messaggi e pausa immediata.
Dettagli e verifiche della nuova versione in [TOTAL_CAP_REMOVAL.md](docs/TOTAL_CAP_REMOVAL.md).

## Cronologia: verifica dei dodici stock — 24 settembre 2026

Tutti i dodici stock selezionati hanno superato i test con token reali su fork: 19 test complessivi,
compresi SPY come regressione aggiuntiva e due test Core/VAA. Verificati deposito, fee, cambio
treasury, metadata, riscatto e interferenze dell’emittente. Il ritorno usa attestazioni simulate;
nessuna transazione è stata inviata alle reti pubbliche. Il cap totale è stato successivamente rimosso; massimo e token bucket restano attivi;
i valori di esempio non sono limiti produttivi approvati.
Risultati, blocchi e limiti in [TWELVE_ASSET_VALIDATION.md](docs/TWELVE_ASSET_VALIDATION.md).

## Revisione interna del 23 settembre 2026

Questa sezione descrive la baseline del 23 settembre. Il 24 settembre è stata aggiunta la rotazione
della treasury: il codice corrente richiede quindi una nuova revisione esterna e non è identico alla
baseline. Dettagli e verifiche correnti in [TREASURY_CHANGE.md](docs/TREASURY_CHANGE.md).

81 test Solidity e 47 test Python superati; campagna stateful di 65.536 chiamate e 15 mutazioni
intenzionali rilevate dai test. Risolti tre rilievi Low nei controlli operativi e di analisi statica.
La logica dei contratti `src/` non è stata modificata da questa revisione. Le dipendenze incluse
sono state confrontate byte per byte con gli upstream fissati.

Questo lavoro è una revisione interna dello stesso autore, non un audit esterno indipendente.
Dieci test su fork reali confermano le interfacce dei quattro token campionati, fee e trasferimenti,
oltre a blocchi/pause/admin-burn dell’emittente. Una VAA Robinhood reale è verificata sui due Core.
Dettagli e limiti in [INTEGRATION_REVIEW.md](docs/INTEGRATION_REVIEW.md).
Restano aperte la configurazione reale, la prova Synthra completa nelle due direzioni e la scelta
esplicita del modello di governance e recupero dopo lunghi ritardi. Il timelock parte da almeno 48 ore,
ma la governance può ridurre il ritardo o trasferire l'ownership; un'operazione già maturata non
attende altre 48 ore dopo una nuova pausa. Il rapporto distingue queste proprietà dai difetti corretti.
