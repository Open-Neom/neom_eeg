import 'dart:async';

import 'package:neom_core/domain/model/neom/neom_neuro_state.dart';
import 'package:neom_core/domain/use_cases/neuro_state_service.dart';

import '../../domain/enums/eeg_connection_state.dart';
import '../../domain/models/eeg_band_power.dart';
import '../../domain/models/eeg_channel_catalog.dart';
import '../../domain/use_cases/eeg_device_service.dart';
import '../hub/eeg_hub.dart';
import 'eeg_indices.dart';

/// Exposes a connected EEG headset as a [NeuroStateService].
///
/// The contract was written for the audio generator, which *drives* the state.
/// A headset does the opposite: it *observes* it. So the stream is fed from the
/// device's band powers, and [setNeuroState] records a target for neurofeedback
/// rather than forcing the emitted value — see its doc.
///
/// Band-to-state mapping follows the same convention as
/// [EegBiofeedbackAdapter], which already classifies alpha as relaxation and
/// beta as analytical activity:
///
/// | dominant band | state       |
/// |---------------|-------------|
/// | delta         | sleep       |
/// | theta         | creativity  |
/// | alpha         | calm        |
/// | beta          | focus       |
/// | gamma         | integration |
///
/// [NeuroStateSnapshot.coherence] is hemispheric, on alpha
/// ([EegIndices.hemisphericBand]) and the best left/right pair the headset
/// offers ([EegChannelCatalog.bestPair] — T7/T8 on Insight/EPOC/MN8,
/// TP9/TP10 on Muse):
///
/// * spectral coherence (MSC) from the hub's raw-signal tracker when the
///   device service is an [EegHub] with a fresh reading for that pair —
///   [coherenceKind] `spectral`;
/// * otherwise `1 − |asymmetry|` of alpha power — [coherenceKind]
///   `symmetry`. The core field cannot be null, so this is the one place
///   the two are carried by the same number; [coherenceKind] says which.
/// * 0 when the headset has no pair — [coherenceKind] `none`.
class EegNeuroStateAdapter implements NeuroStateService {

  EegNeuroStateAdapter({required this.deviceService});

  final EegDeviceService deviceService;

  /// Representative frequency of each band, used to fill
  /// [NeuroStateSnapshot.frequency] with something physically meaningful.
  static const Map<_Band, double> _bandCenterHz = {
    _Band.delta: 2.0,
    _Band.theta: 6.0,
    _Band.alpha: 10.0,
    _Band.beta: 20.0,
    _Band.gamma: 40.0,
  };

  static const Map<_Band, NeomNeuroState> _bandState = {
    _Band.delta: NeomNeuroState.sleep,
    _Band.theta: NeomNeuroState.creativity,
    _Band.alpha: NeomNeuroState.calm,
    _Band.beta: NeomNeuroState.focus,
    _Band.gamma: NeomNeuroState.integration,
  };

  final _stateController = StreamController<NeuroStateSnapshot>.broadcast();
  StreamSubscription<List<EegBandPower>>? _bandPowerSub;
  StreamSubscription<EegConnectionState>? _connectionSub;

  NeuroStateSnapshot _latest = NeuroStateSnapshot.neutral();
  NeomNeuroState? _target;
  bool _isActive = false;

  @override
  NeomNeuroState get currentState => _latest.state;

  @override
  bool get isActive =>
      _isActive &&
      (deviceService.connectionState == EegConnectionState.connected ||
          deviceService.connectionState == EegConnectionState.streaming);

  @override
  Stream<NeuroStateSnapshot> get stateStream => _stateController.stream;

  @override
  NeuroStateSnapshot get latestSnapshot => _latest;

  /// The state a neurofeedback session is steering towards.
  ///
  /// A headset reports what the brain is doing; it cannot be told what to do.
  /// So this does NOT change what the stream emits — it records the goal, which
  /// a session can compare against [currentState] to score progress.
  @override
  void setNeuroState(NeomNeuroState state) => _target = state;

  /// The state requested through [setNeuroState], if any.
  NeomNeuroState? get targetState => _target;

  /// Left/right pair the coherence was last computed on, or null when the
  /// device has no homologous pair.
  EegHemisphericPair? get hemisphericPair => _pair;
  EegHemisphericPair? _pair;

  /// What the last snapshot's `coherence` is.
  EegCoherenceKind get coherenceKind => _kind;
  EegCoherenceKind _kind = EegCoherenceKind.none;

