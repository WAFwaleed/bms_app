import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'مراقب البطاريات',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00897B),
          brightness: Brightness.dark,
        ),
      ),
      home: const HomePage(),
    );
  }
}

// ---- PACE (Modbus RTU over BLE) ----
final Guid kService = Guid('00002760-08c2-11e1-9073-0e8ac72e1001');
final Guid kWriteChar = Guid('00002760-08c2-11e1-9073-0e8ac72e0001');
final Guid kNotifyChar = Guid('00002760-08c2-11e1-9073-0e8ac72e0002');

// ---- JBD / Xiaoxiang (used by Kfo SP04S060L4S300A packs) ----
const String kJbdService = 'ff00';
const String kJbdNotify = 'ff01';
const String kJbdWrite = 'ff02';

/// Compares a discovered Guid against a 16-bit short UUID such as "ff00".
bool uuidIs(Guid g, String short) {
  final s = g.toString().toLowerCase().replaceAll('-', '');
  if (s.length <= 4) return s == short;
  if (s.length != 32) return false;
  return s.substring(4, 8) == short && s.endsWith('00001000800000805f9b34fb');
}

/// Builds a JBD request frame: DD A5 <cmd> 00 <checksum> 77
Uint8List jbdCmd(int cmd) {
  final cs = 0x10000 - cmd;
  return Uint8List.fromList(
      [0xDD, 0xA5, cmd, 0x00, (cs >> 8) & 0xFF, cs & 0xFF, 0x77]);
}

// ============ Modbus RTU ============
int crc16(List<int> data) {
  int crc = 0xFFFF;
  for (final b in data) {
    crc ^= b;
    for (int i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1;
    }
  }
  return crc;
}

Uint8List readCmd(int addr, int reg, int count) {
  final b = <int>[
    addr,
    0x03,
    (reg >> 8) & 0xFF,
    reg & 0xFF,
    (count >> 8) & 0xFF,
    count & 0xFF,
  ];
  final c = crc16(b);
  b.add(c & 0xFF);
  b.add((c >> 8) & 0xFF);
  return Uint8List.fromList(b);
}

// ============ RTL-safe text helpers ============
// Arabic letters written as Unicode escapes so that source lines which also
// contain code (interpolation, operators) never get reordered by editors.
const String _hourLetter = '\u0633'; // س
const String _minLetter = '\u062F'; // د
const String kUntilFull = '\u062D\u062A\u0649 \u0627\u0644\u0627\u0645\u062A\u0644\u0627\u0621';
const String kUntilEmpty = '\u062D\u062A\u0649 \u0627\u0644\u0641\u0631\u0627\u063A';
const String kTimeLeft = '\u0627\u0644\u0648\u0642\u062A \u0627\u0644\u0645\u062A\u0628\u0642\u064A';
// "الآن" / "ثانية" / "دقيقة"
const String kJustNow = '\u0627\u0644\u0622\u0646';
const String kSecondsAgo = '\u062B\u0627\u0646\u064A\u0629';
const String kMinutesAgo = '\u062F\u0642\u064A\u0642\u0629';

String formatHours(double? h) {
  if (h == null) return '\u2014';
  if (h > 99) return '+99 $_hourLetter';
  final total = (h * 60).round();
  final hh = total ~/ 60;
  final mm = total % 60;
  if (hh == 0) return '$mm $_minLetter';
  return '$hh $_hourLetter $mm $_minLetter';
}

// ============ Battery model ============
class Battery {
  final String id;
  final String name;
  BluetoothDevice? device;

  /// User-assigned label, e.g. "بطارية اليمين". Empty = use device name.
  String customName = '';

  /// Whether this battery belongs to the selected system (caravan).
  bool enabled = true;

  double current = 0;
  double voltage = 0;
  int soc = 0;
  int soh = 0;
  double remainAh = 0;
  double fullAh = 0;
  double designAh = 0;
  int cycles = 0;
  int cellCount = 0;
  List<double> cells = [];
  double temp1 = 0, temp2 = 0, tempMos = 0;
  String model = '';
  String serial = '';

  /// Detected BMS protocol: 'pace' or 'jbd'. Empty until first connect.
  String protocol = '';
  bool chgMos = false;
  bool disMos = false;
  bool protect = false;

  String get protocolLabel {
    if (protocol == 'pace') return 'PACE';
    if (protocol == 'jbd') return 'JBD';
    return '\u2014';
  }

  DateTime? updated;
  bool online = false;
  int failCount = 0;

  Battery(this.id, this.name);

  double get power => voltage * current;
  // Sign convention: POSITIVE current = charging, NEGATIVE = discharging.
  bool get charging => current > 0.05;
  bool get discharging => current < -0.05;

