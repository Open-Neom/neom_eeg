import 'dart:async';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../../domain/enums/eeg_connection_state.dart';
import '../../domain/enums/eeg_device_type.dart';
import '../../domain/enums/eeg_transport.dart';
import '../../domain/enums/eeg_vendor.dart';
import '../../domain/models/eeg_capabilities.dart';
import '../../domain/models/eeg_channel_catalog.dart';
import '../../domain/models/eeg_device_info.dart';
import '../../domain/models/eeg_device_status.dart';
import '../../domain/models/eeg_exceptions.dart';
import '../../domain/models/eeg_sample.dart';
import '../drivers/eeg_driver_base.dart';
import 'muse/muse_packet_parser.dart';

/// [EegDriver] for Interaxon Muse 2 / Muse S over BLE, speaking the GATT
/// profile directly (no Interaxon SDK involved).
///
/// The headband exposes one characteristic per electrode; each pushes
/// 12-sample packets tagged with a shared counter. The driver reassembles
/// the four channels per counter value and emits 12 [EegSample]s at 256 Hz.
///
/// Muse does no on-device spectral analysis, so [EegCapabilities]
/// advertises neither band power nor metrics: the hub derives both from
/// the raw stream.
class MuseBleProvider extends EegDriverBase {
  static const serviceUuid = '0000fe8d-0000-1000-8000-00805f9b34fb';
  static const controlUuid = '273e0001-4c4d-454d-96be-f03bac821358';
  static const telemetryUuid = '273e000b-4c4d-454d-96be-f03bac821358';

  /// Electrode characteristic → 10-20 label.
  static const electrodeUuids = {
    '273e0003-4c4d-454d-96be-f03bac821358': 'TP9',
    '273e0004-4c4d-454d-96be-f03bac821358': 'AF7',
    '273e0005-4c4d-454d-96be-f03bac821358': 'AF8',
    '273e0006-4c4d-454d-96be-f03bac821358': 'TP10',
  };

  static const sampleRate = 256;
  static const _samplePeriodUs = 1000000 ~/ sampleRate;

  final Duration connectTimeout;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _control;
  final _subs = <StreamSubscription<dynamic>>[];
  StreamSubscription<BluetoothConnectionState>? _linkSub;

  // Packet reassembly: counter → channel → samples.
  final _frames = <int, Map<String, List<double>>>{};
  int? _lastEmittedIndex;
  DateTime? _clockOrigin;
  int _clockSamples = 0;
  Map<String, double>? _lastStatusQualityRef;
  Map<String, double> _cachedFullQuality = const {
    'TP9': 1.0,
    'AF7': 1.0,
    'AF8': 1.0,
    'TP10': 1.0,
  };

  MuseBleProvider({this.connectTimeout = const Duration(seconds: 15)});

  // ── EegDriver ───────────────────────────────────────────────────────

  @override
  EegVendor get vendor => EegVendor.interaxon;

  @override
  Set<EegDeviceType> get supportedTypes => const {EegDeviceType.muse};

  @override
  EegCapabilities capabilitiesFor(EegDeviceType type) => supports(type)
      ? const EegCapabilities(
          battery: true,
          motion: true,
          temporalCoverage: true,
          transports: {EegTransport.ble},
        )
      : EegCapabilities.none;

