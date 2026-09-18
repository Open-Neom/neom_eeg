import 'dart:async';
import 'dart:convert';

import 'package:neom_eeg/data/providers/emotiv/cortex_transport.dart';

/// In-memory stand-in for EMOTIV Launcher's Cortex service.
///
/// Answers the JSON-RPC methods the provider uses with the shapes the real
/// service returns (Cortex 4.x), keeps a tiny headset table, and lets a
/// test push warnings and stream samples. Behaviour knobs let tests cover
/// the pending-approval, EULA and license-failure paths.
class FakeCortexTransport implements CortexTransport {
  final _messages = StreamController<String>.broadcast();
  final _closed = StreamController<void>.broadcast();

  bool _open = false;
  bool supported = true;
  String? unsupportedText;

  /// Every request as decoded JSON, in order.
  final List<Map<String, dynamic>> requests = [];

  /// Headsets `queryHeadsets` returns; `status` is mutated by `connect`.
  List<Map<String, dynamic>> headsets = [
    {
      'id': 'INSIGHT-A1B2C3D4',
      'status': 'discovered',
      'connectedBy': 'bluetooth',
      'firmware': '3.1',
      'sensors': ['AF3', 'T7', 'Pz', 'T8', 'AF4'],
      'settings': {'mode': 'INSIGHT', 'eegRate': 128, 'memsRate': 64},
      'customName': 'Insight de Emmanuel',
    },
  ];

  /// Users `getUserLogin` reports. Empty → nobody logged in.
  List<Map<String, dynamic>> users = [
    {'username': 'serzen', 'currentOSUId': '501'},
  ];

  /// How many `requestAccess` calls come back unapproved before approval.
  int accessDeniedCalls = 0;

  /// `authorize` returns this warning object instead of a token.
  Map<String, dynamic>? eulaWarning;

  /// `createSession` with status `active` fails with this error.
  Map<String, dynamic>? activeSessionError;

  /// Streams `subscribe` puts in `failure` (e.g. no license for eeg).
  Set<String> failStreams = {};

  /// Whether `controlDevice connect` transitions the headset.
  bool connectSucceeds = true;

  /// Emit warning 104 (or the failure code) after connect.
  int? connectWarningCode = 104;

  /// Optional code the mobile `authenticate` hands back.
  String? authenticationCode;

  int _accessCalls = 0;
  int _sessionCounter = 0;
  int _recordCounter = 0;
  int _markerCounter = 0;

  /// Records created through createRecord, by uuid.
  final Map<String, Map<String, dynamic>> records = {};

  /// uuid of the record currently open, if any.
  String? activeRecordId;

  /// Markers injected, in order.
  final List<Map<String, dynamic>> markers = [];

  /// What getLicenseInfo returns.
  Map<String, dynamic> licenseInfo = {
    'license': {
      'licenseId': 'lic-123',
      'licenseName': 'EmotivPRO Developer',
      'scopes': ['eeg', 'pm', 'com', 'fac', 'mot'],
      'sessionCount': 100,
      'sessionRemaining': 42,
      'expired': false,
      'isCommercial': false,
    },
    'isOnline': true,
  };

  /// Whether updateHeadset succeeds (needs USB cable on real hardware).
  bool headsetUpdateSucceeds = true;

  static const insightCols = {
    'eeg': ['COUNTER', 'INTERPOLATED', 'AF3', 'T7', 'Pz', 'T8', 'AF4',
      'RAW_CQ', 'MARKER_HARDWARE', 'MARKERS'],
    'pow': ['AF3/theta', 'AF3/alpha', 'AF3/betaL', 'AF3/betaH', 'AF3/gamma',
      'T7/theta', 'T7/alpha', 'T7/betaL', 'T7/betaH', 'T7/gamma',
      'Pz/theta', 'Pz/alpha', 'Pz/betaL', 'Pz/betaH', 'Pz/gamma',
      'T8/theta', 'T8/alpha', 'T8/betaL', 'T8/betaH', 'T8/gamma',
      'AF4/theta', 'AF4/alpha', 'AF4/betaL', 'AF4/betaH', 'AF4/gamma'],
    'met': ['eng.isActive', 'eng', 'exc.isActive', 'exc', 'lex',
      'str.isActive', 'str', 'rel.isActive', 'rel', 'int.isActive', 'int',
      'foc.isActive', 'foc'],
    'dev': ['Battery', 'Signal', ['AF3', 'T7', 'Pz', 'T8', 'AF4', 'OVERALL'],
      'BatteryPercent'],
    'eq': ['batteryPercent', 'overall', 'sampleRateQuality', 'AF3', 'T7',
      'Pz', 'T8', 'AF4'],
    'mot': ['COUNTER_MEMS', 'INTERPOLATED_MEMS', 'Q0', 'Q1', 'Q2', 'Q3',
      'ACCX', 'ACCY', 'ACCZ', 'MAGX', 'MAGY', 'MAGZ'],
  };

