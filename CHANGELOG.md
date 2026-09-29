## 0.4.0

Correcciones de la revisión del 2026-09-22.

- **Coherencia real.** `EegSpectral` (Hann + detrend, bandas únicas en
  `EegBands`) con coherencia de Welch (MSC e imaginaria de Nolte) y umbral de
  azar al 95 % por banda; `EegCoherenceTracker` en el hub (`analysisPair`,
  `coherenceStream`, `lastCoherence`). "Coherencia" ya sólo significa eso;
  `1 − |asimetría|` se llama **simetría** en índices, captura, widgets y
  reglas. `EegNeuroStateAdapter` usa alfa y el mismo par (sin banda
  dominante ni "acuerdo entre canales") y expone `coherenceKind`; al
  desconectar emite un estado neutral.
- **Vigilante.** Media móvil exponencial (`smoothing`) + `hysteresis` por
  regla: una asimetría real de 0.33 con ruido de frames ya dispara (antes
  0 avisos en 120 s). Cada regla usa su banda (antes la asimetría ignoraba
  `rule.band`); las métricas de par se reinician si cambia el par y el aviso
  lleva el par. Métrica nueva `symmetry`; `coherence` es espectral.
  `alpha_entrained` → `alpha_over_rest` (cerrar los ojos la produce).
- **Calibración.** Rechazo de artefactos (mediana/MAD), estadística en
  log₁₀, `headZ` en σ reales de la cantidad de toda la cabeza y sólo sobre
  los electrodos compartidos, `settle` de 3 s por fase, activación frontal
  en log (media geométrica). `schemaVersion` 2; las anteriores cargan con
  `supportsZ` falso. Eliminados `zScore(banda, valor)` y `meanDeviation`.
- **Respuesta al estímulo.** La captura mide cada segundo el SNR en la
  frecuencia del pulso isocrónico o del beat binaural (8 s de raw):
  `ffrSnr/ffrHz`, `EegSessionCapture.frequencyFollowing`. `entrainmentIndex`
  → `bandShift` (cambio espectral, no entrainment). Marcador rápido **Ojos
  cerrados**.
- **Capturas `schema: 2`** con `symmetry`; las del esquema 1 migran su
  columna "coherence" a `symmetry`.
- **MN8 = T7/T8** (según `unity-plugin/Src/Types.cs` de Emotiv; antes
  AF7/AF8 y sin cobertura temporal). Nuevo `EegDeviceType.emotivMw20`;
  `INSIGHT2-…` resuelve a Insight. TP9/TP10 son temporoparietales y cuentan
  como cobertura temporal; `hasTemporalCoverage` sale del catálogo de pares.
- `extractBandPower(..., sampleRate:)`: el deriver pasa la tasa real; la
  estimación por timestamps corrige el error n/(n−1).
- Ids de `EegSessionRecorder` en µs y monótonos (dos grabaciones en el mismo
  milisegundo compartían id).

## 0.3.0 - 2026-09-22

- `EegCalibration` ampliada (desviaciones, ojos cerrados, reactividad alfa,
  índices de reposo, `zScore/indexZ/baselineAsymmetry/bandShares/baselineFrame`,
  clave `subjectId|modelo`); JSON anterior compatible.
- `EegCalibrationBuilder` (Welford por banda/canal, raw DC + ruido) y
  `EegCalibrationController` (rutina ojos abiertos/cerrados con cuenta
  regresiva, Hive `eeg_calibrations`, carga automática al conectar).
  `EegCalibrationPanel` + `showEegCalibrationSheet` en el dashboard.
- `EegIndices` / `EegLiveIndices`: shares, asimetría sobre el mejor par,
  activación frontal β/(α+θ), share alfa posterior, z-scores e
  hipofrontalidad con calibración. `EegChannelCatalog.regionOf/isFrontal/
  isPosterior/isTemporal`.
- `EegWatchRule` / `EegAlert` / `EegWatchController`: reglas con sustain y
  cooldown, umbrales personales, markers automáticos en `hub.recording`,
  notas en la captura (`EegSessionCapture.alerts`, `EegAlertNote`),
  `EegWatchStrip` en el dashboard, avisos en el reporte.
- `EegSessionCapture.entrainmentIndex(banda)` y `bandShareAt`; tiles
  "Entrainment alfa/theta" y "Avisos" en `EegSessionReportPage`.

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