  @override
  Future<List<EegDeviceInfo>> scan({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (!await FlutterBluePlus.isSupported) {
      throw EegDriverUnavailableException(
        'Bluetooth LE no disponible en este dispositivo',
        vendor: vendor,
      );
    }

    setConnectionState(EegConnectionState.scanning);
    final found = <String, EegDeviceInfo>{};
    final sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (!_looksLikeMuse(r)) continue;
        final id = r.device.remoteId.str;
        found[id] = EegDeviceInfo(
          id: id,
          name: r.device.platformName.isNotEmpty
              ? r.device.platformName
              : r.advertisementData.advName,
          type: EegDeviceType.muse,
          channels: EegChannelCatalog.forType(EegDeviceType.muse),
          sampleRate: sampleRate,
          battery: 0,
          signalQuality: _rssiToQuality(r.rssi),
          transport: EegTransport.ble,
          metadata: {'rssi': r.rssi},
        );
      }
    });

    try {
      await FlutterBluePlus.startScan(timeout: timeout);
      await FlutterBluePlus.isScanning.where((s) => !s).first;
    } finally {
      await sub.cancel();
      setConnectionState(
        isStreaming ? EegConnectionState.streaming : EegConnectionState.disconnected,
      );
    }
    return found.values.toList();
  }

  @override
  Future<void> connect(EegDeviceInfo device) async {
    if (!supports(device.type)) {
      throw EegDriverUnavailableException(
        '${device.type.displayName} no es un Muse',
        vendor: vendor,
        type: device.type,
      );
    }

    setConnectionState(EegConnectionState.connecting);
    setConnectedDevice(device);
    final ble = BluetoothDevice.fromId(device.id);
    _device = ble;

    try {
      await ble.connect(license: License.nonprofit, timeout: connectTimeout);
      final services = await ble.discoverServices();
      final museService = services.firstWhere(
        (s) => s.uuid.str128.toLowerCase() == serviceUuid,
        orElse: () => throw const EegProtocolException(
          'El dispositivo no expone el servicio Muse (fe8d)',
        ),
      );

      final electrodes = <BluetoothCharacteristic>[];
      BluetoothCharacteristic? telemetry;
      for (final c in museService.characteristics) {
        final uuid = c.uuid.str128.toLowerCase();
        if (uuid == controlUuid) {
          _control = c;
        } else if (uuid == telemetryUuid) {
          telemetry = c;
        } else if (electrodeUuids.containsKey(uuid)) {
          electrodes.add(c);
        }
      }
      if (_control == null || electrodes.length < 4) {
        throw const EegProtocolException(
          'Características Muse incompletas (control o electrodos)',
        );
      }

      _resetClock();
      for (final c in electrodes) {
        final label = electrodeUuids[c.uuid.str128.toLowerCase()]!;
        await c.setNotifyValue(true);
        _subs.add(c.onValueReceived.listen((b) => _onEeg(label, b)));
      }
      if (telemetry != null) {
        await telemetry.setNotifyValue(true);
        _subs.add(telemetry.onValueReceived.listen(_onTelemetry));
      }

      _linkSub = ble.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected && isStreaming) {
          setConnectionState(EegConnectionState.disconnected);
        }
      });

      // muse-js start sequence: halt, choose preset, start, resume.
      await _send('h');
      await _send('p21');
      await _send('s');
      await _send('d');

      setConnectionState(EegConnectionState.streaming);
    } catch (e) {
      setConnectionState(EegConnectionState.error);
      setConnectedDevice(null);
      await _releaseBle();
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    if (_control != null) {
      try {
        await _send('h');
      } catch (_) {
        // Link may already be gone; halting was best-effort.
      }
    }
    await _releaseBle();
    setConnectedDevice(null);
    setConnectionState(EegConnectionState.disconnected);
  }

  @override
  Future<void> dispose() async {
    await disconnect();
    await super.dispose();
  }

  // ── BLE plumbing ────────────────────────────────────────────────────

  Future<void> _send(String command) {
    final ctrl = _control;
    if (ctrl == null) {
      throw const EegException('Característica de control Muse no disponible');
    }
    return ctrl.write(
      MusePacketParser.encodeCommand(command),
      withoutResponse: true,
    );
  }

  Future<void> _releaseBle() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _linkSub?.cancel();
    _linkSub = null;
    _control = null;
    _frames.clear();
    final d = _device;
    _device = null;
    if (d != null) {
      try {
        await d.disconnect();
      } catch (_) {}
    }
  }

  bool _looksLikeMuse(ScanResult r) {
    final name = r.device.platformName.isNotEmpty
        ? r.device.platformName
        : r.advertisementData.advName;
    if (name.toLowerCase().startsWith('muse')) return true;
    return r.advertisementData.serviceUuids
        .any((g) => g.str128.toLowerCase() == serviceUuid);
  }

  static double _rssiToQuality(int rssi) =>
      ((rssi + 90) / 40).clamp(0.0, 1.0); // -90 dBm → 0, -50 dBm → 1

  // ── Packet reassembly ───────────────────────────────────────────────

  void _resetClock() {
    _frames.clear();
    _lastEmittedIndex = null;
    _clockOrigin = null;
    _clockSamples = 0;
  }

  void _onEeg(String label, List<int> bytes) {
    final packet = MusePacketParser.parseEeg(bytes);
    if (packet == null) return;

    final frame = _frames.putIfAbsent(packet.index, () => {});
    frame[label] = packet.samples;

    if (frame.length == electrodeUuids.length) {
      _emitFrame(packet.index, frame);
      _frames.remove(packet.index);
    }

    // A channel packet can be lost; flush frames left more than two
    // 16-bit counters behind (wraparound-safe) so the stream keeps moving.
    if (_frames.isNotEmpty) {
      List<int>? stale;
      for (final i in _frames.keys) {
        final diff = (packet.index - i) & 0xFFFF;
        if (diff > 2 && diff < 0x8000) {
          (stale ??= <int>[]).add(i);
        }
      }
      if (stale != null) {
        if (stale.length > 1) {
          stale.sort((a, b) {
            final da = (packet.index - a) & 0xFFFF;
            final db = (packet.index - b) & 0xFFFF;
            return db.compareTo(da); // Oldest first.
          });
        }
        for (final i in stale) {
          final pending = _frames.remove(i);
          if (pending != null) _emitFrame(i, pending);
        }
      }
      while (_frames.length > 64) {
        _frames.remove(_frames.keys.first);
      }
    }
  }

  void _emitFrame(int index, Map<String, List<double>> frame) {
    final last = _lastEmittedIndex;
    if (last != null && index <= last && last - index < 0x8000) {
      return; // Older than what we already emitted.
    }
    _lastEmittedIndex = index;

    // Timestamps run on a sample clock started at the first frame; the
    // wall clock only anchors it, so jitter in BLE delivery is not baked
    // into the data.
    _clockOrigin ??= DateTime.now();
    final origin = _clockOrigin!;
    final quality = lastStatus?.contactQuality ?? const <String, double>{};
    if (!identical(quality, _lastStatusQualityRef)) {
      _lastStatusQualityRef = quality;
      _cachedFullQuality = Map.unmodifiable({
        for (final label in electrodeUuids.values) label: quality[label] ?? 1.0,
      });
    }
    final isFullFrame = frame.length == electrodeUuids.length;
    final sharedQuality = isFullFrame
        ? _cachedFullQuality
        : Map<String, double>.unmodifiable({
            for (final ch in frame.keys) ch: quality[ch] ?? 1.0,
          });

    for (var i = 0; i < MusePacketParser.samplesPerPacket; i++) {
      final channels = <String, double>{
        for (final e in frame.entries)
          if (i < e.value.length) e.key: e.value[i],
      };
      emitRaw(EegSample(
        timestamp: origin.add(
          Duration(microseconds: _clockSamples * _samplePeriodUs),
        ),
        channels: channels,
        quality: channels.length == frame.length
            ? sharedQuality
            : {for (final ch in channels.keys) ch: quality[ch] ?? 1.0},
      ));
      _clockSamples++;
    }
  }

  void _onTelemetry(List<int> bytes) {
    final t = MusePacketParser.parseTelemetry(bytes);
    if (t == null) return;
    emitStatus(EegDeviceStatus(
      battery: t.battery,
      contactQuality: lastStatus?.contactQuality ?? const {},
      timestamp: DateTime.now(),
    ));
  }
}
