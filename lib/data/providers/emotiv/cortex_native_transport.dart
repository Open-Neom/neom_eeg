import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../domain/enums/eeg_vendor.dart';
import '../../../domain/models/eeg_exceptions.dart';
import 'cortex_transport.dart';

/// Which native bridge carries the JSON to the embedded Cortex library.
enum CortexBridgeDialect {
  /// Emotiv's own Flutter plugin — `cortex` on pub.dev
  /// (github.com/Emotiv/flutter-plugin). MethodChannel
  /// `dev.emotiv.cortex/methods` with `startCortex` / `sendRequest{command}`
  /// / `authenticate{clientId}`, and three EventChannels that split the
  /// library's messages: `…/response`, `…/warning`, `…/dataStream`.
  emotivPlugin,

  /// The bridge contract documented in this package's README, for hosts
  /// that embed the library without the plugin. MethodChannel
  /// `neom_eeg/cortex` with `isAvailable` / `start` / `sendRequest{json}` /
  /// `authenticate{clientId}` / `stop`, and one EventChannel
  /// `neom_eeg/cortex/messages` with every message verbatim.
  neom,
}

/// [CortexTransport] over the Emotiv **Cortex Library for Mobile**
/// (`EmotivCortexLib.xcframework` on iOS, `EmotivCortexLib.aar` on Android).
///
/// The library is distributed by Emotiv on request (private beta) and cannot
/// be bundled here, so this class only ships the Dart half of the bridge.
/// It speaks two dialects and picks whichever the host app registered:
///
/// 1. [CortexBridgeDialect.emotivPlugin] — add Emotiv's `cortex` plugin plus
///    the library to the app and nothing else is needed.
/// 2. [CortexBridgeDialect.neom] — the host writes a small plugin against
///    the contract in the README (Swift/Kotlin reference included).
///
/// When neither is present, [isSupported] turns false after the first
/// [open] attempt and the hub simply does not offer Emotiv on that phone.
class CortexNativeTransport implements CortexTransport {
  // Emotiv plugin channels (github.com/Emotiv/flutter-plugin).
  static const emotivMethodChannel = 'dev.emotiv.cortex/methods';
  static const emotivResponseChannel = 'dev.emotiv.cortex/response';
  static const emotivWarningChannel = 'dev.emotiv.cortex/warning';
  static const emotivDataStreamChannel = 'dev.emotiv.cortex/dataStream';

  // neom_eeg contract channels.
  static const methodChannelName = 'neom_eeg/cortex';
  static const eventChannelName = 'neom_eeg/cortex/messages';

  final CortexBridgeDialect? preferredDialect;
  final MethodChannel _emotivMethods;
  final List<EventChannel> _emotivEvents;
  final MethodChannel _neomMethods;
  final EventChannel _neomEvents;

  CortexBridgeDialect? _dialect;
  final _subs = <StreamSubscription<dynamic>>[];
  bool _open = false;
  bool? _available;
  final _messages = StreamController<String>.broadcast();
  final _closed = StreamController<void>.broadcast();

  CortexNativeTransport({
    this.preferredDialect,
    MethodChannel? emotivMethods,
    List<EventChannel>? emotivEvents,
    MethodChannel? neomMethods,
    EventChannel? neomEvents,
  })  : _emotivMethods =
            emotivMethods ?? const MethodChannel(emotivMethodChannel),
        _emotivEvents = emotivEvents ??
            const [
              EventChannel(emotivResponseChannel),
              EventChannel(emotivWarningChannel),
              EventChannel(emotivDataStreamChannel),
            ],
        _neomMethods = neomMethods ?? const MethodChannel(methodChannelName),
        _neomEvents = neomEvents ?? const EventChannel(eventChannelName);

  /// Bridge that answered, once [open] (or [probe]) has run.
  CortexBridgeDialect? get dialect => _dialect;

