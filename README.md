# neom_eeg

Abstracción de headsets EEG, procesamiento de señal y neurofeedback de lazo
cerrado para el ecosistema Open Neom.

**Un solo API para cualquier headset.** El consumidor no sabe si el equipo
habla Cortex JSON-RPC, un perfil GATT BLE o un puerto serie: elige el
dispositivo, el `EegHub` lo enruta al driver correcto y garantiza los mismos
tres streams (`rawStream`, `bandPowerStream`, `mentalStateStream`) sin
importar la marca.

```dart
final hub = EegHub.standard(
  emotiv: EmotivCortexConfig.fromAppProperties(),   // null → sin driver Emotiv
);

final devices = await hub.scan();                    // Emotiv + Muse + … a la vez
await hub.connect(devices.first);                    // ruteado por devices.first.type

hub.bandPowerStream.listen((frame) { /* nativo o derivado, mismo stream */ });
hub.statusStream.listen((s) => print('batería ${s.battery}, contactos ${s.poorContacts()}'));
```

## Arquitectura

```
                     ┌──────────────────────────────┐
  consumidores ───▶  │  EegHub  (EegDeviceService)   │  scan() en paralelo · connect() por modelo
  (controllers,      │  ├─ EegDriverRegistry         │  vendor → EegDriver
   adapters, UI)     │  ├─ EegBandPowerDeriver       │  FFT sobre raw cuando el driver no da bandas
                     │  └─ EegMetricsEstimator       │  métricas por ratios cuando el SDK no las da
                     └──────────┬───────────────────┘
        ┌───────────────────────┼─────────────────────────┐
        ▼                       ▼                         ▼
 EmotivCortexProvider     MuseBleProvider          EegPendingDriver ×3      SimulatedEegProvider
 (EPOC X/+ /Flex/         (Muse 2/S, GATT           (OpenBCI, BrainBit,
  Insight/MN8)             12-bit @256 Hz)           NeuroSky: declarados)
        │
   CortexClient (JSON-RPC 2.0)
        │
   CortexTransport
   ├─ CortexWebSocketTransport  → EMOTIV Launcher, wss://localhost:6868 (desktop/web)
   └─ CortexNativeTransport     → Cortex Library for Mobile vía platform channel (iOS/Android)
```

| Concepto | Clase | Qué resuelve |
|---|---|---|
| Modelo | `EegDeviceType` | canales, tasa y `vendor` por defecto; `fromCortexId()` |
| Fabricante | `EegVendor` | clave de ruteo del registro |
| Transporte | `EegTransport` | explica por qué un modelo no está disponible en esta plataforma |
| Capacidades | `EegCapabilities` | qué da el hardware (bandas nativas, métricas, calidad de contacto, motion…) |
| Salud | `EegDeviceStatus` | batería, señal, calidad de contacto por electrodo, todo en `0..1` |
| Layout | `EegChannelCatalog` | posiciones 10-20 para cualquier etiqueta que reporte el equipo |
| Contrato de driver | `EegDriver` (+ `EegDriverBase`) | `EegDeviceService` + vendor, capacidades, disponibilidad, status |

`EegBandPowerMode` controla de dónde salen las bandas: `auto` (nativas si
existen, derivadas si no), `native` (solo hardware) o `derived` (siempre el
procesador propio — útil para comparar equipos con el mismo algoritmo; también
es la única forma de tener banda **delta** con Emotiv, porque Cortex no la
publica).

## Emotiv

### Desktop (macOS / Windows / Linux) y web

1. Instala **EMOTIV Launcher** (trae el servicio Cortex) e inicia sesión con tu
   EmotivID. El servicio escucha en `wss://localhost:6868` con certificado
   autofirmado; `CortexWebSocketTransport` lo acepta solo para loopback.
   En web hay que visitar una vez `https://localhost:6868` y aceptar el
   certificado en el navegador.
2. Registra la app en <https://www.emotiv.com/my-account/cortex-apps/> y copia
   el `clientId`/`clientSecret` a `properties.json` del host:
   ```json
   "emotivClientId": "…",
   "emotivClientSecret": "…",
   "emotivLicense": ""
   ```
   `EmotivCortexConfig.fromAppProperties()` devuelve `null` si faltan, y
   `EegHub.standard` simplemente no registra el driver.
