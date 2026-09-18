import '../enums/eeg_device_type.dart';
import '../enums/eeg_vendor.dart';

/// Base class for every error raised by neom_eeg drivers and the hub.
class EegException implements Exception {
  final String message;
  final Object? cause;

  const EegException(this.message, {this.cause});

  @override
  String toString() =>
      'EegException: $message${cause != null ? ' (cause: $cause)' : ''}';
}

/// No registered driver can handle the requested device on this platform.
class EegDriverUnavailableException extends EegException {
  final EegVendor vendor;
  final EegDeviceType? type;

  const EegDriverUnavailableException(
    super.message, {
    required this.vendor,
    this.type,
    super.cause,
  });
}

/// The vendor's SDK refused the application (Cortex `requestAccess` not
/// approved in EMOTIV Launcher, expired license, EULA not accepted…).
class EegAccessDeniedException extends EegException {
  const EegAccessDeniedException(super.message, {super.cause});
}

/// The device answered something the driver cannot interpret, or a
/// JSON-RPC call returned an error object.
class EegProtocolException extends EegException {
  final int? code;

  const EegProtocolException(super.message, {this.code, super.cause});

  @override
  String toString() =>
      'EegProtocolException${code != null ? '[$code]' : ''}: $message';
}

/// A connection attempt or a request timed out.
class EegTimeoutException extends EegException {
  const EegTimeoutException(super.message, {super.cause});
}
