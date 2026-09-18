// Live check against a real Emotiv headset through EMOTIV Launcher.
//
// Skipped unless credentials are in the environment, so `flutter test`
// stays green without hardware. To run it:
//
//   EMOTIV_CLIENT_ID=… EMOTIV_CLIENT_SECRET=… \
//     flutter test test/live/cortex_insight_live_test.dart --tags live
//
// Prerequisites: EMOTIV Launcher open and logged in, headset on and visible
// in the Launcher. The first run pops an "approve this app" dialog in the
// Launcher — accept it while the test waits (it polls for 90 s).
//
// What it verifies with an Insight that lost one sensor tip: the headset
// still connects, Cortex reports that electrode with contact quality 0, the
// hub excludes it from band-power frames, and the other four keep flowing.

@Tags(['live'])
@Timeout(Duration(minutes: 4))
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neom_eeg/neom_eeg.dart';

void main() {
  final clientId = Platform.environment['EMOTIV_CLIENT_ID'] ?? '';
  final clientSecret = Platform.environment['EMOTIV_CLIENT_SECRET'] ?? '';
  final license = Platform.environment['EMOTIV_LICENSE'];
  final hasCredentials = clientId.isNotEmpty && clientSecret.isNotEmpty;

  late EegHub hub;

  setUpAll(() {
    // flutter_test pretends to be Android; the Cortex service only exists on
    // desktop, so tell the transport which OS this really is.
    debugDefaultTargetPlatformOverride = switch (Platform.operatingSystem) {
      'macos' => TargetPlatform.macOS,
      'windows' => TargetPlatform.windows,
      _ => TargetPlatform.linux,
    };
    // Make sure no test binding replaced the HttpClient factory.
    HttpOverrides.global = null;
  });

  tearDownAll(() => debugDefaultTargetPlatformOverride = null);

  setUp(() {
    hub = EegHub.standard(
      emotiv: EmotivCortexConfig(
        clientId: clientId,
        clientSecret: clientSecret,
        license: (license == null || license.isEmpty) ? null : license,
      ),
      onEmotivAccessPending: (msg) =>
          _log('⏳ Cortex: $msg  → aprueba la app en EMOTIV Launcher'),
      includeMuse: false,
      includePending: false,
      includeSimulated: false,
    );
  });

  tearDown(() => hub.dispose());

  test(
    'Insight streams through the hub and the missing tip is reported',
    () async {
      // ── Discovery ────────────────────────────────────────────────
      final report = await hub.scanDetailed(timeout: const Duration(seconds: 8));
      if (report.errors.isNotEmpty) {
        _log('❌ scan errors: ${report.errors}');
      }
      expect(report.errors, isEmpty,
          reason: '¿EMOTIV Launcher abierto y con sesión iniciada?');
      _log('🔎 headsets: ${report.devices.map((d) => '${d.id} '
          '[${d.type.displayName}, ${d.channels.length}ch @${d.sampleRate}Hz, '
          'status=${d.metadata['status']}]').join(', ')}');
      expect(report.devices, isNotEmpty, reason: 'ningún headset Emotiv visible');

      final device = report.devices.firstWhere(
        (d) => d.type == EegDeviceType.emotivInsight,
        orElse: () => report.devices.first,
      );

      // ── Connection ───────────────────────────────────────────────
      final statuses = <EegDeviceStatus>[];
      final raw = <EegSample>[];
      final frames = <List<EegBandPower>>[];
      final metrics = <EegMentalState>[];
      final subs = [
        hub.statusStream.listen(statuses.add),
        hub.rawStream.listen(raw.add),
        hub.bandPowerStream.listen(frames.add),
        hub.mentalStateStream.listen(metrics.add),
      ];

      final t0 = DateTime.now();
      await hub.connect(device);
      _log('🔗 conectado a ${hub.connectedDevice} en '
          '${DateTime.now().difference(t0).inMilliseconds} ms');
      expect(hub.connectionState, EegConnectionState.streaming);

      final driver = hub.activeDriver as EmotivCortexProvider;
      _log('📡 streams aceptados por la licencia: ${driver.activeStreams}');
      expect(driver.activeStreams, contains('dev'),
          reason: 'dev es gratuito; sin él no hay calidad de contacto');

      // ── Collect ──────────────────────────────────────────────────
      await Future<void>.delayed(const Duration(seconds: 12));
      for (final s in subs) {
        await s.cancel();
      }

      // ── Contact quality ──────────────────────────────────────────
      expect(statuses, isNotEmpty, reason: 'sin reportes dev/eq en 12 s');
      final status = statuses.last;
      final labels = hub.connectedDevice!.channelLabels;
      _log('🔋 batería ${_pct(status.battery)} · señal ${_pct(status.wirelessSignal)}'
          ' · overall ${_pct(status.overallQuality)}');
      for (final ch in labels) {
        final q = status.contactQuality[ch];
        _log('   ${ch.padRight(4)} contacto ${_bar(q)} ${_pct(q)}');
      }
      expect(status.contactQuality.keys, containsAll(labels));
      final poor = status.poorContacts(threshold: 0.25);
      _log(poor.isEmpty
          ? '✅ todos los electrodos hacen contacto'
          : '⚠️  sin contacto: $poor  (esperado: el sensor sin punta)');
      expect(hub.excludedChannels, poor,
          reason: 'el hub debe excluir exactamente los electrodos sin contacto');

      // ── Data ─────────────────────────────────────────────────────
      if (driver.activeStreams.contains('eeg')) {
        _log('🧠 raw: ${raw.length} muestras (~${(raw.length / 12).round()} Hz)');
        expect(raw.length, greaterThan(12 * 60),
            reason: 'Insight a 128 Hz debería dar >60 muestras/s');
        expect(raw.last.channels.keys, containsAll(labels));
        expect(raw.last.quality.keys, containsAll(labels),
            reason: 'CQ de dev adjunta a cada muestra');
      } else {
        _log('ℹ️  sin stream eeg: la licencia no incluye EEG crudo');
      }

      if (driver.activeStreams.contains('pow')) {
        _log('📊 band power: ${frames.length} frames');
        expect(frames, isNotEmpty);
        final last = frames.last;
        final kept = last.map((b) => b.channel).toList();
        expect(kept, isNot(containsAll(poor)),
            reason: 'los electrodos sin contacto no deben aparecer en pow');
        for (final b in last) {
          _log('   ${b.channel.padRight(4)} θ ${b.theta.toStringAsFixed(2)} '
              'α ${b.alpha.toStringAsFixed(2)} βL ${b.betaLow.toStringAsFixed(2)} '
              'βH ${b.betaHigh.toStringAsFixed(2)} γ ${b.gamma.toStringAsFixed(2)} '
              '→ ${b.dominantBand}');
        }
      } else {
        _log('ℹ️  sin stream pow: la licencia no incluye band power');
      }

      if (driver.activeStreams.contains('met')) {
        _log('🧭 métricas: ${metrics.length} reportes'
            '${metrics.isEmpty ? ' (las detecciones tardan ~10 s en activarse)' : ''}');
        if (metrics.isNotEmpty) {
          final m = metrics.last;
          _log('   eng ${_pct(m.engagement)} · rel ${_pct(m.relaxation)} · '
              'str ${_pct(m.stress)} · foc ${_pct(m.focus)} · exc ${_pct(m.excitement)}');
        }
      }

      // ── Asymmetry (the Cyberneom use case) ───────────────────────
      final hasTemporal = !poor.contains('T7') && !poor.contains('T8');
      if (frames.isNotEmpty && hasTemporal) {
        final last = frames.last;
        final t7 = last.where((b) => b.channel == 'T7').firstOrNull;
        final t8 = last.where((b) => b.channel == 'T8').firstOrNull;
        if (t7 != null && t8 != null) {
          final asym = EegSignalProcessor().computeAsymmetry(t7, t8, 'alpha');
          _log('⚖️  asimetría alfa T7/T8: índice '
              '${asym.asymmetryIndex.toStringAsFixed(3)}'
              '${asym.isSignificant ? ' (significativa)' : ''}');
        }
      } else if (!hasTemporal) {
        _log('⚠️  el sensor faltante es temporal: sin asimetría T7/T8 hasta '
            'reponer la punta');
      }

      await hub.disconnect();
      expect(hub.connectionState, EegConnectionState.disconnected);
      _log('👋 desconectado');
    },
    skip: hasCredentials
        ? false
        : 'Define EMOTIV_CLIENT_ID y EMOTIV_CLIENT_SECRET para correr contra hardware',
  );
}

void _log(String msg) => stdout.writeln(msg);

String _pct(double? v) => v == null ? '—' : '${(v * 100).round()}%';

String _bar(double? v) {
  if (v == null) return '·····';
  final n = (v * 5).round().clamp(0, 5);
  return '█' * n + '·' * (5 - n);
}