  /// Hours until empty (discharging) or until full (charging).
  /// null when idle or current too small to be meaningful.
  double? get hoursRemaining {
    if (current.abs() < 0.5) return null;
    if (discharging) {
      if (remainAh <= 0) return 0;
      return remainAh / current.abs();
    }
    final toFill = fullAh - remainAh;
    if (toFill <= 0) return 0;
    return toFill / current.abs();
  }

  /// Formatted like "5h 30m" using Arabic letter escapes (RTL-safe source)
  String get timeText => formatHours(hoursRemaining);

  String get timeLabel {
    if (charging) return kUntilFull;
    if (discharging) return kUntilEmpty;
    return kTimeLeft;
  }

  double get cellMin =>
      cells.isEmpty ? 0 : cells.reduce((a, b) => a < b ? a : b);
  double get cellMax =>
      cells.isEmpty ? 0 : cells.reduce((a, b) => a > b ? a : b);
  double get cellDelta => cells.isEmpty ? 0 : (cellMax - cellMin) * 1000;

  bool get stale =>
      updated == null || DateTime.now().difference(updated!).inSeconds > 45;

  /// Name to show in the UI — custom label if set, otherwise device name.
  String get displayName => customName.isNotEmpty ? customName : name;

  /// Short label e.g. "…159P" or the custom name
  String get shortName {
    if (customName.isNotEmpty) {
      return customName.length <= 12
          ? customName
          : '${customName.substring(0, 11)}…';
    }
    if (name.length <= 5) return name;
    return '\u2026${name.substring(name.length - 5)}';
  }
}