  final Map<String, String> sids = {};

  @override
  bool get isSupported => supported;

  @override
  String? get unsupportedReason => supported ? null : unsupportedText;

  @override
  bool get isOpen => _open;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Stream<void> get onClosed => _closed.stream;

  @override
  Future<void> open() async => _open = true;

  @override
  Future<void> close() async => _open = false;

  @override
  Future<String?> authenticate(String clientId) async => authenticationCode;

  /// Simulate the Launcher dying.
  void dropConnection() {
    _open = false;
    _closed.add(null);
  }

  void pushWarning(int code, dynamic message) {
    _messages.add(jsonEncode({
      'jsonrpc': '2.0',
      'warning': {'code': code, 'message': message},
    }));
  }

  void pushSample(String stream, List<dynamic> values, {num? time}) {
    _messages.add(jsonEncode({
      stream: values,
      'sid': sids[stream] ?? 'sid-$stream',
      'time': time ?? 1700000000.0,
    }));
  }

  void pushRaw(String text) => _messages.add(text);

  @override
  void send(String json) {
    final req = jsonDecode(json) as Map<String, dynamic>;
    requests.add(req);
    final id = req['id'];
    final method = req['method'] as String;
    final params = (req['params'] as Map?)?.cast<String, dynamic>() ?? {};

    void reply(dynamic result) => _messages.add(jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': result,
        }));
    void fail(int code, String message) => _messages.add(jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': code, 'message': message},
        }));

    // Deliver asynchronously like a socket would.
    scheduleMicrotask(() {
      switch (method) {
        case 'getUserLogin':
          reply(users);
        case 'loginWithAuthenticationCode':
          users = [{'username': 'mobile-user'}];
          reply({'username': 'mobile-user'});
        case 'requestAccess':
          _accessCalls++;
          final granted = _accessCalls > accessDeniedCalls;
          reply({
            'accessGranted': granted,
            'message': granted
                ? 'The user has granted access right to this application.'
                : 'The User has not granted access right to this '
                    'application. Please use Emotiv App to proceed.',
          });
        case 'authorize':
          if (eulaWarning != null) {
            reply({'warning': eulaWarning});
          } else {
            reply({'cortexToken': 'tok-${params['clientId']}'});
          }
        case 'controlDevice':
          final command = params['command'];
          if (command == 'refresh') {
            reply({'command': 'refresh', 'message': 'Start refreshing.'});
            pushWarning(142, 'Headset discovering complete');
          } else if (command == 'connect') {
            final hid = params['headset'];
            reply({'command': 'connect', 'message': 'Start connecting to $hid'});
            if (connectSucceeds) {
              for (final h in headsets) {
                if (h['id'] == hid) h['status'] = 'connected';
              }
              if (connectWarningCode != null) {
                pushWarning(connectWarningCode!,
                    {'headsetId': hid, 'behavior': 'The headset is connected'});
              }
            } else if (connectWarningCode != null) {
              pushWarning(connectWarningCode!,
                  {'headsetId': hid, 'behavior': 'Connection failed'});
            }
          } else {
            reply({'command': command, 'message': 'ok'});
          }
        case 'queryHeadsets':
          final filter = params['id'] as String?;
          reply([
            for (final h in headsets)
              if (filter == null || h['id'] == filter) Map.of(h),
          ]);
        case 'createSession':
          if (params['status'] == 'active' && activeSessionError != null) {
            fail(activeSessionError!['code'] as int,
                activeSessionError!['message'] as String);
          } else {
            _sessionCounter++;
            reply({
              'id': 'session-$_sessionCounter',
              'status': params['status'],
              'headset': {'id': params['headset']},
            });
          }
        case 'subscribe':
          final streams = (params['streams'] as List).cast<String>();
          final success = <Map<String, dynamic>>[];
          final failure = <Map<String, dynamic>>[];
          for (final s in streams) {
            if (failStreams.contains(s) || !insightCols.containsKey(s)) {
              failure.add({'streamName': s, 'code': -32017,
                'message': 'Not licensed for $s'});
            } else {
              sids[s] = 'sid-$s';
              success.add({'streamName': s, 'sid': 'sid-$s',
                'cols': insightCols[s]});
            }
          }
          reply({'success': success, 'failure': failure});
        case 'unsubscribe':
          reply({'success': [], 'failure': []});
        case 'updateSession':
          reply({'id': params['session'], 'status': params['status']});
          if (params['status'] == 'close') activeRecordId = null;
        case 'getCortexInfo':
          reply({'version': '4.4.7', 'buildNumber': '484', 'buildDate': '2026-05-01'});
        case 'getLicenseInfo':
          reply(licenseInfo);
        case 'createRecord':
          if (activeRecordId != null) {
            fail(-32054, 'A record is already active in this session');
            break;
          }
          final uuid = 'rec-${++_recordCounter}';
          final rec = {
            'uuid': uuid,
            'title': params['title'],
            'description': params['description'],
            'subjectName': params['subjectName'],
            'tags': params['tags'] ?? [],
            'startDatetime': DateTime.now().toIso8601String(),
            'samplingRate': 128,
            'markers': <Map<String, dynamic>>[],
          };
          records[uuid] = rec;
          activeRecordId = uuid;
          reply({'record': Map.of(rec), 'sessionId': params['session']});
        case 'stopRecord':
          final id = activeRecordId;
          if (id == null) {
            fail(-32055, 'No active record');
            break;
          }
          records[id]!['endDatetime'] = DateTime.now().toIso8601String();
          activeRecordId = null;
          reply({'record': Map.of(records[id]!), 'sessionId': params['session']});
        case 'injectMarker':
          final id = activeRecordId;
          if (id == null) {
            fail(-32056, 'You must call createRecord before injectMarker');
            break;
          }
          final marker = {
            'uuid': 'mk-${++_markerCounter}',
            'type': 'instance',
            'value': params['value'],
            'label': params['label'],
            'port': params['port'],
            'startDatetime': params['time'],
          };
          markers.add({...params, 'uuid': marker['uuid']});
          (records[id]!['markers'] as List).add(marker);
          reply({'marker': marker, 'recordId': id, 'sessionId': params['session']});
        case 'queryRecords':
          final all = records.values.toList().reversed.toList();
          final limit = (params['limit'] as int?) ?? all.length;
          reply({'records': all.take(limit).map(Map.of).toList(), 'count': all.length});
        case 'exportRecord':
          final ids = (params['recordIds'] as List).cast<String>();
          reply({
            'success': [
              for (final id in ids)
                if (records.containsKey(id)) {'recordId': id},
            ],
            'failure': [
              for (final id in ids)
                if (!records.containsKey(id))
                  {'recordId': id, 'code': -32070, 'message': 'Record not found'},
            ],
          });
        case 'updateHeadset':
          if (!headsetUpdateSucceeds) {
            fail(-32090, 'Please connect the headset via USB cable');
            break;
          }
          final setting = (params['setting'] as Map).cast<String, dynamic>();
          for (final h in headsets) {
            if (h['id'] == params['headset']) {
              final current = (h['settings'] as Map).cast<String, dynamic>();
              h['settings'] = {...current, ...setting};
            }
          }
          reply({'headset': params['headset'], 'message': 'updated'});
        case 'syncWithHeadsetClock':
          reply({'adjustment': 0.0123});
        case 'createVirtualHeadset':
          final vid = 'VIRTUAL-${params['type']}-1';
          reply({
            'id': vid,
            'status': 'discovered',
            'connectedBy': 'virtual',
            'settings': {'mode': params['type'], 'eegRate': 128},
            'sensors': params['type'] == 'INSIGHT'
                ? ['AF3', 'T7', 'Pz', 'T8', 'AF4']
                : <String>[],
            'virtual': true,
          });
        default:
          fail(-32601, 'Method not found: $method');
      }
    });
  }

  Future<void> dispose() async {
    await _messages.close();
    await _closed.close();
  }
}