3. La primera conexión dispara `requestAccess`; el Launcher muestra un diálogo
   para aprobar la app. El driver hace polling (`accessApprovalTimeout`,
   90 s por defecto) y avisa por `onAccessPending` — `EegConnectionController`
   lo expone como `pendingMessage` y el `EegDevicePicker` lo pinta.
4. Licencia: EEG crudo y `pow` requieren una licencia con sesiones (EmotivPRO /
   developer); `authorize` debita `debit` sesiones (1 por defecto). Sin
   licencia, Cortex rechaza esos streams en `subscribe.failure` y el driver
   sigue con `met`/`dev`/`eq`/`mot`; si `createSession(active)` falla, cae a
   `open`.

Flujo implementado (verificado contra la doc de Cortex 4.x):
`getUserLogin → requestAccess (poll) → authorize → queryHeadsets → controlDevice
connect → (status connected) → createSession → subscribe`. Todos los streams se
parsean por las `cols` que Cortex declara en `subscribe`, así que Insight (5),
EPOC X (14), Flex (32) y MN8 (2) pasan por el mismo código y el orden real de
columnas — `eeg` con `COUNTER/INTERPOLATED` al frente, `pow` como
`theta/alpha/betaL/betaH/gamma`, `met` con flags `.isActive` — está cubierto
en `test/cortex_stream_parser_test.dart`.

### Móvil (iOS / Android) — Cortex Library for Mobile

Emotiv distribuye la librería embebida **bajo solicitud / beta privada**
(`EmotivCortexLib.xcframework` / `.aar`), por lo que este paquete no puede
incluirla. `CortexNativeTransport` implementa la mitad Dart del puente y habla
**dos dialectos**, eligiendo el que la app registró:

**A. Plugin oficial de Emotiv (recomendado).** [`cortex` en pub.dev](https://pub.dev/packages/cortex)
(publisher emotiv.com, v0.1.0, 2023, MIT, [Emotiv/flutter-plugin](https://github.com/Emotiv/flutter-plugin)).
Expone `startCortex()`, `authenticateWithCortex(clientId)`,
`sendRequestToCortex(json)` y los EventChannels
`dev.emotiv.cortex/response|warning|dataStream`. neom_eeg **no depende** del
paquete (su podspec exige la librería en `ios/Frameworks` y sin ella el
`pod install` falla): habla sus canales directamente. Basta agregar el plugin
y la librería al host. Ojo: el plugin está sin mantenimiento desde 2023
(AGP 4.1, compileSdk 30, minSdk 24, appauth 0.8, iOS 13) — al integrarlo en un
proyecto actual hay que subir `compileSdk`/`namespace` en su `build.gradle` y
añadir `android:extractNativeLibs="true"` al manifest (su propio changelog lo
documenta). Permisos: BLUETOOTH/ADMIN, ACCESS_FINE_LOCATION, INTERNET;
`NSBluetoothAlwaysUsageDescription` en iOS.

**B. Contrato neom_eeg.** Para hosts que embeben la librería sin el plugin:

**MethodChannel `neom_eeg/cortex`**

| método | argumentos | retorna |
|---|---|---|
| `isAvailable` | — | `bool` |
| `start` | — | completa tras `CortexLib.start` |
| `sendRequest` | `{json: String}` | — |
| `authenticate` | `{clientId: String}` | `String` código OAuth |
| `stop` | — | — |

**EventChannel `neom_eeg/cortex/messages`**: cada JSON que la librería entrega
a `processResponse`, tal cual.

Cuando `getUserLogin` viene vacío, el driver llama a `authenticate` (la
librería abre el login web de EMOTIV), recibe el código y lo cambia con
`loginWithAuthenticationCode`; el resto del flujo es idéntico al de desktop.
La librería móvil añade métodos que el servicio de escritorio no tiene:
`loginWithAuthenticationCode`, `logout`, `acceptLicense` y **headsets
virtuales** (`createVirtualHeadset` — `EmotivCortexProvider.createVirtualHeadset(EegDeviceType.emotivInsight)`
crea un Insight simulado dentro de Cortex para probar en el teléfono sin
hardware). No tiene `exportRecord`: los records grabados en móvil se exportan
desde EMOTIV Launcher/EmotivPRO en escritorio.

### Records, markers, licencia y ajustes

`EmotivCortexProvider` implementa `EegRecordingService` sobre records nativos
de Cortex: `startRecording` → `createRecord`, `addMarker` → `injectMarker`
(Cortex exige un record activo; `time` en ms epoch; `value` string o entero
≥ 0), `stopRecording` → `stopRecord`, `listRecordings` → `queryRecords`,
`exportRecordings` → `exportRecord` (CSV/EDF/EDF+/BDF+, streams
EEG/MOTION/PM/BP, `version: V2`; sólo desktop). Además:

| Método | Cortex | Para qué |
|---|---|---|
| `licenseInfo()` | `getLicenseInfo` | `scopes` explica por qué `eeg`/`pow` se rechazan (plan gratuito: sólo `met`/`mot`/`dev`/`eq`); `sessionRemaining` |
| `cortexInfo()` | `getCortexInfo` | versión del servicio/librería |
| `updateHeadsetSettings(CortexHeadsetSettings(eegRate: 256))` | `updateHeadset` | 256 Hz sólo EPOC+/EPOC X y con cable USB conectado; Insight fijo a 128 |
| `syncClock()` | `syncWithHeadsetClock` | offset reloj headset ↔ máquina para alinear markers |
| `createVirtualHeadset(type)` | `createVirtualHeadset` | headset simulado (sólo librería móvil) |

**Agnóstico por diseño:** `hub.recording` devuelve el servicio del driver
activo si lo implementa (Emotiv → nativo, visible en EmotivPRO y embebido en el
EDF) y si no, `LocalEegRecordingService` (Hive: snapshots de bandas por segundo
+ eventos; exporta CSV inline). El `EegRecordingStrip` del dashboard usa la
misma API para ambos.

<details>
<summary>Referencia Swift (iOS)</summary>

```swift
import EmotivCortexLib
import Flutter

final class NeomCortexPlugin: NSObject, FlutterPlugin, FlutterStreamHandler, CortexClientDelegate {
  private var client: CortexClient?
  private var sink: FlutterEventSink?
  private var authContinuation: ((String?, Error?) -> Void)?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = NeomCortexPlugin()
    FlutterMethodChannel(name: "neom_eeg/cortex", binaryMessenger: registrar.messenger())
      .setMethodCallHandler(instance.handle)
    FlutterEventChannel(name: "neom_eeg/cortex/messages", binaryMessenger: registrar.messenger())
      .setStreamHandler(instance)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable": result(true)
    case "start":
      CortexLib.start {
        let c = CortexClient(); c.setDelegate(self); self.client = c; result(nil)
      }
    case "sendRequest":
      client?.sendRequest((call.arguments as? [String: Any])?["json"] as? String ?? "")
      result(nil)
    case "authenticate":
      authContinuation = { code, err in err == nil ? result(code) : result(FlutterError(code: "auth", message: err?.localizedDescription, details: nil)) }
      client?.authenticate((call.arguments as? [String: Any])?["clientId"] as? String ?? "")
    case "stop": client?.close(); CortexLib.stop(); result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  // CortexClientDelegate
  func processResponse(_ responseMessage: String) { sink?(responseMessage) }
  func authenticationFinished(_ code: String, withError error: Error?) { authContinuation?(code, error); authContinuation = nil }

  // FlutterStreamHandler
  func onListen(withArguments _: Any?, eventSink: @escaping FlutterEventSink) -> FlutterError? { sink = eventSink; return nil }
  func onCancel(withArguments _: Any?) -> FlutterError? { sink = nil; return nil }
}
```
</details>

<details>
<summary>Referencia Kotlin (Android)</summary>

```kotlin
class NeomCortexPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
  private var client: CortexClient? = null
  private var sink: EventChannel.EventSink? = null

  override fun onAttachedToEngine(b: FlutterPlugin.FlutterPluginBinding) {
    MethodChannel(b.binaryMessenger, "neom_eeg/cortex").setMethodCallHandler(this)
    EventChannel(b.binaryMessenger, "neom_eeg/cortex/messages").setStreamHandler(this)
    EmotivLibraryLoader(b.applicationContext).load()
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) = when (call.method) {
    "isAvailable" -> result.success(true)
    "start" -> CortexLib.start { client = CortexClient().also { c -> c.registerResponseHandler { sink?.success(it) } }; result.success(null) }
    "sendRequest" -> { client?.sendRequest(call.argument<String>("json")); result.success(null) }
    "authenticate" -> { /* client.authenticate(activity, clientId, REQ); resolver con getAuthenticationCode en onActivityResult */ }
    "stop" -> { client?.close(); CortexLib.stop(); result.success(null) }
    else -> result.notImplemented()
  }

  override fun onListen(args: Any?, events: EventChannel.EventSink) { sink = events }
  override fun onCancel(args: Any?) { sink = null }
  override fun onDetachedFromEngine(b: FlutterPlugin.FlutterPluginBinding) {}
}
```
</details>

## Muse (Interaxon)

`MuseBleProvider` habla el perfil GATT del Muse 2 / Muse S directamente
(servicio `fe8d`, control `273e0001`, electrodos `273e0003…0006`, telemetría
`273e000b`). Cada notificación son 12 muestras de 12 bits que se reensamblan
por contador entre los cuatro electrodos; secuencia de arranque `h` → `p21` →
`s` → `d` (misma que muse-js/muse-lsl). Muse no calcula bandas: el hub las
deriva a 4 Hz con ventana de 1 s.

## Vendors pendientes

Camino más corto para casi todos: un `EegLslProvider` con `liblsl` (pub.dev,
MIT, FFI Android/iOS/desktop) — EmotivPRO, OpenBCI GUI y BrainFlow publican
raw EEG por LSL. Ver `~/codebase_eeg/README.md`.

`EegPendingDriver` deja OpenBCI, BrainBit y NeuroSky **declarados** (modelos,
canales, capacidades, transporte requerido) pero no conectables; `scan()` los
reporta en `EegScanReport.skipped` con la razón. Implementar uno es escribir
una clase que extienda `EegDriverBase` y registrarla — nada más cambia:

```dart
class OpenBciUdpProvider extends EegDriverBase {
  @override EegVendor get vendor => EegVendor.openbci;
  @override Set<EegDeviceType> get supportedTypes => EegDeviceType.ofVendor(vendor).toSet();
  @override EegCapabilities capabilitiesFor(EegDeviceType t) => const EegCapabilities(transports: {EegTransport.network});
  @override Future<List<EegDeviceInfo>> scan({Duration timeout = const Duration(seconds: 10)}) async { … }
  @override Future<void> connect(EegDeviceInfo device) async { …; emitRaw(sample); setConnectionState(EegConnectionState.streaming); }
  @override Future<void> disconnect() async { … }
}

hub.registry.register(OpenBciUdpProvider());   // reemplaza el pendiente
```

## Integración en una app

```dart
// root_binding.dart
Bind.lazyPut(() {
  late final EegConnectionController controller;
  final hub = EegHub.standard(
    emotiv: EmotivCortexConfig.fromAppProperties(),
    onEmotivAccessPending: (msg) => controller.reportPending(msg),
  );
  controller = EegConnectionController(provider: hub);
  return controller;
}, fenix: true);
```

`EegConnectionController` expone `foundDevices`, `skippedVendors`,
`failedVendors`, `pendingMessage`, `status` (batería/contactos) y
`connectFirst(EegDeviceType)` para flujos donde la app ya sabe qué headset tiene
el usuario. `EegNeuroStateAdapter` y `EegBiofeedbackAdapter` siguen recibiendo
un `EegDeviceService`; pásales el hub.

## UI: `EegLiveDashboard` y el Modo EEG de la Cámara Neom

`EegLiveDashboard` es el panel completo y agnóstico al modelo: cabecera del
headset (vendor, modelo, canales, transporte, batería), calidad de contacto
por electrodo (`EegContactQualityStrip`, marca en rojo el sensor sin punta),
topografía, medidor de bandas, balance hemisférico (`EegHemisphericBalance`,
usa el mejor par L/R del modelo: T7/T8 → TP9/TP10 → … → AF7/AF8), métricas
(`EegMetricsRow`, nativas o estimadas) y la señal cruda con selector de
canal. Desconectado muestra el `EegDevicePicker`. `EegMonitorPage` lo usa a
pantalla completa (`/eeg` en Cyberneom).

La **Cámara Neom** (neom_generator) ofrece el *Modo EEG* como una **ruta
aparte** (`AppRouteConstants.chamberNeuro` → `ChamberNeuroPage`): un layout
donde el `ChamberNeuroPanel` registrado por la app ocupa el centro y los
controles de audio se reducen a un rail (izquierda en pantallas anchas, barra
inferior en teléfono), compartiendo el mismo `NeomGeneratorController` (el
audio sigue entre páginas). **La página estándar de la Cámara no cambia en
nada**; el host decide desde dónde ofrecer la opción — Cyberneom lo hace con
un botón en el `EegMonitorPage` (`actions:`). neom_generator no importa
neom_eeg — el host registra el panel:

```dart
Sint.put<ChamberNeuroPanel>(ChamberNeuroPanel(
  id: 'eeg',
  icon: Icons.psychology,
  builder: (_) => const EegLiveDashboard(compact: true),
  statusLine: () => 'Insight · 4/5 sensores',
));
```

Sin panel registrado la ruta muestra un aviso y ofrece volver, así las apps
sin hardware no cambian. `EegChannelCatalog.bestPair()` y `EegNeuroStateAdapter` usan el
mismo par hemisférico, de modo que la coherencia que llega al
`NeuroStateService` y la que muestra el panel son la misma cifra.

## Captura por sesión y verificación en tiempo real

`EegSessionCaptureController` mantiene un buffer por segundo de todo lo que
el hub transmite mientras hay headset (muestras/s, frames/s, bandas
promediadas, coherencia hemisférica, métricas) y expone `liveStats` — el
badge **EN VIVO · N muestras/s · M frames/s · % de la tasa nominal** del
dashboard (`EegLiveStatsBadge`) es la prueba de que los datos llegan en
tiempo real; en rojo si hace >2 s que no llega nada.

De ese buffer se cortan **segmentos** (`EegSessionCapture`, Hive) alineados
con lo que hace el host: `startSegment`/`endSegment` con un `contextSampler`
(claves `EegContextKeys`: `baseHz`, `beatHz`, `effectiveHz`, `volume`,
`neuroState`, `isochronicHz`, `preset`), `annotateContext` al cambiar de
frecuencia, `noteVoice` para el micrófono (pitch detectado, inicio/fin de
captura); los marcadores de `hub.recording` y los cambios de contacto entran
solos. Una grabación iniciada desde el dashboard también genera su captura.

`EegPracticeLink` conecta cualquier host observando sus Rx sin que neom_eeg
lo conozca. Cyberneom lo hace en `CyberneomEegPracticeBridge` con la Cámara
Neom (`isPlaying`, `sessionStartedAt`, `currentFreq/currentBeat/currentOctave`,
`detectedFrequency`, `isRecording`) — el generador **no se modifica**, sólo
se observa; la captura queda bajo el mismo id `practice_<micros>` que la
Cámara da a su práctica, para cruzarlas.

`EegSessionReportPage` muestra una captura: frecuencias utilizadas con
duración, micrófono, bandas por segundo, coherencia, métricas promedio,
marcadores y contacto, cobertura (muestras recibidas ÷ esperadas). Se abre
desde el drawer del `EegMonitorPage`.

## Línea base personal y vigilante de umbrales

Casi todo lo que Cyberneom pide al EEG (modo CARE, pre-ictal,
hipofrontalidad, entrainment) necesita comparar la señal con **la del propio
sujeto**, no con valores fijos. Dos piezas agnósticas lo resuelven:

**`EegCalibrationController`** corre la rutina de reposo sobre el headset
conectado — 60 s ojos abiertos mirando un punto fijo, 30 s ojos cerrados —
y produce una `EegCalibration` por `subjectId|modelo` (Hive, caja
`eeg_calibrations`): media y desviación por banda y canal (Welford, sin
historial), nivel DC y ruido del raw (`noiseFloor`, `artifactThreshold`),
medias con ojos cerrados y la **reactividad alfa** (alfa cerrado ÷ alfa
abierto sobre electrodos posteriores; sana ≈ 1.5–3×, ≈ 1 delata mal
contacto), e índices de reposo (`frontalActivation`, `asymmetry:<banda>`).
`zScore(banda, valor)`, `indexZ`, `baselineAsymmetry`, `bandShares`,
`baselineFrame`, `isStale()`. El JSON antiguo (`baselines/noiseFloor/
artifactThreshold/calibratedAt`) sigue cargando. UI: `EegCalibrationPanel`
(estado + botón) y `showEegCalibrationSheet` (cuenta regresiva por fase y
resumen); el `subjectId` lo da el host (`() => profile.id`).

**`EegIndices`** define una vez los números que todo lo demás usa:
`shares` por banda, `asymmetry` sobre el mejor par (`EegChannelCatalog.
bestPair`), `frontalActivation` = β/(α+θ) en electrodos prefrontales/
frontales (índice de Pope 1995 restringido a frontal), `posteriorAlphaShare`,
y `compute(frame, calibration:)` → `EegLiveIndices` con z-scores,
`frontalActivationZ` e **hipofrontalidad** `(reposo − actual)/reposo` en
`0..1`. `EegChannelCatalog.regionOf/isFrontal/isPosterior` clasifican
cualquier etiqueta 10-20, así que funciona igual en Insight (AF3/AF4 + Pz),
Muse (AF7/AF8) o Ganglion (Fp1/Fp2 + O1/O2).

**`EegWatchController`** evalúa `EegWatchRule`s (datos, JSON) contra cada
frame: métrica (`asymmetry`, `coherence`, `bandZ`, `bandShare`,
`frontalActivation`, `frontalActivationZ`, `excludedChannels`), umbral,
dirección, **`sustain`** (la condición debe mantenerse N s) y `cooldown`
(un episodio largo se re-marca cada N s, no cada frame). Reglas por
defecto: asimetría sostenida 10 s (personal: distancia a la asimetría de
reposo cuando hay calibración), beta > 2σ 10 s, alfa > 1σ 20 s (info: el
objetivo se sostiene), activación frontal < −1σ 20 s (hipofrontalidad),
electrodo sin contacto 5 s. Las reglas por desviación duermen sin
calibración (`isArmed`). Al dispararse: `EegAlert` en `alertStream`/
`alerts`, **marker automático** en `hub.recording` si hay grabación
(`autoMarkers`), y nota en la captura abierta (`EegSessionCapture.alerts`,
visible en el reporte). `indices`, `active` y `holding` alimentan
`EegWatchStrip` (chips en vivo, progreso de sustain, últimos avisos,
switch de markers). `EegSessionCapture.entrainmentIndex(banda)` = share de
la banda en el último tercio ÷ primer tercio, en el reporte como
"Entrainment alfa/theta".

Ambos son opt-in: el dashboard muestra sus paneles sólo si el host registró
los controllers. Cyberneom los registra en `root_binding.dart` y los
despierta desde `CyberneomEegPracticeBridge` para que vigilen aunque el
panel EEG esté cerrado; además publica `CyberneomEegVisualSignal`
(`NeomAudioSessionSignal`) — la señal de la Cámara con `hemisphericCoherence`
medida por el EEG cuando hay headset — sin tocar el generador.

## Electrodos sin contacto

Un sensor sin punta (o levantado) sigue apareciendo en `eeg`/`pow` como ruido;
Cortex lo marca con calidad de contacto 0 en `dev`. El hub lo excluye de los
frames de band power (`minContactQuality`, 0.25 por defecto = sólo CQ 0) para
que los promedios "de toda la cabeza" de `EegNeuroStateAdapter` /
`EegMetricsEstimator` no se contaminen; `hub.excludedChannels` dice cuáles.
El raw no se filtra — cada `EegSample.quality` trae la CQ por canal.

## Tests

```bash
flutter test                       # 296 tests, sin hardware
```

### Prueba en vivo con un headset real

`test/live/cortex_insight_live_test.dart` conecta a tu Insight/EPOC a través de
EMOTIV Launcher y reporta streams aceptados por la licencia, batería, calidad
de contacto por electrodo (marca el sensor sin punta), band power por canal y
asimetría alfa T7/T8. Se salta solo si no hay credenciales.

```bash
EMOTIV_CLIENT_ID=… EMOTIV_CLIENT_SECRET=… \
  flutter test test/live/cortex_insight_live_test.dart --tags live
```

Antes: Launcher abierto y con sesión, headset encendido y visible en el
Launcher. La primera vez aparece el diálogo de aprobar la app en el Launcher;
el test espera hasta 90 s. Si `activeStreams` no incluye `eeg`/`pow`, la
licencia de la app no tiene EEG crudo (plan gratuito): `met`/`dev`/`eq`/`mot`
siguen fluyendo.

`test/support/fake_cortex_transport.dart` simula EMOTIV Launcher (respuestas
JSON-RPC, warnings 9/10/104/142, tabla de headsets, fallos de licencia), así el
handshake completo se prueba sin hardware.
