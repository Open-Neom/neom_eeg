import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/enums/eeg_connection_state.dart';
import '../../domain/models/eeg_band_power.dart';
import '../../domain/models/eeg_device_info.dart';
import '../../domain/models/eeg_device_status.dart';
import '../../domain/models/eeg_mental_state.dart';
import '../../domain/models/eeg_sample.dart';
import '../../domain/use_cases/eeg_driver.dart';

/// Shared plumbing for [EegDriver] implementations: broadcast controllers
/// for the data streams, connection-state bookkeeping and the guarded
/// emitters that make it safe to push after [dispose].
///
/// Concrete drivers only implement discovery, connection and parsing.
abstract class EegDriverBase implements EegDriver {
  final _rawController = StreamController<EegSample>.broadcast();
  final _bandPowerController =
      StreamController<List<EegBandPower>>.broadcast();
  final _mentalStateController =
      StreamController<EegMentalState>.broadcast();
  final _statusController = StreamController<EegDeviceStatus>.broadcast();
  final _connectionController =
      StreamController<EegConnectionState>.broadcast();

  EegConnectionState _connectionState = EegConnectionState.disconnected;
  EegDeviceInfo? _connectedDevice;
  EegDeviceStatus? _lastStatus;
  bool _disposed = false;

  @override
  Stream<EegSample> get rawStream => _rawController.stream;

  @override
  Stream<List<EegBandPower>> get bandPowerStream =>
      _bandPowerController.stream;

  @override
  Stream<EegMentalState> get mentalStateStream =>
      _mentalStateController.stream;

  @override
  Stream<EegDeviceStatus> get statusStream => _statusController.stream;

  @override
  Stream<EegConnectionState> get connectionStateStream =>
      _connectionController.stream;

  @override
  EegConnectionState get connectionState => _connectionState;

  @override
  EegDeviceInfo? get connectedDevice => _connectedDevice;

  @override
  EegDeviceStatus? get lastStatus => _lastStatus;

  @override
  bool get isAvailable => true;

  @override
  String? get unavailableReason => null;

  bool get isDisposed => _disposed;

  bool get isStreaming => _connectionState == EegConnectionState.streaming;

  // ── For subclasses ──────────────────────────────────────────────────

  @protected
  void setConnectionState(EegConnectionState state) {
    if (_connectionState == state) return;
    _connectionState = state;
    if (!_disposed) _connectionController.add(state);
  }

  @protected
  void setConnectedDevice(EegDeviceInfo? device) => _connectedDevice = device;

  @protected
  void emitRaw(EegSample sample) {
    if (!_disposed) _rawController.add(sample);
  }

  @protected
  void emitBandPower(List<EegBandPower> powers) {
    if (!_disposed && powers.isNotEmpty) _bandPowerController.add(powers);
  }

  @protected
  void emitMentalState(EegMentalState state) {
    if (!_disposed) _mentalStateController.add(state);
  }

  @protected
  void emitStatus(EegDeviceStatus status) {
    _lastStatus = status;
    if (!_disposed) _statusController.add(status);
  }

  @override
  bool supports(type) => supportedTypes.contains(type);

  @override
  @mustCallSuper
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await Future.wait([
      _rawController.close(),
      _bandPowerController.close(),
      _mentalStateController.close(),
      _statusController.close(),
      _connectionController.close(),
    ]);
  }
}