// ============ Home ============
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final Map<String, Battery> _batteries = {};
  final List<String> _order = [];

  StreamSubscription? _scanSub;
  bool _scanning = false;
  bool _monitoring = false;
  String _status = 'اضغط بحث للعثور على البطاريات';

  /// null = monitor all (round-robin); otherwise focus one battery id
  String? _focusId;

  Timer? _loop;
  Timer? _tick;
  int _rrIndex = 0;
  bool _cycleBusy = false;

  /// True once the user has chosen which batteries belong to this system.
  bool _configured = false;

  /// When true the scan lists every named BLE device, not just likely BMS ones.
  bool _showAll = false;

  /// Heuristic: does this advertisement look like a supported BMS?
  bool _looksLikeBms(ScanResult r) {
    final n = r.device.platformName.trim();
    if (n.isEmpty) return false;
    if (_showAll) return true;
    for (final s in r.advertisementData.serviceUuids) {
      if (s == kService) return true;
      if (uuidIs(s, kJbdService)) return true;
      if (uuidIs(s, 'ffe0')) return true;
    }
    final u = n.toUpperCase();
    const patterns = [
      'BMS',
      'SP0',
      'SP4',
      'JBD',
      'XIAOXIANG',
      'JK-',
      'JK_',
      'DL-',
      'LFP',
      'LIFEPO',
      'BATT',
    ];
    return patterns.any((p) => u.contains(p));
  }

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    // Refresh the "x seconds ago" label once per second
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _lastUpdate != null) setState(() {});
    });
  }

  // ---------- Persistence ----------
  Future<void> _loadPrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      _configured = p.getBool('configured') ?? false;
      final saved = p.getStringList('batteries') ?? [];
      for (final entry in saved) {
        // format: id|deviceName|customName|enabled|protocol
        final parts = entry.split('|');
        if (parts.length < 4) continue;
        final b = Battery(parts[0], parts[1]);
        b.customName = parts[2];
        b.enabled = parts[3] == '1';
        if (parts.length > 4) b.protocol = parts[4];
        _batteries[b.id] = b;
        _order.add(b.id);
      }
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _savePrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      final list = _order.map((id) {
        final b = _batteries[id]!;
        return '${b.id}|${b.name}|${b.customName}|'
            '${b.enabled ? '1' : '0'}|${b.protocol}';
      }).toList();
      await p.setStringList('batteries', list);
      await p.setBool('configured', _configured);
    } catch (_) {}
  }

  /// Batteries that belong to this system
  List<Battery> get _active =>
      _order.map((i) => _batteries[i]!).where((b) => b.enabled).toList();

  // ---------- Scanning ----------
  Future<void> _scan() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    setState(() {
      _scanning = true;
      _status = 'جاري البحث...';
    });

    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final n = r.device.platformName;
        if (!_looksLikeBms(r)) continue;
        final id = r.device.remoteId.str;
        if (!_batteries.containsKey(id)) {
          final b = Battery(id, n.trim());
          b.device = r.device;
          // New batteries found after setup default to OFF so a pack from a
          // neighbouring caravan never joins this system by accident.
          b.enabled = !_configured;
          _batteries[id] = b;
          _order.add(id);
          setState(() {});
        } else {
          _batteries[id]!.device = r.device;
        }
      }
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));
    await Future.delayed(const Duration(seconds: 6));
    if (!mounted) return;
    await _savePrefs();
    setState(() {
      _scanning = false;
      _status = _batteries.isEmpty
          ? 'لم يتم العثور على بطاريات'
          : 'تم العثور على ${_batteries.length} بطارية';
    });
  }

  // ---------- One battery read cycle ----------
  Future<bool> _readBattery(Battery b) async {
    final d = b.device;
    if (d == null) return false;

    BluetoothCharacteristic? wc, nc;
    StreamSubscription? sub;
    final rx = <int>[];
    final done = Completer<bool>();
    bool gotLive = false;
    bool gotCells = false;
    String proto = '';

    // ---- PACE: Modbus RTU frames ----
    void handlePace(List<int> data) {
      if (data.isEmpty) return;
      rx.addAll(data);
      if (rx.length < 3) return;
      if (rx[1] != 0x03) {
        rx.clear();
        return;
      }
      final bc = rx[2];
      final total = 3 + bc + 2;
      if (rx.length < total) return;
      final frame = List<int>.from(rx.sublist(0, total));
      rx.clear();
      if (crc16(frame) != 0) return;
      final p = frame.sublist(3, 3 + bc);
      if (bc >= 110) {
        _decodeLive(b, p);
        gotLive = true;
        if (!done.isCompleted) done.complete(true);
      } else if (bc >= 60) {
        _decodeInfo(b, p);
      }
    }

    // ---- JBD: DD/A5 frames, may arrive split across notifications ----
    void handleJbd(List<int> data) {
      if (data.isEmpty) return;
      rx.addAll(data);
      while (true) {
        final start = rx.indexOf(0xDD);
        if (start < 0) {
          rx.clear();
          return;
        }
        if (start > 0) rx.removeRange(0, start);
        if (rx.length < 4) return;
        final cmd = rx[1];
        final status = rx[2];
        final len = rx[3];
        final total = 4 + len + 3; // header + payload + checksum + 0x77
        if (rx.length < total) return;
        final frame = List<int>.from(rx.sublist(0, total));
        rx.removeRange(0, total);
        if (frame[total - 1] != 0x77 || status != 0x00) continue;
        final p = frame.sublist(4, 4 + len);
        if (cmd == 0x03) {
          _decodeJbdBasic(b, p);
          gotLive = true;
        } else if (cmd == 0x04) {
          _decodeJbdCells(b, p);
          gotCells = true;
        }
        if (gotLive && gotCells && !done.isCompleted) done.complete(true);
      }
    }

    try {
      await d.connect(timeout: const Duration(seconds: 8));
      try {
        await d.requestMtu(517);
      } catch (_) {}

      final services = await d.discoverServices();

      // Auto-detect which protocol this pack speaks.
      for (final s in services) {
        if (s.uuid == kService) {
          for (final c in s.characteristics) {
            if (c.uuid == kWriteChar) wc = c;
            if (c.uuid == kNotifyChar) nc = c;
          }
          if (wc != null && nc != null) {
            proto = 'pace';
            break;
          }
        }
        if (uuidIs(s.uuid, kJbdService)) {
          BluetoothCharacteristic? jw, jn;
          for (final c in s.characteristics) {
            if (uuidIs(c.uuid, kJbdWrite)) jw = c;
            if (uuidIs(c.uuid, kJbdNotify)) jn = c;
          }
          if (jw != null && jn != null) {
            wc = jw;
            nc = jn;
            proto = 'jbd';
            break;
          }
        }
      }

      if (wc == null || nc == null || proto.isEmpty) {
        await d.disconnect();
        return false;
      }

      if (b.protocol != proto) {
        b.protocol = proto;
        _savePrefs();
      }

      await nc.setNotifyValue(true);
      sub = nc.lastValueStream
          .listen(proto == 'jbd' ? handleJbd : handlePace);

      if (proto == 'jbd') {
        rx.clear();
        await wc.write(jbdCmd(0x03), withoutResponse: true);
        await Future.delayed(const Duration(milliseconds: 600));
        await wc.write(jbdCmd(0x04), withoutResponse: true);
        await done.future
            .timeout(const Duration(seconds: 4), onTimeout: () => false);
      } else {
        // model/serial once
        if (b.model.isEmpty) {
          rx.clear();
          await wc.write(readCmd(0x01, 0x00AA, 35), withoutResponse: true);
          await Future.delayed(const Duration(milliseconds: 700));
        }

        rx.clear();
        await wc.write(readCmd(0x01, 0x0000, 59), withoutResponse: true);

        await done.future
            .timeout(const Duration(seconds: 4), onTimeout: () => false);
      }
    } catch (_) {
      // keep whatever was decoded before the error
    } finally {
      await sub?.cancel();
      try {
        await d.disconnect();
      } catch (_) {}
    }

    if (gotLive) {
      b.online = true;
      b.failCount = 0;
    } else {
      b.failCount++;
      if (b.failCount >= 2) b.online = false;
    }
    if (mounted) setState(() {});
    return gotLive;
  }

  int _u16(List<int> d, int i) => (d[i * 2] << 8) | d[i * 2 + 1];
  int _s16(List<int> d, int i) {
    final v = _u16(d, i);
    return v > 32767 ? v - 65536 : v;
  }

  void _decodeLive(Battery b, List<int> d) {
    if (d.length < 118) return;
    // PACE reports positive = discharging. Flip it so the whole app uses
    // one convention: positive = charging, negative = discharging.
    b.current = -_s16(d, 0) / 100.0;
    b.voltage = _u16(d, 1) / 100.0;
    b.soc = _u16(d, 2);
    b.soh = _u16(d, 3);
    b.remainAh = _u16(d, 4) / 100.0; // <-- corrected register
    b.fullAh = _u16(d, 5) / 100.0;
    b.designAh = _u16(d, 6) / 100.0;
    b.cycles = _u16(d, 7);
    b.cellCount = _u16(d, 15);
    final n = b.cellCount.clamp(0, 16);
    b.cells = List.generate(n, (i) => _u16(d, 16 + i) / 1000.0);
    b.temp1 = _u16(d, 47) / 10.0;
    b.temp2 = _u16(d, 48) / 10.0;
    b.tempMos = _u16(d, 57) / 10.0;
    b.updated = DateTime.now();
  }

  void _decodeInfo(Battery b, List<int> d) {
    final txt = String.fromCharCodes(
        d.map((c) => (c >= 0x20 && c <= 0x7E) ? c : 0x20));
    final parts =
        txt.trim().split(RegExp(r'\s{2,}')).where((s) => s.isNotEmpty).toList();
    if (parts.isNotEmpty) b.model = parts[0].trim();
    if (parts.length > 1) b.serial = parts[1].trim();
  }

  // ---------- JBD decoders ----------
  // Byte-indexed helpers (the PACE ones are register-indexed).
  int _jb16(List<int> d, int i) => (d[i] << 8) | d[i + 1];
  int _js16(List<int> d, int i) {
    final v = _jb16(d, i);
    return v > 32767 ? v - 65536 : v;
  }

  void _decodeJbdBasic(Battery b, List<int> d) {
    if (d.length < 23) return;
    b.voltage = _jb16(d, 0) / 100.0;
    // JBD already uses negative = discharging, which matches our convention.
    b.current = _js16(d, 2) / 100.0;
    b.remainAh = _jb16(d, 4) / 100.0;
    b.fullAh = _jb16(d, 6) / 100.0;
    if (b.designAh == 0) b.designAh = b.fullAh;
    b.cycles = _jb16(d, 8);
    b.protect = _jb16(d, 16) != 0;
    b.soc = d[19];
    b.soh = 100;
    b.chgMos = (d[20] & 0x01) != 0;
    b.disMos = (d[20] & 0x02) != 0;
    b.cellCount = d[21];

    final ntc = d[22];
    final temps = <double>[];
    for (int i = 0; i < ntc; i++) {
      final off = 23 + i * 2;
      if (off + 1 >= d.length) break;
      temps.add((_jb16(d, off) - 2731) / 10.0);
    }
    if (temps.isNotEmpty) {
      b.temp1 = temps[0];
      b.temp2 = temps.length > 1 ? temps[1] : temps[0];
      b.tempMos = temps[0];
    }
    if (b.model.isEmpty) b.model = b.name;
    b.updated = DateTime.now();
  }

  void _decodeJbdCells(Battery b, List<int> d) {
    final cells = <double>[];
    for (int i = 0; i + 1 < d.length; i += 2) {
      cells.add(_jb16(d, i) / 1000.0);
    }
    if (cells.isEmpty) return;
    b.cells = cells;
    if (b.cellCount == 0) b.cellCount = cells.length;
    b.updated = DateTime.now();
  }

  // ---------- Monitoring loop ----------
  void _startMonitor() async {
    if (_batteries.isEmpty) return;
    setState(() {
      _monitoring = true;
      _status = 'المراقبة نشطة';
    });
    // Batteries restored from storage have no BLE handle yet — find them first.
    if (_active.any((b) => b.device == null)) {
      await _scan();
      if (!mounted || !_monitoring) return;
    }
    _loop?.cancel();
    _cycle();
    _loop = Timer.periodic(const Duration(seconds: 2), (_) => _cycle());
  }

  void _stopMonitor() {
    _loop?.cancel();
    setState(() {
      _monitoring = false;
      _status = 'المراقبة متوقفة';
    });
  }

  Future<void> _cycle() async {
    if (_cycleBusy || !_monitoring) return;
    _cycleBusy = true;
    try {
      if (_focusId != null) {
        final b = _batteries[_focusId];
        if (b != null) await _readBattery(b);
      } else {
        final act = _active;
        if (act.isEmpty) return;
        _rrIndex = _rrIndex % act.length;
        final b = act[_rrIndex];
        _rrIndex++;
        await _readBattery(b);
      }
    } finally {
      _cycleBusy = false;
    }
  }

  // ---------- Totals ----------
  List<Battery> get _live => _order
      .map((i) => _batteries[i]!)
      .where((b) => b.enabled && b.updated != null)
      .toList();

  /// Most recent successful read across the system
  DateTime? get _lastUpdate {
    DateTime? latest;
    for (final b in _live) {
      if (b.updated == null) continue;
      if (latest == null || b.updated!.isAfter(latest)) latest = b.updated;
    }
    return latest;
  }

  /// Oldest read among active batteries — shows if one is lagging
  DateTime? get _oldestUpdate {
    DateTime? oldest;
    for (final b in _live) {
      if (b.updated == null) continue;
      if (oldest == null || b.updated!.isBefore(oldest)) oldest = b.updated;
    }
    return oldest;
  }

  String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

  String _ago(DateTime t) {
    final s = DateTime.now().difference(t).inSeconds;
    if (s < 5) return kJustNow;
    if (s < 60) return '$s ${kSecondsAgo}';
    final m = s ~/ 60;
    return '$m ${kMinutesAgo}';
  }

  double get _totalCurrent =>
      _live.fold(0.0, (s, b) => s + b.current);
  double get _totalPower => _live.fold(0.0, (s, b) => s + b.power);
  double get _totalRemain => _live.fold(0.0, (s, b) => s + b.remainAh);
  double get _totalFull => _live.fold(0.0, (s, b) => s + b.fullAh);
  double get _avgSoc => _live.isEmpty
      ? 0
      : _live.fold(0.0, (s, b) => s + b.soc) / _live.length;
  double get _sysVoltage => _live.isEmpty
      ? 0
      : _live.fold(0.0, (s, b) => s + b.voltage) / _live.length;

  /// System-wide hours remaining, using total capacity and total current.
  /// Negative total current = discharging.
  double? get _sysHours {
    final i = _totalCurrent.abs();
    if (i < 0.5) return null;
    if (_totalCurrent < 0) {
      return _totalRemain / i;
    }
    final toFill = _totalFull - _totalRemain;
    if (toFill <= 0) return 0;
    return toFill / i;
  }

  String get _sysTimeText => formatHours(_sysHours);

  String get _sysTimeLabel {
    if (_totalCurrent > 0.5) return kUntilFull;
    if (_totalCurrent < -0.5) return kUntilEmpty;
    return kTimeLeft;
  }

  @override
  void dispose() {
    _loop?.cancel();
    _tick?.cancel();
    _scanSub?.cancel();
    super.dispose();
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('مراقب البطاريات'),
          actions: [
            if (_batteries.isNotEmpty) ...[
              IconButton(
                icon: const Icon(Icons.tune),
                tooltip: 'إدارة البطاريات',
                onPressed: _openManager,
              ),
              IconButton(
                icon: Icon(_monitoring ? Icons.pause : Icons.play_arrow),
                onPressed: _monitoring ? _stopMonitor : _startMonitor,
              ),
            ],
          ],
        ),
        body: _batteries.isEmpty ? _empty() : _main(),
        floatingActionButton: _batteries.isEmpty
            ? FloatingActionButton.extended(
                onPressed: _scanning ? null : _scan,
                icon: const Icon(Icons.search),
                label: const Text('بحث'),
              )
            : null,
      ),
    );
  }

  // ---------- Battery management ----------
  void _openManager() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: StatefulBuilder(
          builder: (ctx2, setSheet) => DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.8,
            builder: (_, scroll) => Column(
              children: [
                const SizedBox(height: 14),
                const Text('إدارة البطاريات',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                  child: Text(
                    'حدد البطاريات التابعة لهذه المنظومة فقط. غير المحددة لن تُقرأ ولن تدخل في الإجمالي.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    controller: scroll,
                    children: [
                      ..._order.map((id) {
                        final b = _batteries[id]!;
                        return CheckboxListTile(
                          value: b.enabled,
                          onChanged: (v) {
                            setSheet(() => b.enabled = v ?? false);
                            setState(() {
                              if (!b.enabled && _focusId == b.id) {
                                _focusId = null;
                              }
                            });
                            _savePrefs();
                          },
                          title: Text(b.displayName,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 14)),
                          subtitle: Text(
                            b.customName.isEmpty ? b.id : b.name,
                            style: const TextStyle(fontSize: 11),
                          ),
                          secondary: IconButton(
                            icon: const Icon(Icons.edit, size: 20),
                            onPressed: () async {
                              await _renameDialog(b);
                              setSheet(() {});
                            },
                          ),
                        );
                      }),
                      const Divider(),
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          children: [
                            SwitchListTile(
                              value: _showAll,
                              contentPadding: EdgeInsets.zero,
                              title: const Text('إظهار كل الأجهزة',
                                  style: TextStyle(fontSize: 13)),
                              subtitle: const Text(
                                'فعّلها إذا لم تظهر بطاريتك في البحث',
                                style: TextStyle(fontSize: 11),
                              ),
                              onChanged: (v) {
                                setSheet(() => _showAll = v);
                                setState(() {});
                              },
                            ),
                            SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                icon: const Icon(Icons.search),
                                label: const Text('بحث عن بطاريات جديدة'),
                                onPressed: _scanning
                                    ? null
                                    : () async {
                                        await _scan();
                                        setSheet(() {});
                                      },
                              ),
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: TextButton.icon(
                                icon: const Icon(Icons.delete_outline,
                                    color: Colors.redAccent),
                                label: const Text('حذف غير المحددة',
                                    style: TextStyle(color: Colors.redAccent)),
                                onPressed: () {
                                  setState(() {
                                    final rm = _order
                                        .where((i) => !_batteries[i]!.enabled)
                                        .toList();
                                    for (final i in rm) {
                                      _batteries.remove(i);
                                      _order.remove(i);
                                      if (_focusId == i) _focusId = null;
                                    }
                                  });
                                  _savePrefs();
                                  setSheet(() {});
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () {
                          setState(() => _configured = true);
                          _savePrefs();
                          Navigator.pop(ctx2);
                        },
                        child: const Text('حفظ'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _renameDialog(Battery b) async {
    final ctrl = TextEditingController(text: b.customName);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تسمية البطارية'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(b.name,
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'مثال: بطارية اليمين',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, '\u0000'),
              child: const Text('إزالة'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('حفظ'),
            ),
          ],
        ),
      ),
    );

    if (result == null) return;
    setState(() => b.customName = result == '\u0000' ? '' : result);
    await _savePrefs();
  }

  Widget _empty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (_scanning) const CircularProgressIndicator(),
          const SizedBox(height: 20),
          Icon(Icons.battery_unknown, size: 64, color: Colors.grey.shade700),
          const SizedBox(height: 12),
          Text(_status, style: const TextStyle(fontSize: 16)),
        ],
      ),
    );
  }

  Widget _main() {
    return Column(
      children: [
        // Mode selector
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _modeChip('الكل', _focusId == null, () {
                  setState(() => _focusId = null);
                }),
                ..._active.map((b) {
                  return _modeChip(b.shortName, _focusId == b.id, () {
                    setState(() => _focusId = b.id);
                  });
                }),
                const SizedBox(width: 6),
                ActionChip(
                  avatar: const Icon(Icons.tune, size: 18),
                  label: const Text('إدارة'),
                  onPressed: _openManager,
                ),
              ],
            ),
          ),
        ),
        if (_scanning) const LinearProgressIndicator(),
        Expanded(
          child: _focusId == null ? _overview() : _detail(_batteries[_focusId]!),
        ),
      ],
    );
  }

  Widget _modeChip(String label, bool sel, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: ChoiceChip(
        label: Text(label),
        selected: sel,
        onSelected: (_) => onTap(),
      ),
    );
  }

  Widget _overview() {
    final live = _live;
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        // System summary
        Card(
          color: Colors.teal.shade900.withValues(alpha: 0.4),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.hub, size: 20),
                    const SizedBox(width: 8),
                    Text('إجمالي النظام',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.teal.shade100)),
                  ],
                ),
                const SizedBox(height: 4),
                Text('مراقبة ${live.length} من ${_active.length} بطارية',
                    style:
                        const TextStyle(fontSize: 11, color: Colors.grey)),
                const SizedBox(height: 14),
                Text('${_avgSoc.toStringAsFixed(0)}%',
                    style: const TextStyle(
                        fontSize: 52, fontWeight: FontWeight.bold)),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: _avgSoc / 100,
                    minHeight: 12,
                    color: _avgSoc > 40
                        ? Colors.green
                        : _avgSoc > 20
                            ? Colors.orange
                            : Colors.red,
                  ),
                ),
                const SizedBox(height: 14),
                // Time remaining — the headline number
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _totalCurrent > 0.5
                            ? Icons.battery_charging_full
                            : Icons.timelapse,
                        size: 22,
                        color: Colors.tealAccent,
                      ),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_sysTimeText,
                              style: const TextStyle(
                                  fontSize: 22, fontWeight: FontWeight.bold)),
                          Text(_sysTimeLabel,
                              style: const TextStyle(
                                  fontSize: 10, color: Colors.grey)),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    _mini('الجهد', '${_sysVoltage.toStringAsFixed(2)} V'),
                    _mini('التيار الكلي',
                        '${_totalCurrent.abs().toStringAsFixed(1)} A'),
                    _mini('القدرة', '${_totalPower.abs().toStringAsFixed(0)} W'),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _mini('المتبقي', '${_totalRemain.toStringAsFixed(0)} Ah'),
                    _mini('السعة', '${_totalFull.toStringAsFixed(0)} Ah'),
                    _mini(
                        'الطاقة',
                        '${(_totalRemain * _sysVoltage / 1000).toStringAsFixed(2)} kWh'),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        // Each battery card (active only)
        ..._active.map((b) => _batteryCard(b)),
        const SizedBox(height: 14),
        // Last update line
        if (_lastUpdate != null)
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.update,
                      size: 18,
                      color: _monitoring ? Colors.tealAccent : Colors.grey),
                  const SizedBox(width: 10),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Text('آخر تحديث: ',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey)),
                          Text(_clock(_lastUpdate!),
                              style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  fontFeatures: [])),
                          const SizedBox(width: 6),
                          Text('(${_ago(_lastUpdate!)})',
                              style: const TextStyle(
                                  fontSize: 11, color: Colors.grey)),
                        ],
                      ),
                      if (_oldestUpdate != null &&
                          _lastUpdate!.difference(_oldestUpdate!).inSeconds > 3)
                        Text('أقدم قراءة: ${_clock(_oldestUpdate!)}',
                            style: const TextStyle(
                                fontSize: 10, color: Colors.grey)),
                    ],
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 6),
        Text(
          _monitoring
              ? 'التحديث بالتناوب — كل بطارية كل ~${_active.length * 4} ثانية'
              : 'المراقبة متوقفة — اضغط ▶ للتشغيل',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _mini(String label, String value) {
    return Expanded(
      child: Column(
        children: [
          Text(value,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          Text(label,
              style: const TextStyle(fontSize: 10, color: Colors.grey)),
        ],
      ),
    );
  }

  Widget _batteryCard(Battery b) {
    final never = b.updated == null;
    final statusColor = never
        ? Colors.grey
        : b.stale
            ? Colors.orange
            : b.charging
                ? Colors.green
                : b.discharging
                    ? Colors.amber
                    : Colors.blueGrey;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: InkWell(
        onTap: () => setState(() => _focusId = b.id),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                        color: statusColor, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(b.displayName,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 13),
                        overflow: TextOverflow.ellipsis),
                  ),
                  if (never)
                    const Text('لم تُقرأ بعد',
                        style: TextStyle(fontSize: 11, color: Colors.grey))
                  else if (b.stale)
                    const Text('قديمة',
                        style: TextStyle(fontSize: 11, color: Colors.orange)),
                  const Icon(Icons.chevron_left, size: 18),
                ],
              ),
              if (!never) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: Column(
                        children: [
                          Text('${b.soc}%',
                              style: const TextStyle(
                                  fontSize: 30, fontWeight: FontWeight.bold)),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: b.soc / 100,
                              minHeight: 6,
                              color: b.soc > 40
                                  ? Colors.green
                                  : b.soc > 20
                                      ? Colors.orange
                                      : Colors.red,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _kv('الجهد', '${b.voltage.toStringAsFixed(2)} V'),
                          _kv('التيار',
                              '${b.current.abs().toStringAsFixed(2)} A ${b.charging ? "▼" : b.discharging ? "▲" : ""}'),
                          _kv('المتبقي',
                              '${b.remainAh.toStringAsFixed(0)} Ah'),
                          _kv(b.timeLabel, b.timeText),
                          _kv('الحرارة',
                              '${b.temp1.toStringAsFixed(1)}\u00B0'),
                          _kv('فرق الخلايا',
                              '${b.cellDelta.toStringAsFixed(0)} mV'),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        children: [
          SizedBox(
              width: 52,
              child: Text(k,
                  style: const TextStyle(fontSize: 11, color: Colors.grey))),
          Text(v,
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  // ---------- Detail view ----------
  Widget _detail(Battery b) {
    if (b.updated == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('جاري قراءة ${b.name}...'),
          ],
        ),
      );
    }

    final statusText = b.charging
        ? 'جاري الشحن'
        : b.discharging
            ? 'جاري التفريغ'
            : 'ساكن';
    final statusColor = b.charging
        ? Colors.green
        : b.discharging
            ? Colors.orange
            : Colors.grey;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(b.displayName,
                          style: TextStyle(
                              fontSize: b.customName.isEmpty ? 12 : 15,
                              fontWeight: b.customName.isEmpty
                                  ? FontWeight.normal
                                  : FontWeight.bold,
                              color: b.customName.isEmpty
                                  ? Colors.grey
                                  : null),
                          overflow: TextOverflow.ellipsis),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit, size: 16),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => _renameDialog(b),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text('${b.soc}%',
                    style: const TextStyle(
                        fontSize: 60, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: b.soc / 100,
                    minHeight: 14,
                    color: b.soc > 40
                        ? Colors.green
                        : b.soc > 20
                            ? Colors.orange
                            : Colors.red,
                  ),
                ),
                const SizedBox(height: 14),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(statusText,
                      style: TextStyle(
                          color: statusColor, fontWeight: FontWeight.bold)),
                ),
                if (b.hoursRemaining != null) ...[
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.timelapse,
                          size: 20, color: Colors.tealAccent),
                      const SizedBox(width: 8),
                      Text(b.timeText,
                          style: const TextStyle(
                              fontSize: 24, fontWeight: FontWeight.bold)),
                      const SizedBox(width: 8),
                      Text(b.timeLabel,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.grey)),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        Row(children: [
          _tile('الجهد', '${b.voltage.toStringAsFixed(2)} V', Icons.bolt,
              Colors.amber),
          _tile(
              'التيار',
              '${b.current.abs().toStringAsFixed(2)} A',
              b.charging ? Icons.arrow_downward : Icons.arrow_upward,
              b.charging ? Colors.green : Colors.orange),
        ]),
        Row(children: [
          _tile('القدرة', '${b.power.abs().toStringAsFixed(0)} W',
              Icons.flash_on, Colors.purple),
          _tile('الصحة', '${b.soh}%', Icons.favorite, Colors.pink),
        ]),
        Row(children: [
          _tile('المتبقي', '${b.remainAh.toStringAsFixed(1)} Ah',
              Icons.battery_5_bar, Colors.teal),
          _tile('السعة الكاملة', '${b.fullAh.toStringAsFixed(0)} Ah',
              Icons.battery_full, Colors.blue),
        ]),
        Row(children: [
          _tile('الدورات', '${b.cycles}', Icons.loop, Colors.indigo),
          _tile('فرق الخلايا', '${b.cellDelta.toStringAsFixed(0)} mV',
              Icons.compare_arrows,
              b.cellDelta > 50 ? Colors.red : Colors.deepOrange),
        ]),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('جهد الخلايا',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                ...List.generate(b.cells.length, (i) {
                  final v = b.cells[i];
                  final isMin = v == b.cellMin && b.cellDelta > 5;
                  final isMax = v == b.cellMax && b.cellDelta > 5;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        SizedBox(width: 56, child: Text('خلية ${i + 1}')),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: ((v - 2.5) / (3.65 - 2.5)).clamp(0, 1),
                              minHeight: 8,
                              color: isMin
                                  ? Colors.red
                                  : isMax
                                      ? Colors.blue
                                      : Colors.green,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text('${v.toStringAsFixed(3)} V',
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 13)),
                      ],
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
        Row(children: [
          _tile('حرارة ١', '${b.temp1.toStringAsFixed(1)}°', Icons.thermostat,
              Colors.red),
          _tile('حرارة ٢', '${b.temp2.toStringAsFixed(1)}°', Icons.thermostat,
              Colors.red),
          _tile('MOS', '${b.tempMos.toStringAsFixed(1)}°', Icons.memory,
              Colors.redAccent),
        ]),
        if (b.protocol == 'jbd')
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _flag('مفتاح الشحن', b.chgMos),
                  _flag('مفتاح التفريغ', b.disMos),
                  _flag('لا إنذارات', !b.protect),
                ],
              ),
            ),
          ),
        if (b.model.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('البروتوكول: ${b.protocolLabel}',
                      style: const TextStyle(fontSize: 12)),
                  Text('الموديل: ${b.model}',
                      style: const TextStyle(fontSize: 12)),
                  if (b.serial.isNotEmpty)
                    Text('الرقم: ${b.serial}',
                        style: const TextStyle(fontSize: 12)),
                  Text('السعة التصميمية: ${b.designAh.toStringAsFixed(0)} Ah',
                      style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.all(10),
          child: Text(
            'آخر تحديث: ${b.updated!.hour.toString().padLeft(2, '0')}:${b.updated!.minute.toString().padLeft(2, '0')}:${b.updated!.second.toString().padLeft(2, '0')}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey, fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _flag(String label, bool ok) {
    return Column(
      children: [
        Icon(ok ? Icons.check_circle : Icons.cancel,
            color: ok ? Colors.green : Colors.redAccent, size: 26),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }

  Widget _tile(String label, String value, IconData icon, Color color) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 6),
          child: Column(
            children: [
              Icon(icon, color: color, size: 26),
              const SizedBox(height: 6),
              Text(value,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text(label,
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
        ),
      ),
    );
  }
}
