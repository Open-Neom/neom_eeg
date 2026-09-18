/// Physical/logical path through which a driver reaches a headset.
///
/// A device type may be reachable through more than one transport (an Emotiv
/// headset goes through the Cortex service on desktop and through the
/// embedded Cortex library on mobile). Drivers declare which transports they
/// implement; the hub uses that to explain why a device cannot be connected
/// on the current platform instead of failing silently.
enum EegTransport {
  /// EMOTIV Launcher / Cortex service on the same machine, JSON-RPC over
  /// `wss://localhost:6868`. Desktop and web only.
  cortexService('Cortex service (EMOTIV Launcher)'),

  /// Emotiv Cortex Library for Mobile embedded in the host app, bridged to
  /// Dart through a platform channel. iOS and Android only.
  cortexLibrary('Cortex embedded library'),

  /// Bluetooth Low Energy GATT, spoken directly by the driver.
  ble('Bluetooth LE'),

  /// USB / serial dongle (e.g. OpenBCI Cyton).
  serial('Serial / USB'),

  /// Samples relayed over the network by a companion program
  /// (e.g. OpenBCI GUI, LSL bridge).
  network('Network relay'),

  /// Synthetic signal generated in-process.
  simulated('Simulated');

  final String displayName;

  const EegTransport(this.displayName);
}
