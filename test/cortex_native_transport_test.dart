// The mobile transport must work with Emotiv's own `cortex` Flutter plugin
// (dev.emotiv.cortex/*) and with the neom_eeg bridge contract, picking
// whichever the host registered. Channels are mocked with flutter_test's
// binary messenger; no native code runs here.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neom_eeg/data/providers/emotiv/cortex_native_transport.dart';
import 'package:neom_eeg/domain/models/eeg_exceptions.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const emotivMethods = MethodChannel(CortexNativeTransport.emotivMethodChannel);
  const emotivResponse = EventChannel(CortexNativeTransport.emotivResponseChannel);
  const emotivWarning = EventChannel(CortexNativeTransport.emotivWarningChannel);
  const emotivData = EventChannel(CortexNativeTransport.emotivDataStreamChannel);
  const neomMethods = MethodChannel(CortexNativeTransport.methodChannelName);
  const neomEvents = EventChannel(CortexNativeTransport.eventChannelName);

  final calls = <String, List<MethodCall>>{};

  void mockEmotivPlugin({bool startSucceeds = true}) {
    messenger.setMockMethodCallHandler(emotivMethods, (call) async {
      calls.putIfAbsent('emotiv', () => []).add(call);
      return switch (call.method) {
        'startCortex' => startSucceeds,
        'sendRequest' => null,
        'authenticate' => 'oauth-code-emotiv',
        _ => throw MissingPluginException(),
      };
    });
    messenger.setMockStreamHandler(
      emotivResponse,
      MockStreamHandler.inline(onListen: (_, sink) {
        sink.success('{"id":1,"jsonrpc":"2.0","result":{"ok":true}}');
      }),
    );
    messenger.setMockStreamHandler(
      emotivWarning,
      MockStreamHandler.inline(onListen: (_, sink) {
        sink.success('{"jsonrpc":"2.0","warning":{"code":104,"message":"x"}}');
      }),
    );
    messenger.setMockStreamHandler(
      emotivData,
      MockStreamHandler.inline(onListen: (_, sink) {
        sink.success('{"eeg":[1,0,1,2,3,4,5],"sid":"s","time":1.0}');
      }),
    );
  }

  void mockNeomBridge({bool available = true}) {
    messenger.setMockMethodCallHandler(neomMethods, (call) async {
      calls.putIfAbsent('neom', () => []).add(call);
      return switch (call.method) {
        'isAvailable' => available,
        'start' => null,
        'sendRequest' => null,
        'authenticate' => 'oauth-code-neom',
        'stop' => null,
        _ => throw MissingPluginException(),
      };
    });
    messenger.setMockStreamHandler(
      neomEvents,
      MockStreamHandler.inline(onListen: (_, sink) {
        sink.success('{"id":7,"jsonrpc":"2.0","result":{"from":"neom"}}');
      }),
    );
  }

  setUp(() {
    calls.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(emotivMethods, null);
    messenger.setMockMethodCallHandler(neomMethods, null);
    for (final ch in [emotivResponse, emotivWarning, emotivData, neomEvents]) {
      messenger.setMockStreamHandler(ch, null);
    }
  });

  test('is never supported off phones', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final t = CortexNativeTransport();
    expect(t.isSupported, isFalse);
    expect(t.unsupportedReason, contains('iOS y Android'));
  });

  test("uses Emotiv's plugin when it is the one registered", () async {
    mockEmotivPlugin();
    final t = CortexNativeTransport();
    final received = <String>[];
    t.messages.listen(received.add);

    await t.open();
    expect(t.isOpen, isTrue);
    expect(t.dialect, CortexBridgeDialect.emotivPlugin);
    expect(calls['emotiv']!.map((c) => c.method), ['startCortex']);

    t.send('{"id":1,"method":"queryHeadsets"}');
    await Future<void>.delayed(Duration.zero);
    final sent = calls['emotiv']!.last;
    expect(sent.method, 'sendRequest');
    expect(sent.arguments, {'command': '{"id":1,"method":"queryHeadsets"}'});

    // All three event channels are merged into one message stream.
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(received.length, 3);
    expect(received.any((m) => m.contains('"warning"')), isTrue);
    expect(received.any((m) => m.contains('"eeg"')), isTrue);

    expect(await t.authenticate('cid'), 'oauth-code-emotiv');
    await t.close();
    expect(t.isOpen, isFalse);
    // Emotiv's plugin has no stop; nothing else was invoked.
    expect(calls['emotiv']!.where((c) => c.method == 'stop'), isEmpty);
  });

  test('uses the neom bridge when it answers isAvailable', () async {
    mockNeomBridge();
    final t = CortexNativeTransport();
    final received = <String>[];
    t.messages.listen(received.add);

    expect(await t.probe(), isTrue);
    expect(t.dialect, CortexBridgeDialect.neom);
    expect(t.isOpen, isFalse, reason: 'probe must not start the library');

    await t.open();
    expect(calls['neom']!.map((c) => c.method), ['isAvailable', 'start']);

    t.send('{"id":2}');
    await Future<void>.delayed(Duration.zero);
    expect(calls['neom']!.last.arguments, {'json': '{"id":2}'});

    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(received, ['{"id":7,"jsonrpc":"2.0","result":{"from":"neom"}}']);

    expect(await t.authenticate('cid'), 'oauth-code-neom');
    await t.close();
    expect(calls['neom']!.last.method, 'stop');
  });

  test('prefers the neom bridge when both exist and it is available',
      () async {
    mockEmotivPlugin();
    mockNeomBridge();
    final t = CortexNativeTransport();
    await t.open();
    expect(t.dialect, CortexBridgeDialect.neom);
    expect(calls.containsKey('emotiv'), isFalse);
    await t.close();
  });

  test('falls back to the Emotiv plugin when the neom bridge says unavailable',
      () async {
    mockEmotivPlugin();
    mockNeomBridge(available: false);
    final t = CortexNativeTransport();
    await t.open();
    expect(t.dialect, CortexBridgeDialect.emotivPlugin);
    await t.close();
  });

  test('preferredDialect can force the Emotiv plugin', () async {
    mockEmotivPlugin();
    mockNeomBridge();
    final t = CortexNativeTransport(
      preferredDialect: CortexBridgeDialect.emotivPlugin,
    );
    await t.open();
    expect(t.dialect, CortexBridgeDialect.emotivPlugin);
    expect(calls.containsKey('neom'), isFalse);
    await t.close();
  });

  test('with no bridge at all, open fails and the transport turns unsupported',
      () async {
    final t = CortexNativeTransport();
    expect(t.isSupported, isTrue, reason: 'unknown until tried');
    await expectLater(t.open(), throwsA(isA<EegDriverUnavailableException>()));
    expect(t.isSupported, isFalse);
    expect(t.unsupportedReason, contains('dev.emotiv.cortex'));
  });

  test('a plugin whose startCortex returns false counts as absent', () async {
    mockEmotivPlugin(startSucceeds: false);
    final t = CortexNativeTransport();
    await expectLater(t.open(), throwsA(isA<EegDriverUnavailableException>()));
    expect(t.isOpen, isFalse);
  });
}
