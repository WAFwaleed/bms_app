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
      title: 'مراقب البطارية',
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

class BatteryData {
  double current = 0;
  double voltage = 0;
  int soc = 0;
  int soh = 0;
  double remainAh = 0;
  double fullAh = 0;
  int cycles = 0;
  int cellCount = 0;
  List<double> cells = [];
  double temp1 = 0;
  double temp2 = 0;
  double tempMos = 0;
  DateTime? updated;

  double get power => voltage * current;
  bool get charging => current > 0.05;
  bool get discharging => current < -0.05;
  double get cellMin =>
      cells.isEmpty ? 0 : cells.reduce((a, b) => a < b ? a : b);
  double get cellMax =>
      cells.isEmpty ? 0 : cells.reduce((a, b) => a > b ? a : b);
  double get cellDelta => cells.isEmpty ? 0 : (cellMax - cellMin) * 1000;
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final List<ScanResult> _found = [];
  BluetoothDevice? _device;
  BluetoothCharacteristic? _write;
  BluetoothCharacteristic? _notify;
  StreamSubscription? _scanSub;
  StreamSubscription? _notifySub;
  Timer? _poll;

  final BatteryData _bat = BatteryData();
  String _model = '';
  String _serial = '';

  bool _busy = false;
  bool _connected = false;
  String _status = 'اضغط بحث للبدء';

  final List<int> _rx = [];

  static int _crc16(List<int> data) {
    int crc = 0xFFFF;
    for (final b in data) {
      crc ^= b;
      for (int i = 0; i < 8; i++) {
        crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1;
      }
    }
    return crc;
  }

  static Uint8List _readCmd(int addr, int reg, int count) {
    final b = <int>[
      addr,
      0x03,
      (reg >> 8) & 0xFF,
      reg & 0xFF,
      (count >> 8) & 0xFF,
      count & 0xFF,
    ];
    final crc = _crc16(b);
    b.add(crc & 0xFF);
    b.add((crc >> 8) & 0xFF);
    return Uint8List.fromList(b);
  }

