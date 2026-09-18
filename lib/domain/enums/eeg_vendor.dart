/// Manufacturer of an EEG headset.
///
/// The hub routes a device to its driver by vendor, so a consumer never has
/// to know whether a headset speaks Cortex JSON-RPC, a BLE GATT profile or a
/// serial protocol.
enum EegVendor {
  emotiv('Emotiv'),
  interaxon('Interaxon (Muse)'),
  brainbit('BrainBit'),
  openbci('OpenBCI'),
  neurosky('NeuroSky'),
  simulated('Simulated');

  final String displayName;

  const EegVendor(this.displayName);
}
