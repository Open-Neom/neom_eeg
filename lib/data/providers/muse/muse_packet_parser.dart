/// One EEG notification from a Muse electrode characteristic.
class MuseEegPacket {
  /// 16-bit rolling counter; the four electrode characteristics share it,
  /// which is how samples from different channels are aligned in time.
  final int index;

  /// 12 consecutive samples in microvolts.
  final List<double> samples;

  const MuseEegPacket(this.index, this.samples);
}

class MuseTelemetry {
  final int index;

  /// Battery charge, `0..1`.
  final double battery;

  /// Fuel-gauge voltage in millivolts.
  final double fuelGaugeMv;

  /// Board temperature, °C.
  final double temperature;

  const MuseTelemetry({
    required this.index,
    required this.battery,
    required this.fuelGaugeMv,
    required this.temperature,
  });
}

/// Wire format of the Muse 2 / Muse S GATT characteristics.
///
/// Every notification is 20 bytes. EEG packets carry a 16-bit big-endian
/// counter followed by twelve 12-bit big-endian samples packed back to back
/// (18 bytes). The ADC spans 2 mV peak-to-peak over 12 bits, so one count
/// is 0.48828125 µV around a 2048 midpoint. Verified against muse-lsl and
/// muse-js, which decode the same way.
class MusePacketParser {
  MusePacketParser._();

  static const samplesPerPacket = 12;
  static const packetLength = 20;
  static const microvoltsPerCount = 0.48828125;
  static const midpoint = 2048;

  /// Returns null for anything that is not a full 20-byte EEG packet.
  static MuseEegPacket? parseEeg(List<int> bytes) {
    if (bytes.length < packetLength) return null;

    final index = ((bytes[0] & 0xFF) << 8) | (bytes[1] & 0xFF);
    final samples = List<double>.filled(samplesPerPacket, 0.0);

    // 12-bit fields alternate between byte-aligned and nibble-aligned.
    var bit = 16;
    for (var i = 0; i < samplesPerPacket; i++) {
      final b = bit >> 3;
      final b0 = bytes[b] & 0xFF;
      final b1 = bytes[b + 1] & 0xFF;
      final raw = (bit & 7) == 0 ? (b0 << 4) | (b1 >> 4) : ((b0 & 0x0F) << 8) | b1;
      samples[i] = microvoltsPerCount * (raw - midpoint);
      bit += 12;
    }
    return MuseEegPacket(index, samples);
  }

  /// Telemetry: five big-endian uint16 — counter, battery (÷512 = %),
  /// fuel gauge (×2.2 = mV), ADC volts, temperature (°C).
  static MuseTelemetry? parseTelemetry(List<int> bytes) {
    if (bytes.length < 10) return null;
    int u16(int at) => ((bytes[at] & 0xFF) << 8) | (bytes[at + 1] & 0xFF);
    return MuseTelemetry(
      index: u16(0),
      battery: (u16(2) / 512.0 / 100.0).clamp(0.0, 1.0),
      fuelGaugeMv: u16(4) * 2.2,
      temperature: u16(8).toDouble(),
    );
  }

  /// Control-characteristic framing: length byte (chars + newline), ASCII
  /// command, `\n`. `h` halt · `d` resume · `s` start · `p21` EEG-only
  /// preset · `p20` EEG + AUX · `v1` firmware info · `k` keep-alive.
  static List<int> encodeCommand(String command) {
    if (command.isEmpty || command.length > 254) {
      throw ArgumentError.value(
        command,
        'command',
        'Muse GATT command must be 1..254 ASCII bytes',
      );
    }
    final units = command.codeUnits;
    for (final c in units) {
      if (c < 0x20 || c >= 0x7F) {
        throw ArgumentError.value(
          command,
          'command',
          'Muse GATT command must contain single-line printable ASCII only',
        );
      }
    }
    return [units.length + 1, ...units, 0x0A];
  }
}