  Future<void> _scan() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    setState(() {
      _found.clear();
      _busy = true;
      _status = 'جاري البحث...';
    });

    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (r.device.platformName.isEmpty) continue;
        if (!r.device.platformName.toUpperCase().contains('BMS')) continue;
        if (_found.any((f) => f.device.remoteId == r.device.remoteId)) continue;
        setState(() => _found.add(r));
      }
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));
    await Future.delayed(const Duration(seconds: 6));
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = _found.isEmpty ? 'لم يتم العثور على بطاريات' : 'اختر البطارية';
    });
  }

  Future<void> _connect(BluetoothDevice d) async {
    setState(() {
      _busy = true;
      _status = 'جاري الاتصال...';
    });
    _device = d;

    try {
      await FlutterBluePlus.stopScan();
      await d.connect(timeout: const Duration(seconds: 15));
      try {
        await d.requestMtu(517);
      } catch (_) {}

      final services = await d.discoverServices();
      for (final s in services) {
        if (s.uuid == kService) {
          for (final c in s.characteristics) {
            if (c.uuid == kWriteChar) _write = c;
            if (c.uuid == kNotifyChar) _notify = c;
          }
        }
      }

      if (_write == null || _notify == null) {
        setState(() {
          _busy = false;
          _status = 'لم يتم العثور على خدمة البطارية';
        });
        return;
      }

      await _notify!.setNotifyValue(true);
      _notifySub?.cancel();
      _notifySub = _notify!.lastValueStream.listen(_onData);

      setState(() {
        _connected = true;
        _busy = false;
        _status = 'متصل';
      });

      await Future.delayed(const Duration(milliseconds: 400));
      await _send(_readCmd(0x01, 0x00AA, 35));
      await Future.delayed(const Duration(milliseconds: 900));
      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'فشل الاتصال — حاول مرة أخرى';
      });
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  Future<void> _refresh() async {
    if (_write == null) return;
    await _send(_readCmd(0x01, 0x0000, 59));
  }

  Future<void> _send(Uint8List cmd) async {
    _rx.clear();
    try {
      await _write!.write(cmd, withoutResponse: true);
    } catch (_) {}
  }

  void _onData(List<int> data) {
    if (data.isEmpty) return;
    _rx.addAll(data);

    if (_rx.length < 3) return;
    if (_rx[1] != 0x03) {
      _rx.clear();
      return;
    }
    final byteCount = _rx[2];
    final total = 3 + byteCount + 2;
    if (_rx.length < total) return;

    final frame = List<int>.from(_rx.sublist(0, total));
    _rx.clear();

    if (_crc16(frame) != 0) return;

    final payload = frame.sublist(3, 3 + byteCount);
    if (byteCount >= 110) {
      _decodeLive(payload);
    } else if (byteCount >= 60) {
      _decodeInfo(payload);
    }
  }

  int _u16(List<int> d, int i) => (d[i * 2] << 8) | d[i * 2 + 1];
  int _s16(List<int> d, int i) {
    final v = _u16(d, i);
    return v > 32767 ? v - 65536 : v;
  }

  void _decodeLive(List<int> d) {
    if (d.length < 118) return;
    final b = _bat;
    b.current = _s16(d, 0) / 100.0;
    b.voltage = _u16(d, 1) / 100.0;
    b.soc = _u16(d, 2);
    b.soh = _u16(d, 3);
    b.remainAh = _u16(d, 5) / 100.0;
    b.fullAh = _u16(d, 6) / 100.0;
    b.cycles = _u16(d, 7);
    b.cellCount = _u16(d, 15);

    final n = b.cellCount.clamp(0, 16);
    b.cells = List.generate(n, (i) => _u16(d, 16 + i) / 1000.0);

    b.temp1 = _u16(d, 47) / 10.0;
    b.temp2 = _u16(d, 48) / 10.0;
    b.tempMos = _u16(d, 57) / 10.0;
    b.updated = DateTime.now();
    if (mounted) setState(() {});
  }

  void _decodeInfo(List<int> d) {
    final txt = String.fromCharCodes(
        d.map((c) => (c >= 0x20 && c <= 0x7E) ? c : 0x20));
    final parts =
        txt.trim().split(RegExp(r'\s{2,}')).where((s) => s.isNotEmpty).toList();
    if (!mounted) return;
    setState(() {
      if (parts.isNotEmpty) _model = parts[0].trim();
      if (parts.length > 1) _serial = parts[1].trim();
    });
  }

  Future<void> _disconnect() async {
    _poll?.cancel();
    await _notifySub?.cancel();
    await _device?.disconnect();
    if (!mounted) return;
    setState(() {
      _connected = false;
      _write = null;
      _notify = null;
      _bat.updated = null;
      _status = 'اضغط بحث للبدء';
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _scanSub?.cancel();
    _notifySub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('مراقب البطارية'),
          actions: [
            if (_connected)
              IconButton(
                  icon: const Icon(Icons.link_off), onPressed: _disconnect),
          ],
        ),
        body: _connected ? _dashboard() : _scanView(),
        floatingActionButton: _connected
            ? null
            : FloatingActionButton.extended(
                onPressed: _busy ? null : _scan,
                icon: const Icon(Icons.search),
                label: const Text('بحث'),
              ),
      ),
    );
  }

  Widget _scanView() {
    return Column(
      children: [
        if (_busy) const LinearProgressIndicator(),
        Padding(
          padding: const EdgeInsets.all(20),
          child: Text(_status, style: const TextStyle(fontSize: 16)),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: _found.length,
            itemBuilder: (_, i) {
              final r = _found[i];
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: ListTile(
                  leading: const Icon(Icons.battery_charging_full,
                      color: Colors.green, size: 32),
                  title: Text(r.device.platformName,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text('قوة الإشارة: ${r.rssi} dBm'),
                  trailing: const Icon(Icons.chevron_left),
                  onTap: () => _connect(r.device),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _dashboard() {
    final b = _bat;
    if (b.updated == null) {
      return const Center(child: CircularProgressIndicator());
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

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Text('${b.soc}%',
                      style: const TextStyle(
                          fontSize: 64, fontWeight: FontWeight.bold)),
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
            _tile('المتبقي', '${b.remainAh.toStringAsFixed(0)} Ah',
                Icons.battery_5_bar, Colors.teal),
            _tile('السعة الكلية', '${b.fullAh.toStringAsFixed(0)} Ah',
                Icons.battery_full, Colors.blue),
          ]),
          Row(children: [
            _tile('الدورات', '${b.cycles}', Icons.loop, Colors.indigo),
            _tile('فرق الخلايا', '${b.cellDelta.toStringAsFixed(0)} mV',
                Icons.compare_arrows, Colors.deepOrange),
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
                          SizedBox(width: 60, child: Text('خلية ${i + 1}')),
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
          if (_model.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('الموديل: $_model',
                        style: const TextStyle(fontSize: 13)),
                    if (_serial.isNotEmpty)
                      Text('الرقم: $_serial',
                          style: const TextStyle(fontSize: 13)),
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
      ),
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
