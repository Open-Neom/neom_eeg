import 'package:flutter_test/flutter_test.dart';
import 'package:neom_eeg/data/providers/emotiv/cortex_client.dart';
import 'package:neom_eeg/data/providers/emotiv_cortex_provider.dart';
import 'package:neom_eeg/domain/enums/eeg_connection_state.dart';
import 'package:neom_eeg/domain/enums/eeg_device_type.dart';
import 'package:neom_eeg/domain/enums/eeg_transport.dart';
import 'package:neom_eeg/domain/enums/eeg_vendor.dart';
import 'package:neom_eeg/domain/models/eeg_exceptions.dart';
import 'package:neom_eeg/domain/models/emotiv_cortex_config.dart';

import 'support/fake_cortex_transport.dart';

void main() {
  late FakeCortexTransport cortex;
  late EmotivCortexProvider provider;

  const config = EmotivCortexConfig(
    clientId: 'neom-client',
    clientSecret: 'neom-secret',
    accessApprovalTimeout: Duration(seconds: 2),
    accessPollInterval: Duration(milliseconds: 50),
    headsetConnectTimeout: Duration(seconds: 3),
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

  List<String> methods() =>
      cortex.requests.map((r) => r['method'] as String).toList();

  group('driver identity', () {
    test('serves every Emotiv model and nothing else', () {
      expect(provider.vendor, EegVendor.emotiv);
      expect(provider.supportedTypes,
          EegDeviceType.ofVendor(EegVendor.emotiv).toSet());
      expect(provider.supports(EegDeviceType.muse), isFalse);
    });

    test('Cortex computes band power and metrics on its side', () {
      final caps = provider.capabilitiesFor(EegDeviceType.emotivInsight);
      expect(caps.nativeBandPower, isTrue);
      expect(caps.nativeMentalMetrics, isTrue);
      expect(caps.contactQuality, isTrue);
      expect(caps.temporalCoverage, isTrue, reason: 'Insight has T7/T8');
      expect(provider.capabilitiesFor(EegDeviceType.emotivMn8).temporalCoverage,
          isFalse);
      expect(caps.transports,
          {EegTransport.cortexService, EegTransport.cortexLibrary});
    });

    test('is unavailable without credentials or without a transport', () {
      final blank = EmotivCortexProvider(
        config: const EmotivCortexConfig(clientId: '', clientSecret: ''),
        transport: cortex,
      );
      expect(blank.isAvailable, isFalse);
      expect(blank.unavailableReason, contains('emotivClientId'));

      cortex.supported = false;
      cortex.unsupportedText = 'no Launcher here';
      expect(provider.isAvailable, isFalse);
      expect(provider.unavailableReason, 'no Launcher here');
    });
  });

  group('scan', () {
    test('refreshes, waits for scan-finished, maps headsets', () async {
      final devices = await provider.scan();

      expect(methods(), ['getUserLogin', 'controlDevice', 'queryHeadsets']);
      expect(cortex.requests[1]['params'], {'command': 'refresh'});

      expect(devices, hasLength(1));
      final d = devices.first;
      expect(d.id, 'INSIGHT-A1B2C3D4');
      expect(d.name, 'Insight de Emmanuel');
      expect(d.type, EegDeviceType.emotivInsight);
      expect(d.channelLabels, ['AF3', 'T7', 'Pz', 'T8', 'AF4']);
      expect(d.sampleRate, 128);
      expect(d.firmwareVersion, '3.1');
      expect(d.transport, EegTransport.cortexService);
      expect(d.metadata['status'], 'discovered');
      expect(provider.connectionState, EegConnectionState.disconnected);
    });

    test('resolves model from id when settings.mode is absent', () async {
      cortex.headsets = [
        {'id': 'EPOCX-E5020A3F', 'status': 'connected',
          'sensors': <String>[], 'settings': {'eegRate': 256}},
      ];
      final d = (await provider.scan()).single;
      expect(d.type, EegDeviceType.emotivEpocX);
      expect(d.channels.length, 14, reason: 'catalog fallback');
      expect(d.sampleRate, 256);
      expect(d.name, 'EPOCX-E5020A3F');
    });

    test('requires a logged-in user on desktop', () async {
      cortex.users = [];
      expect(provider.scan(), throwsA(isA<EegAccessDeniedException>()));
    });

    test('on mobile, logs in through the OAuth code the library returns',
        () async {
      cortex.users = [];
      cortex.authenticationCode = 'oauth-123';
      await provider.scan();
      final login = cortex.requests
          .firstWhere((r) => r['method'] == 'loginWithAuthenticationCode');
      expect(login['params'], {
        'clientId': 'neom-client',
        'clientSecret': 'neom-secret',
        'code': 'oauth-123',
      });
    });
  });

  group('connect handshake', () {
    test('follows requestAccess → authorize → connect → session → subscribe',
        () async {
      final device = (await provider.scan()).single;
      cortex.requests.clear();

      await provider.connect(device);

      expect(methods(), [
        'getUserLogin',
        'requestAccess',
        'authorize',
        'queryHeadsets',
        'controlDevice',
        'queryHeadsets',
        'createSession',
        'syncWithHeadsetClock', // official practice: right after the session
        'subscribe',
      ]);
      final sync = cortex.requests[7]['params'];
      expect(sync['headset'], 'INSIGHT-A1B2C3D4');
      expect(sync['monotonicTime'], isA<double>());
      expect(sync['systemTime'], isA<double>());
      expect(provider.clockAdjustment, closeTo(0.0123, 1e-9));
      expect(cortex.requests[2]['params'], {
        'clientId': 'neom-client',
        'clientSecret': 'neom-secret',
        'debit': 1,
      });
      expect(cortex.requests[4]['params'],
          {'command': 'connect', 'headset': 'INSIGHT-A1B2C3D4'});
      expect(cortex.requests[6]['params'], {
        'cortexToken': 'tok-neom-client',
        'headset': 'INSIGHT-A1B2C3D4',
        'status': 'active',
      });
      expect(cortex.requests[8]['params']['streams'],
          ['eeg', 'pow', 'met', 'dev', 'eq', 'mot']);
      expect(provider.connectionState, EegConnectionState.streaming);
      expect(provider.connectedDevice?.metadata['status'], 'connected');
    });

    test('skips controlDevice when the headset is already connected',
        () async {
      cortex.headsets.first['status'] = 'connected';
      final device = (await provider.scan()).single;
      cortex.requests.clear();
      await provider.connect(device);
      expect(methods(), isNot(contains('controlDevice')));
    });

    test('polls requestAccess until the user approves in the Launcher',
        () async {
      cortex.accessDeniedCalls = 2;
      final pending = <String>[];
      provider = EmotivCortexProvider(
        config: config,
        transport: cortex,
        onAccessPending: pending.add,
      );
      final device = (await provider.scan()).single;

      await provider.connect(device);

      expect(pending, hasLength(2));
      expect(pending.first, contains('not granted'));
      expect(methods().where((m) => m == 'requestAccess').length, 3);
      expect(provider.connectionState, EegConnectionState.streaming);
    });

    test('warning 9 short-circuits the approval poll', () async {
      cortex.accessDeniedCalls = 100;
      final device = (await provider.scan()).single;
      final connecting = provider.connect(device);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // Test double: after the warning the fake still says "denied", so
      // the provider must trust the warning rather than poll again.
      cortex.accessDeniedCalls = 0;
      cortex.pushWarning(CortexWarning.accessGranted, 'granted');
      await connecting;
      expect(provider.connectionState, EegConnectionState.streaming);
    });

    test('gives up on approval after the configured timeout', () async {
      cortex.accessDeniedCalls = 1000;
      final device = (await provider.scan()).single;
      await expectLater(
        provider.connect(device),
        throwsA(isA<EegAccessDeniedException>()),
      );
      expect(provider.connectionState, EegConnectionState.error);
      expect(provider.connectedDevice, isNull);
    });

    test('warning 10 (declined) fails immediately', () async {
      cortex.accessDeniedCalls = 1000;
      final device = (await provider.scan()).single;
      final connecting = provider.connect(device);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      cortex.pushWarning(CortexWarning.accessDeclined, 'declined');
      await expectLater(connecting, throwsA(isA<EegAccessDeniedException>()));
    });

    test('EULA warning from authorize is surfaced as access denied',
        () async {
      cortex.eulaWarning = {
        'code': 17,
        'message': 'User has not accepted EULA',
        'licenseUrl': 'https://www.emotiv.com/eula',
      };
      final device = (await provider.scan()).single;
      await expectLater(
        provider.connect(device),
        throwsA(isA<EegAccessDeniedException>().having(
          (e) => e.message, 'message', contains('emotiv.com/eula'),
        )),
      );
    });

    test('falls back to an "open" session when the license has no sessions',
        () async {
      cortex.activeSessionError = {'code': -32019, 'message': 'No session left'};
      final device = (await provider.scan()).single;
      await provider.connect(device);
      final sessions = cortex.requests.where((r) => r['method'] == 'createSession');
      expect(sessions.map((r) => r['params']['status']), ['active', 'open']);
      expect(provider.connectionState, EegConnectionState.streaming);
    });

    test('keeps streaming with the streams the license allows', () async {
      cortex.failStreams = {'eeg', 'pow'};
      final device = (await provider.scan()).single;
      await provider.connect(device);
      expect(provider.connectionState, EegConnectionState.streaming);
    });

    test('fails when the license allows no stream at all', () async {
      cortex.failStreams = {'eeg', 'pow', 'met', 'dev', 'eq', 'mot'};
      final device = (await provider.scan()).single;
      await expectLater(
        provider.connect(device),
        throwsA(isA<EegAccessDeniedException>()),
      );
    });

    test('headset connection failure warning aborts the connect', () async {
      cortex.connectSucceeds = false;
      cortex.connectWarningCode = CortexWarning.headsetConnectTimeout;
      final device = (await provider.scan()).single;
      await expectLater(provider.connect(device), throwsA(isA<EegException>()));
      expect(provider.connectionState, EegConnectionState.error);
    });

    test('refuses non-Emotiv devices before touching the transport',
        () async {
      final device = (await provider.scan()).single;
      cortex.requests.clear();
      await expectLater(
        provider.connect(device.copyWith(type: EegDeviceType.muse)),
        throwsA(isA<EegDriverUnavailableException>()),
      );
      expect(cortex.requests, isEmpty);
    });
  });

  group('streaming', () {
    test('parses eeg/pow/met/dev by the subscribed cols', () async {
      final device = (await provider.scan()).single;
      await provider.connect(device);

      final raw = provider.rawStream.first;
      final pow = provider.bandPowerStream.first;
      final met = provider.mentalStateStream.first;
      final status = provider.statusStream.first;

      cortex.pushSample('dev', [4, 0.9, [4, 4, 2, 4, 4, 90], 95]);
      cortex.pushSample('eeg', [7, 0, 4101.0, 4102.0, 4103.0, 4104.0, 4105.0,
        0, 0, []]);
      cortex.pushSample('pow', List.generate(25, (i) => i.toDouble()));
      cortex.pushSample('met', [true, 0.6, true, 0.4, 0.5, true, 0.3,
        true, 0.7, true, 0.5, true, 0.8]);

      final s = await raw;
      expect(s.channels, {
        'AF3': 4101.0, 'T7': 4102.0, 'Pz': 4103.0, 'T8': 4104.0, 'AF4': 4105.0,
      });
      expect(s.quality['Pz'], 0.5, reason: 'dev CQ 2/4 attached to raw');

      final p = await pow;
      expect(p.map((b) => b.channel), ['AF3', 'T7', 'Pz', 'T8', 'AF4']);
      expect(p[1].theta, 5.0);
      expect(p[1].betaHigh, 8.0);

      final m = await met;
      expect(m.focus, 0.8);
      expect(m.stress, 0.3);

      final st = await status;
      expect(st.battery, closeTo(0.95, 1e-9));
      expect(st.overallQuality, closeTo(0.9, 1e-9));
    });

    test('ignores samples for streams that were not subscribed', () async {
      cortex.failStreams = {'pow'};
      final device = (await provider.scan()).single;
      await provider.connect(device);

      var got = 0;
      final sub = provider.bandPowerStream.listen((_) => got++);
      cortex.pushSample('pow', List.generate(25, (i) => 1.0));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();
      expect(got, 0);
    });

    test('non-JSON and unknown messages are dropped silently', () async {
      final device = (await provider.scan()).single;
      await provider.connect(device);
      cortex.pushRaw('not json');
      cortex.pushRaw('{"jsonrpc":"2.0","id":999,"result":{}}');
      cortex.pushRaw('{"something":"else"}');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(provider.connectionState, EegConnectionState.streaming);
    });
  });

  group('lifecycle', () {
    test('disconnect closes the session and the transport', () async {
      final device = (await provider.scan()).single;
      await provider.connect(device);
      cortex.requests.clear();

      await provider.disconnect();

      expect(methods(), ['updateSession']);
      expect(cortex.requests.single['params']['status'], 'close');
      expect(cortex.isOpen, isFalse);
      expect(provider.connectionState, EegConnectionState.disconnected);
      expect(provider.connectedDevice, isNull);
    });

    test('headset-disconnected warning flips state to error', () async {
      final device = (await provider.scan()).single;
      await provider.connect(device);
      final next = provider.connectionStateStream.first;
      cortex.pushWarning(CortexWarning.headsetDisconnected,
          {'headsetId': 'INSIGHT-A1B2C3D4'});
      expect(await next, EegConnectionState.error);
    });

    test('session auto-closed warning flips state to disconnected',
        () async {
      final device = (await provider.scan()).single;
      await provider.connect(device);
      final next = provider.connectionStateStream.first;
      cortex.pushWarning(CortexWarning.sessionClosed, 'closed');
      expect(await next, EegConnectionState.disconnected);
    });

    test('Launcher going away is reported as disconnected', () async {
      final device = (await provider.scan()).single;
      await provider.connect(device);
      final next = provider.connectionStateStream.first;
      cortex.dropConnection();
      expect(await next, EegConnectionState.disconnected);
    });

    test('a request that never gets an answer times out', () async {
      final client = CortexClient(
        _SilentTransport(),
        requestTimeout: const Duration(milliseconds: 30),
      );
      await client.open();
      await expectLater(
        client.call('getCortexInfo'),
        throwsA(isA<EegTimeoutException>()),
      );
      await client.dispose();
    });
  });
}

/// Transport that accepts requests and never replies.
class _SilentTransport extends FakeCortexTransport {
  @override
  void send(String json) {}
}
