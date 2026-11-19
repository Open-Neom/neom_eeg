import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:neom_eeg/data/implementations/local_eeg_recording_service.dart';
import 'package:neom_eeg/domain/enums/eeg_device_type.dart';
import 'package:neom_eeg/domain/enums/eeg_vendor.dart';
import 'package:neom_eeg/domain/models/eeg_band_power.dart';
import 'package:neom_eeg/domain/models/eeg_exceptions.dart';
import 'package:neom_eeg/domain/models/eeg_recording.dart';

import 'support/fake_eeg_driver.dart';

void main() {
  late Directory dir;
  late FakeEegDriver muse;
  late LocalEegRecordingService service;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('neom_eeg_local_rec_');
    Hive.init(dir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  setUp(() async {
    muse = FakeEegDriver(vendor: EegVendor.interaxon);
    await muse.connect(FakeEegDriver.device(EegDeviceType.muse));
    service = LocalEegRecordingService(
      source: muse,
      deviceTypeOf: () => EegDeviceType.muse,
    );
  });

  tearDown(() async {
    await service.dispose();
    await muse.dispose();
  });

  EegBandPower bp(String ch) => EegBandPower(
        channel: ch,
        delta: 1,
        theta: 2,
        alpha: 10,
        betaLow: 3,
        betaHigh: 1,
        gamma: 0.5,
        timestamp: DateTime.now(),
      );

  test('is the local backend and cannot write files itself', () {
    expect(service.backend, EegRecordingBackend.local);
    expect(service.canExportToFolder, isFalse);
    expect(service.isRecording, isFalse);
  });

  test('markers outside a recording are refused like Cortex does', () async {
    await expectLater(
      service.addMarker(label: 'aura'),
      throwsA(isA<EegException>()),
    );
  });

  test('records band-power snapshots and markers, lists and exports CSV',
      () async {
    final markers = <EegMarker>[];
    final sub = service.markerStream.listen(markers.add);

    final rec = await service.startRecording(
      title: 'Prueba Muse',
      subject: 'Emmanuel',
      tags: ['test'],
    );
    expect(rec.backend, EegRecordingBackend.local);
    expect(rec.isActive, isTrue);
    expect(rec.sampleRate, 256);
    expect(service.isRecording, isTrue);

    muse.bandPower([bp('TP9'), bp('AF7'), bp('AF8'), bp('TP10')]);
    muse.bandPower([bp('TP9'), bp('AF7'), bp('AF8'), bp('TP10')]);
    await Future<void>.delayed(Duration.zero);

    final m1 = await service.addMarker(label: 'aura', value: 1);
    final m2 = await service.addMarker(
      label: 'nota',
      value: 9,
      extras: {'texto': 'mareo leve'},
    );
    expect(m1.recordingId, rec.id);
    expect(m2.extras['texto'], 'mareo leve');
    expect(service.activeRecording?.markerCount, 2);

    final done = await service.stopRecording();
    expect(done!.isActive, isFalse);
    expect(done.markerCount, 2);
    expect(done.metadata['sampleCount'], 2);
    expect(service.isRecording, isFalse);
    await sub.cancel();
    expect(markers.map((m) => m.label), ['aura', 'nota']);

    final list = await service.listRecordings();
    final stored = list.firstWhere((r) => r.id == rec.id);
    expect(stored.title, 'Prueba Muse');
    expect(stored.subject, 'Emmanuel');
    expect(stored.tags, ['test']);
    expect(stored.markerCount, 2);
    expect(stored.metadata['deviceType'], 'muse');

    final export = await service.exportRecordings(
      ids: [rec.id, 'nope'],
      folder: '/ignored',
    );
    expect(export.exported, [rec.id]);
    expect(export.failed.keys, ['nope']);
    final csv = export.inlineCsv[rec.id]!;
    expect(csv.split('\n').first,
        'timestamp,channel,delta,theta,alpha,betaLow,betaHigh,gamma');
    expect(csv, contains('TP9'));
  });

  test('only CSV is supported locally', () async {
    final rec = await service.startRecording(title: 'x');
    await service.stopRecording();
    final export = await service.exportRecordings(
      ids: [rec.id],
      folder: '/ignored',
      format: EegExportFormat.edf,
    );
    expect(export.exported, isEmpty);
    expect(export.failed[rec.id], contains('CSV'));
  });

  test('starting again closes the previous recording', () async {
    final a = await service.startRecording(title: 'a');
    final b = await service.startRecording(title: 'b');
    expect(b.id, isNot(a.id));
    expect(service.activeRecording?.title, 'b');
  });
}
