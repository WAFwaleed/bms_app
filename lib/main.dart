import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

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

final Guid kService = Guid('00002760-08c2-11e1-9073-0e8ac72e1001');
final Guid kWriteChar = Guid('00002760-08c2-11e1-9073-0e8ac72e0001');
final Guid kNotifyChar = Guid('00002760-08c2-11e1-9073-0e8ac72e0002');

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

// ============ Battery model ============
class Battery {
  final String id;
  final String name;
  BluetoothDevice? device;

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

  DateTime? updated;
  bool online = false;
  int failCount = 0;

  Battery(this.id, this.name);

  double get power => voltage * current;
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

  /// Formatted like "5 س 30 د"
  String get timeText {
    final h = hoursRemaining;
    if (h == null) return '—';
    if (h > 99) return '+99 س';
    final total = (h * 60).round();
    final hh = total ~/ 60;
    final mm = total % 60;
    if (hh == 0) return '$mm د';
    return '$hh س $mm د';
  }

  String get timeLabel => charging
      ? 'حتى الامتلاء'
      : discharging
          ? 'حتى الفراغ'
          : 'الوقت المتبقي';

  double get cellMin =>
      cells.isEmpty ? 0 : cells.reduce((a, b) => a < b ? a : b);
  double get cellMax =>
      cells.isEmpty ? 0 : cells.reduce((a, b) => a > b ? a : b);
  double get cellDelta => cells.isEmpty ? 0 : (cellMax - cellMin) * 1000;

  bool get stale =>
      updated == null || DateTime.now().difference(updated!).inSeconds > 45;

  /// Short label e.g. "…159P"
  String get shortName {
    if (name.length <= 5) return name;
    return '…${name.substring(name.length - 5)}';
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
  int _rrIndex = 0;
  bool _cycleBusy = false;

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
        if (n.isEmpty || !n.toUpperCase().contains('BMS')) continue;
        final id = r.device.remoteId.str;
        if (!_batteries.containsKey(id)) {
          final b = Battery(id, n.trim());
          b.device = r.device;
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

    void handle(List<int> data) {
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

    try {
      await d.connect(timeout: const Duration(seconds: 8));
      try {
        await d.requestMtu(517);
      } catch (_) {}

      final services = await d.discoverServices();
      for (final s in services) {
        if (s.uuid == kService) {
          for (final c in s.characteristics) {
            if (c.uuid == kWriteChar) wc = c;
            if (c.uuid == kNotifyChar) nc = c;
          }
        }
      }
      if (wc == null || nc == null) {
        await d.disconnect();
        return false;
      }

      await nc.setNotifyValue(true);
      sub = nc.lastValueStream.listen(handle);

      // model/serial once
      if (b.model.isEmpty) {
        rx.clear();
        await wc.write(readCmd(0x01, 0x00AA, 35), withoutResponse: true);
        await Future.delayed(const Duration(milliseconds: 700));
      }

      rx.clear();
      await wc.write(readCmd(0x01, 0x0000, 59), withoutResponse: true);

      await done.future.timeout(const Duration(seconds: 4),
          onTimeout: () => false);
    } catch (_) {
      gotLive = false;
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
    b.current = _s16(d, 0) / 100.0;
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

  // ---------- Monitoring loop ----------
  void _startMonitor() {
    if (_batteries.isEmpty) return;
    setState(() {
      _monitoring = true;
      _status = 'المراقبة نشطة';
    });
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
        if (_order.isEmpty) return;
        _rrIndex = _rrIndex % _order.length;
        final b = _batteries[_order[_rrIndex]];
        _rrIndex++;
        if (b != null) await _readBattery(b);
      }
    } finally {
      _cycleBusy = false;
    }
  }

  // ---------- Totals ----------
  List<Battery> get _live =>
      _order.map((i) => _batteries[i]!).where((b) => b.updated != null).toList();

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

  /// System-wide hours remaining, using total capacity and total current
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

  String get _sysTimeText {
    final h = _sysHours;
    if (h == null) return '—';
    if (h > 99) return '+99 س';
    final total = (h * 60).round();
    final hh = total ~/ 60;
    final mm = total % 60;
    if (hh == 0) return '$mm د';
    return '$hh س $mm د';
  }

  String get _sysTimeLabel => _totalCurrent > 0.5
      ? 'حتى الامتلاء'
      : _totalCurrent < -0.5
          ? 'حتى الفراغ'
          : 'الوقت المتبقي';

  @override
  void dispose() {
    _loop?.cancel();
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
            if (_batteries.isNotEmpty)
              IconButton(
                icon: Icon(_monitoring ? Icons.pause : Icons.play_arrow),
                onPressed: _monitoring ? _stopMonitor : _startMonitor,
              ),
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
                ..._order.map((id) {
                  final b = _batteries[id]!;
                  return _modeChip(b.shortName, _focusId == id, () {
                    setState(() => _focusId = id);
                  });
                }),
                const SizedBox(width: 6),
                ActionChip(
                  avatar: const Icon(Icons.refresh, size: 18),
                  label: const Text('بحث'),
                  onPressed: _scanning ? null : _scan,
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
                Text('مراقبة ${live.length} من ${_batteries.length} بطارية',
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
        // Each battery card
        ..._order.map((id) => _batteryCard(_batteries[id]!)),
        const SizedBox(height: 12),
        Text(
          _monitoring
              ? 'التحديث بالتناوب — كل بطارية كل ~${_batteries.length * 4} ثانية'
              : 'المراقبة متوقفة — اضغط ▶ للتشغيل',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
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
                    child: Text(b.name,
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
                              '${b.temp1.toStringAsFixed(1)}°  |  فرق ${b.cellDelta.toStringAsFixed(0)}mV'),
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
                Text(b.name,
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
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
        if (b.model.isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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
