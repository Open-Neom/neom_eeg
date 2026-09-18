import 'package:flutter_test/flutter_test.dart';
import 'package:neom_eeg/data/hub/eeg_driver_registry.dart';
import 'package:neom_eeg/data/hub/eeg_hub.dart';
import 'package:neom_eeg/data/providers/emotiv/cortex_models.dart';
import 'package:neom_eeg/data/providers/emotiv_cortex_provider.dart';
import 'package:neom_eeg/domain/enums/eeg_device_type.dart';
import 'package:neom_eeg/domain/enums/eeg_vendor.dart';
import 'package:neom_eeg/domain/models/eeg_exceptions.dart';
import 'package:neom_eeg/domain/models/eeg_recording.dart';
import 'package:neom_eeg/domain/models/emotiv_cortex_config.dart';

import 'support/fake_cortex_transport.dart';
import 'support/fake_eeg_driver.dart';

void main() {
  late FakeCortexTransport cortex;
  late EmotivCortexProvider provider;

  const config = EmotivCortexConfig(
    clientId: 'neom-client',
    clientSecret: 'neom-secret',
    accessPollInterval: Duration(milliseconds: 50),
    requestTimeout: Duration(seconds: 1),
  );

  setUp(() {
    cortex = FakeCortexTransport();
    provider = EmotivCortexProvider(config: config, transport: cortex);
  });

  tearDown(() async {
    await provider.dispose();
    await cortex.dispose();
  });

  Future<void> connect() async {
    final device = (await provider.scan()).single;
    await provider.connect(device);
  }

  Map<String, dynamic> lastCall(String method) =>
      cortex.requests.lastWhere((r) => r['method'] == method);

  group('records', () {
    test('markers require a connected session and an open record', () async {
      await expectLater(
        provider.addMarker(label: 'aura'),
        throwsA(isA<EegException>()),
      );
      await connect();
      await expectLater(
        provider.addMarker(label: 'aura'),
        throwsA(isA<EegException>()
            .having((e) => e.message, 'message', contains('grabación'))),
      );
      expect(cortex.markers, isEmpty);
    });

    test('start → mark → stop maps onto createRecord/injectMarker/stopRecord',
        () async {
      await connect();
      final markers = <EegMarker>[];
      final sub = provider.markerStream.listen(markers.add);

      final rec = await provider.startRecording(
        title: 'Noche 14',
        subject: 'Emmanuel',
        tags: ['insight', 'sueño'],
      );
      expect(rec.backend, EegRecordingBackend.native);
      expect(rec.id, 'rec-1');
      expect(rec.title, 'Noche 14');
      expect(rec.subject, 'Emmanuel');
      expect(rec.tags, ['insight', 'sueño']);
      expect(rec.isActive, isTrue);
      expect(provider.isRecording, isTrue);
      expect(lastCall('createRecord')['params'], {
        'cortexToken': 'tok-neom-client',
        'session': 'session-1',
        'title': 'Noche 14',
        'subjectName': 'Emmanuel',
        'tags': ['insight', 'sueño'],
      });

      final at = DateTime.utc(2026, 9, 14, 3, 12, 5, 250);
      final m = await provider.addMarker(
        label: 'aura',
        value: 3,
        at: at,
        extras: {'intensity': 'media'},
      );
      expect(m.id, 'mk-1');
      expect(m.recordingId, 'rec-1');
      expect(m.at, at);
      final inject = lastCall('injectMarker')['params'];
      expect(inject['time'], at.millisecondsSinceEpoch);
      expect(inject['value'], 3);
      expect(inject['label'], 'aura');
      expect(inject['port'], 'Software');
      expect(inject['extras'], {'intensity': 'media'});
      expect(provider.activeRecording?.markerCount, 1);

      final done = await provider.stopRecording();
      expect(done, isNotNull);
      expect(done!.isActive, isFalse);
      expect(done.markerCount, 1);
      expect(provider.isRecording, isFalse);
      expect(provider.activeRecording, isNull);
      await sub.cancel();
      expect(markers.single.label, 'aura');
    });

    test('negative integer markers are refused before reaching Cortex',
        () async {
      await connect();
      await provider.startRecording(title: 't');
      await expectLater(
        provider.addMarker(label: 'x', value: -1),
        throwsA(isA<EegException>()),
      );
      expect(cortex.markers, isEmpty);
    });

    test('starting a second recording closes the first', () async {
      await connect();
      await provider.startRecording(title: 'a');
      final b = await provider.startRecording(title: 'b');
      expect(b.id, 'rec-2');
      expect(cortex.records['rec-1']!['endDatetime'], isNotNull);
    });

    test('disconnect forgets the active record', () async {
      await connect();
      await provider.startRecording(title: 'a');
      await provider.disconnect();
      expect(provider.isRecording, isFalse);
      expect(await provider.stopRecording(), isNull);
    });

    test('listRecordings queries newest first and maps markers', () async {
      await connect();
      await provider.startRecording(title: 'uno');
      await provider.addMarker(label: 'a');
      await provider.addMarker(label: 'b');
      await provider.stopRecording();
      await provider.startRecording(title: 'dos');
      await provider.stopRecording();

      final list = await provider.listRecordings(limit: 10);
      expect(list.map((r) => r.title), ['dos', 'uno']);
      expect(list.last.markerCount, 2);
      expect(list.first.isActive, isFalse);
      final q = lastCall('queryRecords')['params'];
      expect(q['orderBy'], [{'startDatetime': 'DESC'}]);
      expect(q['limit'], 10);
    });

    test('export on desktop asks Cortex for EDF+ with the chosen streams',
        () async {
      await connect();
      final rec = await provider.startRecording(title: 'x');
      await provider.stopRecording();

      final result = await provider.exportRecordings(
        ids: [rec.id, 'missing'],
        folder: '/tmp/eeg',
        format: EegExportFormat.edfPlus,
        streams: {EegExportStream.eeg, EegExportStream.motion},
      );
      expect(result.exported, [rec.id]);
      expect(result.failed.keys, ['missing']);
      expect(result.isComplete, isFalse);
      final p = lastCall('exportRecord')['params'];
      expect(p['format'], 'EDFPLUS');
      expect(p['streamTypes'], ['EEG', 'MOTION']);
      expect(p['folder'], '/tmp/eeg');
      expect(p['version'], 'V2');
    });
  });

  group('license / info / headset', () {
    test('licenseInfo parses scopes and session quota, then caches', () async {
      await connect();
      final lic = await provider.licenseInfo();
      expect(lic.licenseName, 'EmotivPRO Developer');
      expect(lic.allowsRawEeg, isTrue);
      expect(lic.allowsHighResMetrics, isTrue);
      expect(lic.sessionRemaining, 42);
      expect(lic.isOnline, isTrue);
      expect(lic.expired, isFalse);

      cortex.licenseInfo = {'license': {'scopes': []}, 'isOnline': false};
      expect((await provider.licenseInfo()).allowsRawEeg, isTrue,
          reason: 'cached');
      expect((await provider.licenseInfo(refresh: true)).allowsRawEeg, isFalse);
    });

    test('licenseInfo works before connecting by authorizing on its own',
        () async {
      final lic = await provider.licenseInfo();
      expect(lic.licenseId, 'lic-123');
      expect(cortex.requests.map((r) => r['method']),
          containsAll(['requestAccess', 'authorize', 'getLicenseInfo']));
    });

    test('cortexInfo reports the service version', () async {
      final info = await provider.cortexInfo();
      expect(info.version, '4.4.7');
      expect(info.toString(), 'Cortex 4.4.7 (484)');
    });

    test('updateHeadsetSettings refreshes the connected device', () async {
      await connect();
      final updated = await provider.updateHeadsetSettings(
        const CortexHeadsetSettings(eegRate: 256, memsRate: 64),
      );
      expect(lastCall('updateHeadset')['params']['setting'],
          {'eegRate': 256, 'memsRate': 64});
      expect(updated.sampleRate, 256);
      expect(provider.connectedDevice?.sampleRate, 256);
    });

    test('updateHeadsetSettings surfaces the USB-cable error', () async {
      await connect();
      cortex.headsetUpdateSucceeds = false;
      await expectLater(
        provider.updateHeadsetSettings(const CortexHeadsetSettings(eegRate: 256)),
        throwsA(isA<EegProtocolException>()
            .having((e) => e.message, 'message', contains('USB'))),
      );
    });

    test('syncClock returns the adjustment', () async {
      await connect();
      expect(await provider.syncClock(), closeTo(0.0123, 1e-9));
      final p = lastCall('syncWithHeadsetClock')['params'];
      expect(p['headset'], 'INSIGHT-A1B2C3D4');
      expect(p['monotonicTime'], isA<double>());
    });

    test('createVirtualHeadset maps the Cortex type and result', () async {
      final v = await provider.createVirtualHeadset(EegDeviceType.emotivInsight);
      expect(v.type, EegDeviceType.emotivInsight);
      expect(v.channelLabels, ['AF3', 'T7', 'Pz', 'T8', 'AF4']);
      expect(v.metadata['connectedBy'], 'virtual');
      expect(lastCall('createVirtualHeadset')['params']['type'], 'INSIGHT');
      await expectLater(
        provider.createVirtualHeadset(EegDeviceType.muse),
        throwsA(isA<EegDriverUnavailableException>()),
      );
    });
  });

  group('hub routing', () {
    test('hub.recording is native for Emotiv and local for others', () async {
      final muse = FakeEegDriver(vendor: EegVendor.interaxon);
      final hub = EegHub(registry: EegDriverRegistry([provider, muse]));

      expect(hub.recording.backend, EegRecordingBackend.local,
          reason: 'nothing connected yet');

      final device = (await provider.scan()).single;
      await hub.connect(device);
      expect(hub.recording.backend, EegRecordingBackend.native);
      expect(identical(hub.recording, provider), isTrue);

      await hub.connect(FakeEegDriver.device(EegDeviceType.muse));
      expect(hub.recording.backend, EegRecordingBackend.local);

      // The provider was disposed by the registry; keep tearDown happy.
      provider = EmotivCortexProvider(config: config, transport: cortex);
      await hub.dispose();
    });
  });
}
