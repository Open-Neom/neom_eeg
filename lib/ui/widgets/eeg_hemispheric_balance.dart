import 'package:flutter/material.dart';

import '../../data/implementations/eeg_signal_processor.dart';
import '../../domain/models/eeg_band_power.dart';
import '../../domain/models/eeg_channel_catalog.dart';
import 'eeg_asymmetry_indicator.dart';

/// Left/right balance for whatever homologous pair the connected headset
/// offers — T7/T8 on an Insight, TP9/TP10 on a Muse, AF7/AF8 on an MN8 —
/// so the same panel reads correctly on every model.
///
/// Wraps [EegAsymmetryIndicator] with the region the pair covers and the
/// derived coherence (`1 − |asymmetry|`), which is the value the
/// NeuroStateService snapshot carries into the Cámara Neom.
class EegHemisphericBalance extends StatelessWidget {
  final List<EegBandPower> frame;
  final String band;

  /// Electrodes to ignore (no contact), so a dead T7 does not fake an
  /// asymmetry — the next pair down the catalog is used instead.
  final Set<String> excluded;

  const EegHemisphericBalance({
    super.key,
    required this.frame,
    this.band = 'alpha',
    this.excluded = const {},
  });

  @override
  Widget build(BuildContext context) {
    if (frame.isEmpty) {
      return const _Card(
        child: Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 10),
            Text(
              'Esperando bandas del headset…',
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ),
      );
    }

    final byChannel = {
      for (final p in frame)
        if (!excluded.contains(p.channel)) p.channel: p,
    };
    final pair = EegChannelCatalog.bestPair(byChannel.keys);

    if (pair == null) {
      return _Card(
        child: Row(
          children: const [
            Icon(Icons.balance, size: 16, color: Colors.white38),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Este headset no tiene un par izquierdo/derecho utilizable; '
                'el balance hemisférico no está disponible.',
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ),
          ],
        ),
      );
    }

    final asymmetry = EegSignalProcessor().computeAsymmetry(
      byChannel[pair.left]!,
      byChannel[pair.right]!,
      band,
    );
    final coherence = (1.0 - asymmetry.asymmetryIndex.abs()).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 4),
          child: Row(
            children: [
              Icon(
                pair.isTemporal ? Icons.hearing : Icons.balance,
                size: 13,
                color: Colors.white38,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'BALANCE ${pair.region.toUpperCase()} · ${pair.left}/${pair.right}',
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              Text(
                'coherencia ${(coherence * 100).round()}%',
                style: TextStyle(
                  color: coherence > 0.8
                      ? Colors.greenAccent
                      : coherence > 0.6
                          ? Colors.amber
                          : Colors.redAccent,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        EegAsymmetryIndicator(asymmetry: asymmetry),
        if (!pair.isTemporal)
          const Padding(
            padding: EdgeInsets.only(top: 4, left: 2),
            child: Text(
              'Sin electrodos temporales: el protocolo T7/T8 requiere un '
              'Insight o EPOC con ambos sensores en contacto.',
              style: TextStyle(color: Colors.white38, fontSize: 10),
            ),
          ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(10),
        ),
        child: child,
      );
}