  /// How close the reading is to [targetState], or null when none is set.
  /// 1.0 means the target is being held.
  double? get targetProximity {
    final target = _target;
    if (target == null) return null;
    final distance =
        (currentState.normalizedValue - target.normalizedValue).abs();
    return 1.0 - distance;
  }

  /// Starts translating device readings into snapshots.
  Future<void> start() async {
    if (_isActive) return;
    _isActive = true;
    _bandPowerSub = deviceService.bandPowerStream.listen(_onBandPower);
    final device = deviceService;
    if (device is EegHub) {
      // Frames simply stop when the headset goes away; say so, so listeners
      // do not keep showing the last reading.
      _connectionSub = device.connectionStateStream.listen((state) {
        if (state == EegConnectionState.disconnected || state == EegConnectionState.error) {
          _latest = NeuroStateSnapshot.neutral();
          _kind = EegCoherenceKind.none;
          if (!_stateController.isClosed) _stateController.add(_latest);
        }
      });
    }
  }

  Future<void> stop() async {
    _isActive = false;
    await _bandPowerSub?.cancel();
    _bandPowerSub = null;
    await _connectionSub?.cancel();
    _connectionSub = null;
  }

  Future<void> dispose() async {
    await stop();
    await _stateController.close();
  }

  void _onBandPower(List<EegBandPower> readings) {
    if (readings.isEmpty) return;

    // Average each band across channels: a state is a whole-head property, and
    // a single electrode is too noisy to classify on its own.
    final totals = {for (final b in _Band.values) b: 0.0};
    for (final r in readings) {
      totals[_Band.delta] = totals[_Band.delta]! + r.delta;
      totals[_Band.theta] = totals[_Band.theta]! + r.theta;
      totals[_Band.alpha] = totals[_Band.alpha]! + r.alpha;
      totals[_Band.beta] = totals[_Band.beta]! + r.betaLow + r.betaHigh;
      totals[_Band.gamma] = totals[_Band.gamma]! + r.gamma;
    }

    final sum = totals.values.fold(0.0, (a, b) => a + b);
    if (sum <= 0) return;

    _Band dominant = _Band.alpha;
    double dominantShare = 0;
    for (final entry in totals.entries) {
      final share = entry.value / sum;
      if (share > dominantShare) {
        dominantShare = share;
        dominant = entry.key;
      }
    }

    final snapshot = NeuroStateSnapshot(
      state: _bandState[dominant]!,
      // How much the dominant band stands out — a flat spectrum reads as a
      // weak signal rather than a confident classification.
      amplitude: dominantShare.clamp(0.0, 1.0),
      frequency: _bandCenterHz[dominant]!,
      neuro: _bandState[dominant]!.normalizedValue,
      coherence: _hemisphericCoherence(readings),
      // breath, beat and phase belong to the audio generator; a headset has
      // no source for them, so they stay at zero rather than being invented.
      timestamp: DateTime.now(),
    );

    _latest = snapshot;
    if (!_stateController.isClosed) _stateController.add(snapshot);
  }

  /// Spectral coherence when the hub has it for this pair, otherwise alpha
  /// power symmetry; 0 without a pair. Sets [coherenceKind].
  double _hemisphericCoherence(List<EegBandPower> readings) {
    final asym = EegIndices.asymmetry(readings);
    _pair = asym?.pair;
    if (asym == null) {
      _kind = EegCoherenceKind.none;
      return 0.0;
    }
    final device = deviceService;
    if (device is EegHub) {
      final c = device.lastCoherence;
      final msc = c != null && c.pair == asym.pair && c.isFresh()
          ? c.of(EegIndices.hemisphericBand)
          : null;
      if (msc != null) {
        _kind = EegCoherenceKind.spectral;
        return msc.clamp(0.0, 1.0);
      }
    }
    _kind = EegCoherenceKind.symmetry;
    return (1.0 - asym.index.abs()).clamp(0.0, 1.0);
  }
}

enum _Band { delta, theta, alpha, beta, gamma }

/// Which measure [EegNeuroStateAdapter] put in `NeuroStateSnapshot.coherence`.
enum EegCoherenceKind {
  /// Spectral coherence (MSC) of the raw signals.
  spectral,

  /// `1 − |asymmetry|` of band power (no raw EEG available).
  symmetry,

  /// No left/right pair; the value is 0.
  none,
}
