## 0.2.0

- Root CA de Emotiv pinneada en el transporte WebSocket (de
  `Emotiv/cortex-example/certificates/rootCA.pem`); loopback sólo como
  fallback.
- `syncWithHeadsetClock` automático tras `createSession` con reloj monotónico
  (práctica oficial COR-5953); `EmotivCortexProvider.clockAdjustment`.

- `EegSessionCaptureController` (buffer en vivo por segundo, `liveStats`,
  segmentos por práctica/grabación persistidos en Hive) + `EegSessionCapture`
  (bandas, coherencia, métricas, contexto de audio, voz, marcadores, contacto,
  cobertura). `EegPracticeLink` para enlazar hosts por Rx. `EegLiveStatsBadge`
  en el dashboard, `EegSessionReportPage` y lista de capturas en el monitor.
- `EegRecordingService.activeRecordingStream`.

- `CortexNativeTransport` habla el plugin oficial de Emotiv (`cortex`,
  canales `dev.emotiv.cortex/*`) además del contrato neom_eeg, con
  autodetección (`CortexBridgeDialect`).
- `EegRecordingService` (agnóstico): records + markers nativos en Emotiv
  (`createRecord/injectMarker/stopRecord/queryRecords/exportRecord`) y
  `LocalEegRecordingService` (Hive) para el resto; `hub.recording` rutea.
  `EegRecordingStrip` en el dashboard (Grabar / Aura / Síntoma / Respiración /
  Estímulo / Nota…).
- Emotiv extras: `licenseInfo()`, `cortexInfo()`, `updateHeadsetSettings()`,
  `syncClock()`, `createVirtualHeadset()`; modelos `CortexLicenseInfo`,
  `CortexInfo`, `CortexHeadsetSettings`.

- `EegMonitorPage(actions:)` para que el host enlace su Cámara en Modo EEG
  (`/chamber/neuro`) sin que el módulo conozca rutas ajenas.
- UI: `EegLiveDashboard` (panel completo agnóstico al modelo) con
  `EegContactQualityStrip`, `EegHemisphericBalance`, `EegMetricsRow`;
  `EegMonitorPage` lo reutiliza. Exportado desde el barrel.
- `EegChannelCatalog.hemisphericPairs / availablePairs / bestPair`: par L/R
  por prioridad de región para cualquier layout. `EegNeuroStateAdapter`
  calcula `coherence` como `1 − |asimetría|` sobre ese par (fallback al
  acuerdo entre canales cuando no hay par).

- `EegHub.minContactQuality`: excluye de band power los electrodos sin
  contacto (CQ 0) y expone `excludedChannels`.
- `EmotivCortexProvider.activeStreams` para diagnosticar la licencia.
- Test en vivo `test/live/cortex_insight_live_test.dart` (tag `live`, se
  salta sin `EMOTIV_CLIENT_ID`/`EMOTIV_CLIENT_SECRET`).

- `EegHub` + `EegDriverRegistry`: un solo `EegDeviceService` que escanea todos
  los vendors en paralelo y rutea `connect()` por `EegDeviceType`. Deriva band
  power (`EegBandPowerDeriver`) y métricas (`EegMetricsEstimator`) cuando el
  hardware no las entrega, según `EegCapabilities`.
- `EegDriver` / `EegDriverBase`: contrato de vendor con capacidades,
  disponibilidad por plataforma, `statusStream` (batería, calidad de contacto)
  y `connectionStateStream`.
- Emotiv reescrito: `CortexClient` JSON-RPC sobre `CortexTransport`
  (`CortexWebSocketTransport` desktop/web con certificado autofirmado de
  loopback; `CortexNativeTransport` para la Cortex Library for Mobile). Flujo
  `getUserLogin → requestAccess (poll) → authorize → controlDevice → createSession
  → subscribe`; parseo por `cols` (corrige `eeg` sin COUNTER/INTERPOLATED,
  `pow` como theta/alpha/betaL/betaH/gamma, `met` con flags `.isActive`);
  suscribe `dev`/`eq` para calidad de contacto. Soporta EPOC X/+, Flex,
  Insight, MN8 por el mismo camino.
- `MuseBleProvider` con el protocolo GATT real (12-bit, `h/p21/s/d`,
  telemetría) reemplaza a `BleGenericEegProvider`.
- `EegPendingDriver` para OpenBCI, BrainBit y NeuroSky.
- Nuevos enums `EegVendor`, `EegTransport`; `EegDeviceType` con `vendor` y
  modelos adicionales (EPOC+, Flex, Cyton+Daisy, Ganglion); `EegChannelCatalog`
  con posiciones 10-20; `EegDeviceStatus`, `EegCapabilities`, excepciones
  tipadas, `EmotivCortexConfig.fromAppProperties()`.
- `EegConnectionController` acepta el hub y expone `skippedVendors`,
  `failedVendors`, `pendingMessage`, `status`, `connectFirst`.
- Fix: `EegNeuroStateAdapter.isActive` no reconocía el estado `streaming`.
- Fix: `scan()` ya no pisa el estado `streaming` de un provider conectado.

## 0.1.0

- Versión inicial: modelos, `EegSignalProcessor` (DFT), `EmotivCortexProvider`
  básico, `SimulatedEegProvider`, adapters a neom_biofeedback / NeuroStateService,
  UI de monitor.
