import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BMS Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const HomePage(),
    );
  }
}

// UUIDs discovered from the battery
final Guid kService = Guid('00002760-08c2-11e1-9073-0e8ac72e1001');
final Guid kWriteChar = Guid('00002760-08c2-11e1-9073-0e8ac72e0001');
final Guid kNotifyChar = Guid('00002760-08c2-11e1-9073-0e8ac72e0002');

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final List<String> _log = [];
  final List<ScanResult> _found = [];
  BluetoothDevice? _device;
  BluetoothCharacteristic? _write;
  BluetoothCharacteristic? _notify;
  StreamSubscription? _scanSub;
  StreamSubscription? _notifySub;
  bool _busy = false;
  int _frameCount = 0;
  int _byteCount = 0;

  void _add(String s) {
    final t = DateTime.now();
    final ts =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}.${t.millisecond.toString().padLeft(3, '0')}';
    setState(() => _log.insert(0, '[$ts] $s'));
  }

  String _hex(List<int> d) =>
      d.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');

  Future<void> _startScan() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    setState(() {
      _found.clear();
      _busy = true;
    });
    _add('--- بدء البحث ---');

    _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        if (r.device.platformName.isEmpty) continue;
        if (_found.any((f) => f.device.remoteId == r.device.remoteId)) continue;
        setState(() => _found.add(r));
      }
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
    await Future.delayed(const Duration(seconds: 8));
    setState(() => _busy = false);
    _add('--- انتهى البحث: ${_found.length} جهاز ---');
  }

  Future<void> _connect(BluetoothDevice d) async {
    setState(() => _busy = true);
    _device = d;
    _add('محاولة الاتصال بـ ${d.platformName}');

    try {
      await FlutterBluePlus.stopScan();
      await d.connect(timeout: const Duration(seconds: 15));
      _add('✅ تم الاتصال');

      try {
        await d.requestMtu(517);
        _add('MTU = 517');
      } catch (_) {
        _add('MTU لم يتغير (عادي)');
      }

      final services = await d.discoverServices();
      _add('عدد الخدمات: ${services.length}');

      for (final s in services) {
        if (s.uuid == kService) {
          for (final c in s.characteristics) {
            if (c.uuid == kWriteChar) _write = c;
            if (c.uuid == kNotifyChar) _notify = c;
          }
        }
      }

      if (_write == null || _notify == null) {
        _add('❌ لم يتم العثور على الخدمة المطلوبة');
        setState(() => _busy = false);
        return;
      }
      _add('✅ تم العثور على الخدمة');

      await _notify!.setNotifyValue(true);
      _add('✅ تم تفعيل الاستقبال');

      _notifySub?.cancel();
      _notifySub = _notify!.lastValueStream.listen((data) {
        if (data.isEmpty) return;
        _frameCount++;
        _byteCount += data.length;
        _add('📥 [${data.length} بايت] ${_hex(data)}');
      });

      setState(() => _busy = false);
    } catch (e) {
      _add('❌ خطأ: $e');
      setState(() => _busy = false);
    }
  }

  // JK BMS command builder: 0xAA 0x55 0x90 0xEB, cmd, len, 4-byte value, pad to 19, checksum
  Uint8List _jkCmd(int cmd, {int value = 0}) {
    final b = Uint8List(20);
    b[0] = 0xAA;
    b[1] = 0x55;
    b[2] = 0x90;
    b[3] = 0xEB;
    b[4] = cmd;
    b[5] = 0x00;
    b[6] = value & 0xFF;
    b[7] = (value >> 8) & 0xFF;
    b[8] = (value >> 16) & 0xFF;
    b[9] = (value >> 24) & 0xFF;
    int sum = 0;
    for (int i = 0; i < 19; i++) {
      sum += b[i];
    }
    b[19] = sum & 0xFF;
    return b;
  }

  Future<void> _send(Uint8List cmd, String label) async {
    if (_write == null) {
      _add('❌ غير متصل');
      return;
    }
    _add('📤 $label → ${_hex(cmd)}');
    try {
      await _write!.write(cmd, withoutResponse: true);
    } catch (e) {
      _add('❌ فشل الإرسال: $e');
    }
  }

  Future<void> _runSequence() async {
    setState(() {
      _busy = true;
      _frameCount = 0;
      _byteCount = 0;
    });
    _add('=================================');
    _add('بدء تسلسل الأوامر');

    // Device info
    await _send(_jkCmd(0x97), 'معلومات الجهاز (0x97)');
    await Future.delayed(const Duration(milliseconds: 1500));

    // Settings
    await _send(_jkCmd(0x96), 'الإعدادات (0x96)');
    await Future.delayed(const Duration(milliseconds: 1500));

    // Live data
    await _send(_jkCmd(0x96), 'البيانات الحية (0x96)');
    await Future.delayed(const Duration(milliseconds: 2500));

    _add('=================================');
    _add('انتهى — الرسائل: $_frameCount | البايتات: $_byteCount');
    setState(() => _busy = false);
  }

  Future<void> _probe() async {
    setState(() {
      _busy = true;
      _frameCount = 0;
      _byteCount = 0;
    });
    _add('=================================');
    _add('فحص شامل — تجربة كل الأوامر');

    for (int cmd in [0x96, 0x97, 0x98, 0x00, 0x01, 0x02, 0x03, 0x10, 0x20]) {
      await _send(
          _jkCmd(cmd), 'أمر 0x${cmd.toRadixString(16).toUpperCase()}');
      await Future.delayed(const Duration(milliseconds: 1200));
    }

    _add('=================================');
    _add('انتهى — الرسائل: $_frameCount | البايتات: $_byteCount');
    setState(() => _busy = false);
  }

  Future<void> _disconnect() async {
    await _notifySub?.cancel();
    await _device?.disconnect();
    setState(() {
      _device = null;
      _write = null;
      _notify = null;
    });
    _add('تم قطع الاتصال');
  }

  void _copyLog() {
    Clipboard.setData(ClipboardData(text: _log.reversed.join('\n')));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('تم نسخ السجل')),
    );
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _notifySub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _write != null;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('فاحص البطارية'),
          actions: [
            IconButton(icon: const Icon(Icons.copy), onPressed: _copyLog),
            IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => setState(() => _log.clear())),
          ],
        ),
        body: Column(
          children: [
            if (_busy) const LinearProgressIndicator(),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton.icon(
                    onPressed: _busy ? null : _startScan,
                    icon: const Icon(Icons.search),
                    label: const Text('بحث'),
                  ),
                  ElevatedButton.icon(
                    onPressed: (_busy || !connected) ? null : _runSequence,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('تسلسل الأوامر'),
                  ),
                  ElevatedButton.icon(
                    onPressed: (_busy || !connected) ? null : _probe,
                    icon: const Icon(Icons.travel_explore),
                    label: const Text('فحص شامل'),
                  ),
                  if (connected)
                    ElevatedButton.icon(
                      onPressed: _disconnect,
                      icon: const Icon(Icons.link_off),
                      label: const Text('قطع'),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.red.shade900),
                    ),
                ],
              ),
            ),
            if (_found.isNotEmpty && !connected)
              SizedBox(
                height: 120,
                child: ListView.builder(
                  itemCount: _found.length,
                  itemBuilder: (_, i) {
                    final r = _found[i];
                    final isBms =
                        r.device.platformName.toUpperCase().contains('BMS');
                    return ListTile(
                      dense: true,
                      leading: Icon(Icons.bluetooth,
                          color: isBms ? Colors.green : Colors.grey),
                      title: Text(r.device.platformName,
                          style: TextStyle(
                              fontWeight:
                                  isBms ? FontWeight.bold : FontWeight.normal)),
                      subtitle: Text('${r.device.remoteId} • ${r.rssi} dBm'),
                      trailing: const Icon(Icons.chevron_left),
                      onTap: () => _connect(r.device),
                    );
                  },
                ),
              ),
            if (connected)
              Container(
                width: double.infinity,
                color: Colors.green.shade900,
                padding: const EdgeInsets.all(8),
                child: Text(
                  'متصل: ${_device?.platformName ?? ""}  |  الرسائل: $_frameCount  |  البايتات: $_byteCount',
                  textAlign: TextAlign.center,
                ),
              ),
            const Divider(height: 1),
            Expanded(
              child: Container(
                color: Colors.black,
                child: ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: _log.length,
                  itemBuilder: (_, i) {
                    final line = _log[i];
                    Color c = Colors.white70;
                    if (line.contains('📥')) c = Colors.greenAccent;
                    if (line.contains('📤')) c = Colors.cyanAccent;
                    if (line.contains('❌')) c = Colors.redAccent;
                    if (line.contains('✅')) c = Colors.lightGreenAccent;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        line,
                        textDirection: TextDirection.ltr,
                        style: TextStyle(
                            fontFamily: 'monospace', fontSize: 11, color: c),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
