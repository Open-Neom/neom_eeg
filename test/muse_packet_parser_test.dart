import 'package:flutter_test/flutter_test.dart';
import 'package:neom_eeg/data/providers/muse/muse_packet_parser.dart';

/// Packs twelve 12-bit values big-endian after a 16-bit counter, the way
/// the Muse firmware does, so the parser is checked against the inverse.
List<int> packEeg(int index, List<int> values12) {
  assert(values12.length == 12);
  final bits = <int>[];
  void push(int v, int width) {
    for (var i = width - 1; i >= 0; i--) {
      bits.add((v >> i) & 1);
    }
  }
  push(index, 16);
  for (final v in values12) {
    push(v, 12);
  }
  final bytes = <int>[];
  for (var i = 0; i < bits.length; i += 8) {
    var b = 0;
    for (var j = 0; j < 8; j++) {
      b = (b << 1) | bits[i + j];
    }
    bytes.add(b);
  }
  return bytes;
}

void main() {
  group('EEG packets', () {
    test('a 20-byte packet yields the counter and 12 µV samples', () {
      final values = [2048, 2049, 2047, 0, 4095, 1024, 3072, 2048, 2100,
        1996, 2048, 2048];
      final packet = MusePacketParser.parseEeg(packEeg(0x1234, values));

      expect(packet, isNotNull);
      expect(packet!.index, 0x1234);
      expect(packet.samples.length, 12);
      expect(packet.samples[0], 0.0);
      expect(packet.samples[1], closeTo(0.48828125, 1e-9));
      expect(packet.samples[2], closeTo(-0.48828125, 1e-9));
      expect(packet.samples[3], closeTo(-1000.0, 1e-6));
      expect(packet.samples[4], closeTo(999.51171875, 1e-6));
      expect(packet.samples[5], closeTo(-500.0, 1e-6));
      expect(packet.samples[6], closeTo(500.0, 1e-6));
    });

    test('byte-aligned and nibble-aligned fields decode independently', () {
      // Alternate a distinctive pattern so a shift error is visible.
      final values = List.generate(12, (i) => i.isEven ? 0xABC : 0x123);
      final packet = MusePacketParser.parseEeg(packEeg(1, values))!;
      for (var i = 0; i < 12; i++) {
        final expected = MusePacketParser.microvoltsPerCount *
            ((i.isEven ? 0xABC : 0x123) - 2048);
        expect(packet.samples[i], closeTo(expected, 1e-9), reason: 'sample $i');
      }
    });

    test('short notifications are rejected', () {
      expect(MusePacketParser.parseEeg(List.filled(19, 0)), isNull);
      expect(MusePacketParser.parseEeg(const []), isNull);
    });

    test('a real-looking packet from muse-lsl decodes to plausible µV', () {
      // Midscale with slight noise: all samples within ±10 µV.
      final values = [2050, 2046, 2052, 2044, 2048, 2051, 2047, 2049,
        2045, 2053, 2048, 2046];
      final packet = MusePacketParser.parseEeg(packEeg(300, values))!;
      for (final s in packet.samples) {
        expect(s.abs(), lessThan(10.0));
      }
    });
  });

  group('telemetry', () {
    test('battery is uint16 ÷ 512 percent, normalised to 0..1', () {
      // 0x9600 = 38400 → 75%
      final bytes = [0x00, 0x2A, 0x96, 0x00, 0x0F, 0xA0, 0x00, 0x00, 0x00, 0x19];
      final t = MusePacketParser.parseTelemetry(bytes)!;
      expect(t.index, 0x2A);
      expect(t.battery, closeTo(0.75, 1e-9));
      expect(t.fuelGaugeMv, closeTo(4000 * 2.2, 1e-6));
      expect(t.temperature, 25.0);
    });

    test('rejects short payloads', () {
      expect(MusePacketParser.parseTelemetry([1, 2, 3]), isNull);
    });
  });

  group('commands', () {
    test('frames as length, ascii, newline', () {
      expect(MusePacketParser.encodeCommand('h'), [2, 0x68, 0x0A]);
      expect(MusePacketParser.encodeCommand('p21'),
          [4, 0x70, 0x32, 0x31, 0x0A]);
      expect(MusePacketParser.encodeCommand('v1'), [3, 0x76, 0x31, 0x0A]);
    });
  });
}