  /// The library only exists for phones; on any other platform the answer
  /// is known without touching a channel.
  bool get _platformCanHost =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.android);

  @override
  bool get isSupported => _platformCanHost && (_available ?? true);

  @override
  String? get unsupportedReason {
    if (!_platformCanHost) {
      return 'La Cortex Library for Mobile sólo existe para iOS y Android.';
    }
    if (_available == false) {
      return 'La app no incluye EmotivCortexLib: agrega el plugin `cortex` de '
          'Emotiv (dev.emotiv.cortex) o el puente $methodChannelName.';
    }
    return null;
  }

  @override
  bool get isOpen => _open;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Stream<void> get onClosed => _closed.stream;

  /// Finds a bridge without starting the library when possible. The neom
  /// contract has a side-effect-free `isAvailable`; the Emotiv plugin has
  /// none, so its presence is only confirmed by [open].
  Future<bool> probe() async {
    if (!_platformCanHost) return _available = false;
    if (_available != null) return _available!;

    if (preferredDialect != CortexBridgeDialect.emotivPlugin) {
      try {
        final ok = await _neomMethods.invokeMethod<bool>('isAvailable') ?? false;
        if (ok) {
          _dialect = CortexBridgeDialect.neom;
          return _available = true;
        }
      } on MissingPluginException {
        // Not registered; try the other dialect.
      } on PlatformException {
        // Registered but broken; treat as absent.
      }
    }
    // Emotiv's plugin cannot be probed passively; assume present until
    // `startCortex` says otherwise.
    return _available ?? true;
  }

  @override
  Future<void> open() async {
    if (_open) return;
    if (!await probe()) {
      throw EegDriverUnavailableException(
        unsupportedReason ?? 'Cortex library not available',
        vendor: EegVendor.emotiv,
      );
    }

    final order = switch (preferredDialect ?? _dialect) {
      CortexBridgeDialect.neom => [CortexBridgeDialect.neom, CortexBridgeDialect.emotivPlugin],
      CortexBridgeDialect.emotivPlugin => [CortexBridgeDialect.emotivPlugin, CortexBridgeDialect.neom],
      null => [CortexBridgeDialect.emotivPlugin, CortexBridgeDialect.neom],
    };

    Object? lastError;
    for (final d in order) {
      try {
        await (d == CortexBridgeDialect.neom ? _openNeom() : _openEmotiv());
        _dialect = d;
        _available = true;
        _open = true;
        return;
      } on MissingPluginException catch (e) {
        lastError = e;
        await _cancelSubs();
      } on PlatformException catch (e) {
        lastError = e;
        await _cancelSubs();
      }
    }

    _available = false;
    throw EegDriverUnavailableException(
      unsupportedReason ?? 'Cortex library not available',
      vendor: EegVendor.emotiv,
      cause: lastError,
    );
  }

  Future<void> _openNeom() async {
    _subs.add(_neomEvents.receiveBroadcastStream().listen(
      _forward,
      onError: (_) => _drop(),
      onDone: _drop,
    ));
    await _neomMethods.invokeMethod<void>('start');
  }

  Future<void> _openEmotiv() async {
    for (final ch in _emotivEvents) {
      _subs.add(ch.receiveBroadcastStream().listen(
        _forward,
        onError: (_) => _drop(),
        onDone: _drop,
      ));
    }
    final started = await _emotivMethods.invokeMethod<bool>('startCortex');
    if (started != true) {
      throw PlatformException(
        code: 'start_failed',
        message: 'CortexLib.start devolvió false',
      );
    }
  }

  void _forward(dynamic event) {
    if (event is String) _messages.add(event);
  }

  @override
  void send(String json) {
    if (!_open) throw const EegException('Cortex library is not started');
    // Fire-and-forget: replies come back through the event channels.
    switch (_dialect) {
      case CortexBridgeDialect.emotivPlugin:
        _emotivMethods.invokeMethod<void>('sendRequest', {'command': json});
      case CortexBridgeDialect.neom:
      case null:
        _neomMethods.invokeMethod<void>('sendRequest', {'json': json});
    }
  }

  @override
  Future<String?> authenticate(String clientId) async {
    if (!_open) await open();
    final methods = _dialect == CortexBridgeDialect.emotivPlugin
        ? _emotivMethods
        : _neomMethods;
    try {
      return await methods.invokeMethod<String>(
        'authenticate',
        {'clientId': clientId},
      );
    } on PlatformException catch (e) {
      throw EegAccessDeniedException(
        'EMOTIV OAuth login failed: ${e.message}',
        cause: e,
      );
    }
  }

  @override
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    await _cancelSubs();
    if (_dialect == CortexBridgeDialect.neom) {
      try {
        await _neomMethods.invokeMethod<void>('stop');
      } on PlatformException {
        // Already down; nothing left to release.
      } on MissingPluginException {
        // Bridge vanished; nothing left to release.
      }
    }
    // Emotiv's plugin stops the library itself when the app terminates and
    // exposes no stop method.
  }

  Future<void> _cancelSubs() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }

  void _drop() {
    if (!_open) return;
    _open = false;
    _subs.clear();
    if (!_closed.isClosed) _closed.add(null);
  }
}
