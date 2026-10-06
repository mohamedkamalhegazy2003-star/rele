import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart' as intl;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:sqflite/sqflite.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';

@pragma('vm:entry-point')
void notificationCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    final plugin = FlutterLocalNotificationsPlugin();
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await plugin.initialize(const InitializationSettings(android: android));
    const details = NotificationDetails(android: AndroidNotificationDetails(
      'rent_reminders', 'تنبيهات إدارة العقارات',
      channelDescription: 'تنبيهات دورية لمراجعة المستحقات',
      importance: Importance.high, priority: Priority.high));
    await plugin.show(4001, 'إدارة العقارات', 'راجع الإيجارات والمرافق والمستحقات الحالية.', details);
    return Future.value(true);
  });
}

Future<void> _initNotifications() async {
  final plugin = FlutterLocalNotificationsPlugin();
  const android = AndroidInitializationSettings('@mipmap/ic_launcher');
  await plugin.initialize(const InitializationSettings(android: android));
  await plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
  await Workmanager().initialize(notificationCallbackDispatcher);
  await Workmanager().registerPeriodicTask('real-estate-4h', 'periodicLocalNotification',
      frequency: const Duration(hours: 4));
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RealEstateApp());
  await Future<void>.delayed(Duration.zero);
  try { await _initNotifications(); } catch (_) {}
}

const kStatuses = ['مؤجر', 'شاغر', 'متأخرات'];
final _money = intl.NumberFormat('#,##0.##');
String fmt(num v) => '${_money.format(v)} ج.م';

Color statusColor(String? s) {
  switch (s) {
    case 'مؤجر':
      return const Color(0xFF2E7D32);
    case 'متأخرات':
      return const Color(0xFFC62828);
    default:
      return const Color(0xFFEF6C00);
  }
}

double num0(dynamic v) => (v is num) ? v.toDouble() : 0.0;

// ---------------- التواريخ والتنبيهات ----------------
/// عدد الأيام قبل الاستحقاق التي يبدأ عندها التنبيه بقرب السداد.
const kReminderDays = 3;
final _dateFmt = intl.DateFormat('yyyy/MM/dd');
final _isoFmt = intl.DateFormat('yyyy-MM-dd');

String plain(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toString();

DateTime? parseDue(Map<String, dynamic> i) {
  final d = DateTime.tryParse((i['due_date'] ?? '').toString());
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

/// سالب = متأخر، 0 = اليوم، موجب = متبقي. null = لا يوجد تاريخ استحقاق.
int? daysToDue(Map<String, dynamic> i) {
  final d = parseDue(i);
  if (d == null) return null;
  final n = DateTime.now();
  return DateTime.utc(d.year, d.month, d.day)
      .difference(DateTime.utc(n.year, n.month, n.day))
      .inDays;
}

DateTime addMonths(DateTime d, int m) {
  final total = d.year * 12 + (d.month - 1) + m;
  final y = total ~/ 12;
  final mo = total % 12 + 1;
  final last = DateTime(y, mo + 1, 0).day;
  return DateTime(y, mo, d.day > last ? last : d.day);
}

/// الحالة الفعلية: إن وُجد تاريخ استحقاق فهو الذي يحدد (مؤجر/متأخرات).
String effStatus(Map<String, dynamic> i) {
  final st = (i['status'] ?? 'مؤجر').toString();
  if (st == 'شاغر') return st;
  final d = daysToDue(i);
  if (d == null) return st;
  return d < 0 ? 'متأخرات' : 'مؤجر';
}

String dueText(Map<String, dynamic> i) {
  final d = parseDue(i);
  final days = daysToDue(i);
  if (d == null || days == null) return 'غير محدد';
  var t = _dateFmt.format(d);
  if (days < 0) {
    t += '  (متأخر ${-days} يوم)';
  } else if (days == 0) {
    t += '  (اليوم)';
  } else if (days <= kReminderDays) {
    t += '  (بعد $days يوم)';
  }
  return t;
}

String receiptNo(dynamic payOrSerial, [int? propertyId]) {
  if (payOrSerial is Map) {
    final serial = (payOrSerial['receipt_serial'] as num?)?.toInt();
    if (serial != null && serial > 0) return serial.toString();
    final pid = (payOrSerial['property_id'] as num?)?.toInt() ?? 0;
    final id = (payOrSerial['id'] as num?)?.toInt() ?? 0;
    return (pid * 100000 + id).toString();
  }
  final n = (payOrSerial as num).toInt();
  return propertyId == null ? n.toString() : (propertyId * 100000 + n).toString();
}

class AppCard extends StatelessWidget {
  final Widget child;
  final Clip clipBehavior;
  const AppCard({super.key, required this.child, this.clipBehavior = Clip.none});

  @override
  Widget build(BuildContext context) => Card(
        elevation: 0,
        color: Colors.white,
        margin: EdgeInsets.zero,
        clipBehavior: clipBehavior,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.black.withAlpha(15)),
        ),
        child: child,
      );
}

class RealEstateApp extends StatelessWidget {
  const RealEstateApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF1B5E85));
    return MaterialApp(
      title: 'إدارة العقارات',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar', 'EG'),
      supportedLocales: const [Locale('ar', 'EG')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFFF4F7FA),
        appBarTheme: const AppBarTheme(
          centerTitle: true,
          scrolledUnderElevation: 0,
          backgroundColor: Color(0xFFF4F7FA),
          systemOverlayStyle: SystemUiOverlayStyle.dark,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Colors.black.withAlpha(30)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Colors.black.withAlpha(30)),
          ),
        ),
      ),
      home: const AuthGate(),
    );
  }
}

// ---------------------------------------------------------
// Database
// ---------------------------------------------------------
class DB {
  static Database? _db;
  static Future<Database> get db async => _db ??= await _init();

  static Future<void> _createPayments(Database db) => db.execute('''
    CREATE TABLE IF NOT EXISTS payments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      property_id INTEGER,
      property_name TEXT, tenant_name TEXT, tenant_phone TEXT,
      rent_amount REAL, electricity REAL, water REAL, gas REAL,
      amount REAL, paid_at TEXT, due_date TEXT, note TEXT,
      payment_type TEXT DEFAULT 'rent', utility_due_id INTEGER,
      receipt_serial INTEGER
    )
  ''');

  static Future<void> _createExtras(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS utility_dues (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      property_id INTEGER NOT NULL, kind TEXT NOT NULL, note TEXT,
      amount REAL NOT NULL DEFAULT 0, paid_amount REAL NOT NULL DEFAULT 0,
      created_at TEXT
    )''');
    await db.execute('''CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL,
      full_name TEXT, password TEXT NOT NULL, is_primary INTEGER NOT NULL DEFAULT 0
    )''');
    final c = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM users')) ?? 0;
    if (c == 0) {
      await db.insert('users', {'username':'admin','full_name':'المستخدم الرئيسي','password':'admin123','is_primary':1});
      await db.insert('users', {'username':'backup','full_name':'الحساب البديل','password':'backup123','is_primary':0});
    }
  }

  static Future<bool> _hasColumn(Database db, String table, String col) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    return rows.any((r) => r['name'] == col);
  }
  static Future<void> _addCol(Database db, String table, String col, String type) async {
    if (!await _hasColumn(db, table, col)) await db.execute('ALTER TABLE $table ADD COLUMN $col $type');
  }

  static Future<Database> _init() async {
    final path = p.join(await getDatabasesPath(), 'real_estate.db');
    return openDatabase(path, version: 6,
      onCreate: (db, v) async {
        await db.execute('''CREATE TABLE properties (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT, address TEXT, location TEXT,
          tenant_name TEXT, tenant_phone TEXT, tenant_alt_phone TEXT,
          rent_amount REAL, deposit_amount REAL, electricity REAL, water REAL, gas REAL,
          status TEXT, id_card_path TEXT, contract_path TEXT,
          id_card_paths TEXT DEFAULT '[]', contract_paths TEXT DEFAULT '[]', due_date TEXT
        )''');
        await _createPayments(db);
        await _createExtras(db);
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          await _addCol(db, 'properties', 'due_date', 'TEXT');
          await _createPayments(db);
        }
        await _addCol(db, 'properties', 'location', 'TEXT');
        await _addCol(db, 'properties', 'tenant_alt_phone', 'TEXT');
        await _addCol(db, 'properties', 'id_card_paths', "TEXT DEFAULT '[]'");
        await _addCol(db, 'properties', 'contract_paths', "TEXT DEFAULT '[]'");
        await _addCol(db, 'payments', 'payment_type', "TEXT DEFAULT 'rent'");
        await _addCol(db, 'payments', 'utility_due_id', 'INTEGER');
        await _addCol(db, 'payments', 'receipt_serial', 'INTEGER');
        await _createExtras(db);
        final props = await db.query('properties');
        for (final pr in props) {
          final id = pr['id'] as int;
          final oldId = (pr['id_card_path'] ?? '').toString();
          final oldContract = (pr['contract_path'] ?? '').toString();
          final idPaths = (pr['id_card_paths'] ?? '').toString();
          final contractPaths = (pr['contract_paths'] ?? '').toString();
          final patch = <String,dynamic>{};
          if ((idPaths.isEmpty || idPaths == '[]') && oldId.isNotEmpty) patch['id_card_paths'] = jsonEncode([oldId]);
          if ((contractPaths.isEmpty || contractPaths == '[]') && oldContract.isNotEmpty) patch['contract_paths'] = jsonEncode([oldContract]);
          if (patch.isNotEmpty) await db.update('properties', patch, where:'id=?', whereArgs:[id]);
          final pays = await db.query('payments', where:'property_id=?', whereArgs:[id], orderBy:'id ASC');
          var seq = 1;
          for (final pay in pays) {
            if ((pay['receipt_serial'] as num?)?.toInt() == null) {
              await db.update('payments', {'receipt_serial': id * 100000 + seq}, where:'id=?', whereArgs:[pay['id']]);
            }
            seq++;
          }
        }
      },
      onOpen: (db) async => _createExtras(db),
    );
  }

  static Future<List<Map<String,dynamic>>> all() async => (await db).query('properties', orderBy:'id DESC');
  static Future<int> insert(Map<String,dynamic> d) async => (await db).insert('properties', d);
  static Future<int> update(int id, Map<String,dynamic> d) async => (await db).update('properties', d, where:'id=?', whereArgs:[id]);
  static Future<int> delete(int id) async => (await db).delete('properties', where:'id=?', whereArgs:[id]);
  static Future<List<Map<String,dynamic>>> allPayments() async => (await db).query('payments', orderBy:'id DESC');
  static Future<List<Map<String,dynamic>>> paymentsForProperty(int id) async => (await db).query('payments', where:'property_id=?', whereArgs:[id], orderBy:'id DESC');

  static Future<int> _nextReceiptSerial(Transaction tx, int propertyId) async {
    final r = await tx.rawQuery('SELECT MAX(receipt_serial) AS m FROM payments WHERE property_id=?', [propertyId]);
    final max = (r.first['m'] as num?)?.toInt();
    return max == null || max < propertyId * 100000 ? propertyId * 100000 + 1 : max + 1;
  }

  static Future<Map<String,int>> recordPayment(int propId, Map<String,dynamic> pay, String newDue) async {
    final d = await db;
    return d.transaction((tx) async {
      final serial = await _nextReceiptSerial(tx, propId);
      pay['receipt_serial'] = serial;
      pay['payment_type'] ??= 'rent';
      final id = await tx.insert('payments', pay);
      if (pay['payment_type'] == 'rent') {
        await tx.update('properties', {'due_date':newDue,'status':'مؤجر'}, where:'id=?', whereArgs:[propId]);
      } else if (pay['utility_due_id'] != null) {
        await tx.update('utility_dues', {'paid_amount':pay['amount']}, where:'id=?', whereArgs:[pay['utility_due_id']]);
      }
      return {'id':id,'receipt_serial':serial};
    });
  }

  static Future<void> updatePayment(int id, double amount, String note, String paidAt) async {
    final d = await db;
    await d.transaction((tx) async {
      final rows = await tx.query('payments', where:'id=?', whereArgs:[id], limit:1);
      if (rows.isEmpty) return;
      final old = rows.first;
      await tx.update('payments', {'amount':amount,'note':note,'paid_at':paidAt}, where:'id=?', whereArgs:[id]);
      final dueId = (old['utility_due_id'] as num?)?.toInt();
      if (dueId != null) await tx.update('utility_dues', {'paid_amount':amount}, where:'id=?', whereArgs:[dueId]);
    });
  }

  static Future<void> deletePayment(int id) async {
    final d = await db;
    await d.transaction((tx) async {
      final rows = await tx.query('payments', where:'id=?', whereArgs:[id], limit:1);
      if (rows.isEmpty) return;
      final pay = rows.first;
      final pid = (pay['property_id'] as num?)?.toInt() ?? 0;
      final dueId = (pay['utility_due_id'] as num?)?.toInt();
      if (dueId != null) await tx.update('utility_dues', {'paid_amount':0}, where:'id=?', whereArgs:[dueId]);
      if ((pay['payment_type'] ?? 'rent') == 'rent') {
        final newer = Sqflite.firstIntValue(await tx.rawQuery("SELECT COUNT(*) FROM payments WHERE property_id=? AND payment_type='rent' AND id>?", [pid,id])) ?? 0;
        if (newer == 0) await tx.update('properties', {'due_date':pay['due_date'] ?? ''}, where:'id=?', whereArgs:[pid]);
      }
      await tx.delete('payments', where:'id=?', whereArgs:[id]);
    });
  }

  static Future<List<Map<String,dynamic>>> utilityDues(int propertyId) async =>
      (await db).query('utility_dues', where:'property_id=? AND amount>paid_amount', whereArgs:[propertyId], orderBy:'id DESC');
  static Future<int> addUtilityDue(int propertyId, String kind, String note, double amount) async =>
      (await db).insert('utility_dues', {'property_id':propertyId,'kind':kind,'note':note,'amount':amount,'paid_amount':0,'created_at':_isoFmt.format(DateTime.now())});

  static Future<Map<String,dynamic>?> login(String username, String password) async {
    final rows = await (await db).query('users', where:'username=? AND password=?', whereArgs:[username,password], limit:1);
    return rows.isEmpty ? null : rows.first;
  }
  static Future<Map<String,dynamic>?> primaryUser() async {
    final rows = await (await db).query('users', where:'is_primary=1', limit:1);
    return rows.isEmpty ? null : rows.first;
  }
  static Future<void> updateUser(int id, String username, String fullName, {String? password}) async {
    final data=<String,dynamic>{'username':username,'full_name':fullName};
    if (password != null && password.isNotEmpty) data['password']=password;
    await (await db).update('users', data, where:'id=?', whereArgs:[id]);
  }
}

Map<String,dynamic>? currentUser;

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _logged = false;
  @override
  Widget build(BuildContext context) => _logged
      ? HomeScreen(onLogout: () => setState(() { currentUser = null; _logged = false; }))
      : LoginScreen(onLogin: (u) => setState(() { currentUser = u; _logged = true; }));
}

class LoginScreen extends StatefulWidget {
  final ValueChanged<Map<String,dynamic>> onLogin;
  const LoginScreen({super.key, required this.onLogin});
  @override State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false, _hide = true;
  String? _error;
  @override void dispose(){_user.dispose();_pass.dispose();super.dispose();}
  Future<void> _login() async {
    setState(() {_busy=true;_error=null;});
    final u = await DB.login(_user.text.trim(), _pass.text);
    if (!mounted) return;
    setState(() => _busy=false);
    if (u == null) { setState(() => _error='اسم المستخدم أو كلمة المرور غير صحيحة'); return; }
    widget.onLogin(u);
  }
  Future<void> _bio() async {
    try {
      final auth = LocalAuthentication();
      final ok = await auth.authenticate(localizedReason:'تسجيل الدخول إلى إدارة العقارات', options: const AuthenticationOptions(biometricOnly:true, stickyAuth:true));
      if (!ok) return;
      final u = await DB.primaryUser();
      if (u != null && mounted) widget.onLogin(u);
    } catch (_) { if (mounted) setState(() => _error='البصمة غير متاحة أو غير مفعلة على الجهاز'); }
  }
  @override Widget build(BuildContext context) => Scaffold(
    body: SafeArea(child: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth:420), child: AppCard(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize:MainAxisSize.min, children:[
        const CircleAvatar(radius:34, child: Icon(Icons.apartment, size:36)),
        const SizedBox(height:16),
        const Text('تسجيل الدخول', style: TextStyle(fontSize:24,fontWeight:FontWeight.w800)),
        const SizedBox(height:6),
        const Text('الحساب الافتراضي الرئيسي: admin / admin123\nالحساب البديل: backup / backup123', textAlign:TextAlign.center, style:TextStyle(fontSize:12,color:Colors.black54)),
        const SizedBox(height:20),
        TextField(controller:_user, decoration:const InputDecoration(labelText:'اسم المستخدم',prefixIcon:Icon(Icons.person_outline))),
        const SizedBox(height:12),
        TextField(controller:_pass, obscureText:_hide, onSubmitted:(_)=>_login(), decoration:InputDecoration(labelText:'كلمة المرور',prefixIcon:const Icon(Icons.lock_outline),suffixIcon:IconButton(onPressed:()=>setState(()=>_hide=!_hide),icon:Icon(_hide?Icons.visibility:Icons.visibility_off)))),
        if (_error != null) Padding(padding:const EdgeInsets.only(top:10), child:Text(_error!,style:const TextStyle(color:Colors.red))),
        const SizedBox(height:16),
        SizedBox(width:double.infinity,height:48,child:FilledButton(onPressed:_busy?null:_login,child:_busy?const SizedBox(width:22,height:22,child:CircularProgressIndicator(strokeWidth:2)):const Text('دخول'))),
        const SizedBox(height:8),
        SizedBox(width:double.infinity,child:OutlinedButton.icon(onPressed:_bio,icon:const Icon(Icons.fingerprint),label:const Text('الدخول بالبصمة'))),
      ]))))))),
  );
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override State<SettingsScreen> createState()=>_SettingsScreenState();
}
class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _username,_name,_password;
  bool _saving=false;
  @override void initState(){super.initState();final u=currentUser??{};_username=TextEditingController(text:'${u['username']??''}');_name=TextEditingController(text:'${u['full_name']??''}');_password=TextEditingController();}
  @override void dispose(){_username.dispose();_name.dispose();_password.dispose();super.dispose();}
  Future<void> _save() async { if(_username.text.trim().isEmpty)return; setState(()=>_saving=true); try {await DB.updateUser(currentUser!['id'] as int,_username.text.trim(),_name.text.trim(),password:_password.text); currentUser={...currentUser!,'username':_username.text.trim(),'full_name':_name.text.trim()}; if(mounted) Navigator.pop(context,true);} catch(e){if(mounted){setState(()=>_saving=false);ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('تعذر الحفظ. قد يكون اسم المستخدم مستخدماً بالفعل.')));}}}
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:const Text('إعدادات التطبيق')),body:ListView(padding:const EdgeInsets.all(16),children:[
    TextField(controller:_name,decoration:const InputDecoration(labelText:'الاسم الشخصي',prefixIcon:Icon(Icons.badge_outlined))),const SizedBox(height:12),
    TextField(controller:_username,decoration:const InputDecoration(labelText:'اسم المستخدم',prefixIcon:Icon(Icons.person_outline))),const SizedBox(height:12),
    TextField(controller:_password,obscureText:true,decoration:const InputDecoration(labelText:'كلمة مرور جديدة (اتركها فارغة لعدم التغيير)',prefixIcon:Icon(Icons.lock_outline))),const SizedBox(height:20),
    SizedBox(height:50,child:FilledButton.icon(onPressed:_saving?null:_save,icon:const Icon(Icons.save),label:const Text('حفظ التعديلات')))
  ]));
}

// ---------------------------------------------------------
// Home
// ---------------------------------------------------------
class HomeScreen extends StatefulWidget {
  final VoidCallback? onLogout;
  const HomeScreen({super.key, this.onLogout});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  bool _loading = true;
  List<Map<String, dynamic>> _items = [];
  List<Map<String, dynamic>> _payments = [];
  bool _alertShown = false;
  String _query = '';
  String? _filter;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await DB.all();
    final pays = await DB.allPayments();
    if (!mounted) return;
    setState(() {
      _items = data;
      _payments = pays;
      _loading = false;
    });
    if (!_alertShown && _alerts.isNotEmpty) {
      _alertShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showAlertDialog();
      });
    }
  }

  /// العقارات المتأخرة أو القريبة من موعد السداد (الأكثر تأخراً أولاً).
  List<Map<String, dynamic>> get _alerts {
    final l = _items.where((i) {
      if (i['status'] == 'شاغر') return false;
      final d = daysToDue(i);
      return d != null && d <= kReminderDays;
    }).toList();
    l.sort((a, b) => daysToDue(a)!.compareTo(daysToDue(b)!));
    return l;
  }

  void _showAlertDialog() {
    final a = _alerts;
    final late = a.where((i) => daysToDue(i)! < 0).length;
    final soon = a.length - late;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: Icon(Icons.notifications_active,
            color: late > 0 ? const Color(0xFFC62828) : const Color(0xFFEF6C00),
            size: 36),
        title: const Text('تنبيهات الإيجارات'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (late > 0)
                Text('متأخرون عن السداد: $late',
                    style: const TextStyle(
                        color: Color(0xFFC62828), fontWeight: FontWeight.w800)),
              if (soon > 0)
                Text('يقترب موعد سدادهم: $soon',
                    style: const TextStyle(
                        color: Color(0xFFEF6C00), fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              for (final i in a.take(6))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(
                      '• ${i['tenant_name'] ?? ''} - ${i['name'] ?? ''}: ${dueText(i)}'),
                ),
              if (a.length > 6) Text('... و${a.length - 6} آخرين'),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              setState(() => _tab = 1);
            },
            child: const Text('عرض التنبيهات'),
          ),
        ],
      ),
    );
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
      ));
  }

  Future<void> _openForm([Map<String, dynamic>? item]) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => PropertyFormScreen(property: item)),
    );
    if (saved == true) {
      await _load();
      _toast(item == null ? 'تمت إضافة العقار' : 'تم تحديث العقار');
    }
  }

  Future<void> _delete(Map<String, dynamic> item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف العقار'),
        content: Text('هل تريد حذف "${item['name']}" نهائياً؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              child: const Text('حذف')),
        ],
      ),
    );
    if (ok == true) {
      await DB.delete(item['id'] as int);
      await _load();
      _toast('تم حذف العقار');
    }
  }

  Future<void> _whatsapp(Map<String, dynamic> item, String type,
      {String? receipt, double? amount}) async {
    final phone = (item['tenant_phone'] ?? '').toString();
    var clean = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (clean.isEmpty) {
      _toast('رقم الهاتف غير مسجل');
      return;
    }
    // رقم مصري محلي (01xxxxxxxxx) -> أضف رمز الدولة
    if (clean.startsWith('01') && clean.length == 11) clean = '2$clean';
    final total = _total(item);
    final t = item['tenant_name'];
    final n = item['name'];
    final a = fmt(amount ?? total);
    final due = parseDue(item);
    final dueTxt = due == null ? '' : ' بتاريخ ${_dateFmt.format(due)}';
    final days = daysToDue(item);
    String msg;
    if (type == 'reminder') {
      msg = 'أهلاً $t، نود تذكيرك بقرب موعد سداد إيجار $n$dueTxt وقيمته الإجمالية $a (شامل المرافق).';
    } else if (type == 'late') {
      final lateTxt = (days != null && days < 0) ? ' (متأخر ${-days} يوم)' : '';
      msg = 'عزيزي $t، نود إحاطتكم بتأخر سداد مستحقات $n$dueTxt$lateTxt وقيمتها $a. نرجو السداد في أقرب وقت.';
    } else {
      final r = receipt == null ? '' : ' (إيصال رقم $receipt)';
      msg = 'شكراً لك $t، تم استلام مبلغ $a الخاص بإيجار ومرافق $n بنجاح$r. نشكر لك التزامك.';
    }
    final url = Uri.parse('https://wa.me/$clean?text=${Uri.encodeComponent(msg)}');
    try {
      final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
      if (!ok) _toast('تعذر فتح WhatsApp');
    } catch (_) {
      _toast('تعذر فتح WhatsApp');
    }
  }

  // ---------------- سداد الإيجار ----------------
  Future<void> _pay(Map<String, dynamic> item) async {
    final amountC = TextEditingController(text: plain(_total(item)));
    final noteC = TextEditingController();
    var paidAt = DateTime.now();
    final due = parseDue(item);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('سداد الإيجار'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${item['name'] ?? ''} • ${item['tenant_name'] ?? ''}',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                if (due != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('تاريخ الاستحقاق: ${dueText(item)}'),
                  ),
                const SizedBox(height: 14),
                TextField(
                  controller: amountC,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
                  ],
                  decoration: const InputDecoration(
                      labelText: 'المبلغ المسدد',
                      prefixIcon: Icon(Icons.payments_outlined)),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () async {
                    final d = await showDatePicker(
                      context: ctx,
                      initialDate: paidAt,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100),
                    );
                    if (d != null) setD(() => paidAt = d);
                  },
                  icon: const Icon(Icons.event_outlined, size: 18),
                  label: Text('تاريخ السداد: ${_dateFmt.format(paidAt)}'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: noteC,
                  decoration: const InputDecoration(
                      labelText: 'ملاحظات (اختياري)',
                      prefixIcon: Icon(Icons.notes)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('إلغاء')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('تأكيد السداد')),
          ],
        ),
      ),
    );
    if (ok != true) return;

    final amount = double.tryParse(amountC.text.trim()) ?? 0;
    if (amount <= 0) {
      _toast('أدخل مبلغاً صحيحاً');
      return;
    }
    // الاستحقاق التالي = بعد شهر من الاستحقاق الحالي (أو من تاريخ السداد إن لم يوجد)
    final newDue = addMonths(due ?? paidAt, 1);
    final pay = <String, dynamic>{
      'property_id': item['id'],
      'property_name': item['name'],
      'tenant_name': item['tenant_name'],
      'tenant_phone': item['tenant_phone'],
      'rent_amount': num0(item['rent_amount']),
      'electricity': num0(item['electricity']),
      'water': num0(item['water']),
      'gas': num0(item['gas']),
      'amount': amount,
      'paid_at': _isoFmt.format(paidAt),
      'due_date': due == null ? '' : _isoFmt.format(due),
      'note': noteC.text.trim(),
    };
    final result = await DB.recordPayment(
        item['id'] as int, pay, _isoFmt.format(newDue));
    pay['id'] = result['id'];
    pay['receipt_serial'] = result['receipt_serial'];
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('تم تسجيل السداد - إيصال رقم ${receiptNo(pay)}'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
            label: 'طباعة الإيصال', onPressed: () => _printReceipt(pay)),
      ));
    // رسالة الشكر عبر واتساب (تفتح جاهزة وتحتاج ضغطة إرسال)
    await _whatsapp(item, 'thanks', receipt: receiptNo(pay), amount: amount);
  }

  double _total(Map<String, dynamic> i) =>
      num0(i['rent_amount']) +
      num0(i['electricity']) +
      num0(i['water']) +
      num0(i['gas']);

  List<Map<String, dynamic>> get _filtered {
    return _items.where((i) {
      if (_filter != null && effStatus(i) != _filter) return false;
      if (_query.isEmpty) return true;
      final q = _query.toLowerCase();
      return '${i['name']} ${i['tenant_name']} ${i['address']}'
          .toLowerCase()
          .contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final titles = ['العقارات', 'التنبيهات', 'تقارير مالية مجمعة'];
    final alertCount = _loading ? 0 : _alerts.length;
    return Scaffold(
      appBar: AppBar(
        title: Text(titles[_tab], style: const TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(tooltip:'الإعدادات', icon:const Icon(Icons.settings_outlined), onPressed:() async { await Navigator.push(context, MaterialPageRoute(builder:(_)=>const SettingsScreen())); if(mounted)setState((){}); }),
          IconButton(tooltip:'تسجيل الخروج', icon:const Icon(Icons.logout), onPressed:widget.onLogout),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_tab == 0
              ? _propertiesTab()
              : (_tab == 1 ? _alertsTab() : _reportsTab())),
      floatingActionButton: _tab == 0
          ? FloatingActionButton.extended(
              onPressed: () => _openForm(),
              icon: const Icon(Icons.add),
              label: const Text('إضافة عقار'),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: [
          const NavigationDestination(
              icon: Icon(Icons.home_work_outlined),
              selectedIcon: Icon(Icons.home_work),
              label: 'العقارات'),
          NavigationDestination(
              icon: Badge(
                isLabelVisible: alertCount > 0,
                label: Text('$alertCount'),
                child: const Icon(Icons.notifications_outlined),
              ),
              selectedIcon: Badge(
                isLabelVisible: alertCount > 0,
                label: Text('$alertCount'),
                child: const Icon(Icons.notifications),
              ),
              label: 'التنبيهات'),
          const NavigationDestination(
              icon: Icon(Icons.insights_outlined),
              selectedIcon: Icon(Icons.insights),
              label: 'التقارير'),
        ],
      ),
    );
  }

  // ---------------- Properties tab ----------------
  Widget _propertiesTab() {
    final list = _filtered;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            onChanged: (v) => setState(() => _query = v.trim()),
            decoration: const InputDecoration(
              hintText: 'ابحث بالعقار أو المستأجر أو العنوان',
              prefixIcon: Icon(Icons.search),
              contentPadding: EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        SizedBox(
          height: 42,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: ChoiceChip(
                  label: const Text('الكل'),
                  selected: _filter == null,
                  onSelected: (_) => setState(() => _filter = null),
                ),
              ),
              for (final s in kStatuses)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: ChoiceChip(
                    label: Text(s),
                    selected: _filter == s,
                    onSelected: (_) => setState(() => _filter = s),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: list.isEmpty
              ? _emptyState()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (_, i) => _propertyCard(list[i]),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _emptyState() {
    final has = _items.isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(has ? Icons.search_off : Icons.apartment,
                size: 72, color: Colors.black26),
            const SizedBox(height: 12),
            Text(
              has
                  ? 'لا توجد نتائج مطابقة'
                  : 'لا توجد عقارات بعد\nاضغط "إضافة عقار" للبدء',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _propertyCard(Map<String, dynamic> item) {
    final st = effStatus(item);
    final color = statusColor(st);
    final total = _total(item);
    return AppCard(
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          leading: CircleAvatar(
            backgroundColor: color.withAlpha(30),
            child: Icon(Icons.apartment, color: color),
          ),
          title: Text('${item['name'] ?? ''}',
              style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                _statusChip(st, color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('${item['tenant_name'] ?? ''}',
                      overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
          trailing: Text(fmt(total),
              style: TextStyle(fontWeight: FontWeight.w800, color: color)),
          children: [
            _info(Icons.numbers, 'ID العقار', '${item['id']}'),
            _info(Icons.place_outlined, 'العنوان', '${item['address'] ?? ''}'),
            _info(Icons.location_on_outlined, 'الموقع', '${item['location'] ?? ''}'),
            _info(Icons.phone_outlined, 'الهاتف', '${item['tenant_phone'] ?? ''}'),
            if ((item['tenant_alt_phone'] ?? '').toString().isNotEmpty) _info(Icons.phone_in_talk_outlined, 'هاتف بديل', '${item['tenant_alt_phone']}'),
            _info(Icons.event_outlined, 'تاريخ الاستحقاق', dueText(item)),
            _info(Icons.savings_outlined, 'التأمين',
                fmt(num0(item['deposit_amount']))),
            const Divider(height: 24),
            _info(Icons.payments_outlined, 'الإيجار',
                fmt(num0(item['rent_amount']))),
            _info(Icons.bolt_outlined, 'كهرباء', fmt(num0(item['electricity']))),
            _info(Icons.water_drop_outlined, 'مياه', fmt(num0(item['water']))),
            _info(Icons.local_fire_department_outlined, 'غاز',
                fmt(num0(item['gas']))),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: color.withAlpha(20),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('إجمالي المستحق',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  Text(fmt(total),
                      style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: color)),
                ],
              ),
            ),
            _images(item),
            const SizedBox(height: 12),
            if (item['status'] != 'شاغر')
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () => _pay(item),
                    icon: const Icon(Icons.price_check),
                    label: const Text('سداد الإيجار'),
                    style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF1B5E85)),
                  ),
                ),
              ),
            Row(children:[
              Expanded(child:OutlinedButton.icon(onPressed:() async {await Navigator.push(context,MaterialPageRoute(builder:(_)=>UtilitiesScreen(property:item)));await _load();},icon:const Icon(Icons.receipt_long_outlined),label:const Text('المرافق'))),
              const SizedBox(width:8),
              Expanded(child:OutlinedButton.icon(onPressed:()=>Navigator.push(context,MaterialPageRoute(builder:(_)=>PropertyAccountScreen(property:item))),icon:const Icon(Icons.account_balance_wallet_outlined),label:const Text('الحساب الخاص'))),
            ]),
            const SizedBox(height:8),
            Row(
              children: [
                Expanded(
                  child: _waButton('تذكير', Icons.notifications_active,
                      const Color(0xFFF9A825), () => _whatsapp(item, 'reminder')),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _waButton('تأخير', Icons.warning_amber_rounded,
                      const Color(0xFFC62828), () => _whatsapp(item, 'late')),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _waButton('شكر', Icons.favorite,
                      const Color(0xFF2E7D32), () => _whatsapp(item, 'thanks')),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _openForm(item),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('تعديل'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _delete(item),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('حذف'),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: const BorderSide(color: Colors.red)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusChip(String? s, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
            color: c.withAlpha(30), borderRadius: BorderRadius.circular(8)),
        child: Text(s ?? '',
            style: TextStyle(
                color: c, fontSize: 12, fontWeight: FontWeight.w700)),
      );

  Widget _info(IconData icon, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(icon, size: 18, color: Colors.black45),
            const SizedBox(width: 8),
            Text('$label: ', style: const TextStyle(color: Colors.black54)),
            Expanded(
              child: Text(value,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );

  Widget _waButton(String label, IconData icon, Color c, VoidCallback onTap) =>
      FilledButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label),
        style: FilledButton.styleFrom(
          backgroundColor: c,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
      );

  List<String> _pathsOf(Map<String,dynamic> item,String key,String legacy) {
    try { final x=jsonDecode((item[key]??'[]').toString()); if(x is List)return x.map((e)=>e.toString()).where((e)=>e.isNotEmpty).toList(); } catch(_) {}
    final old=(item[legacy]??'').toString(); return old.isEmpty?[]:[old];
  }

  Widget _images(Map<String, dynamic> item) {
    final groups=<MapEntry<String,List<String>>>[
      MapEntry('بطاقة المستأجر',_pathsOf(item,'id_card_paths','id_card_path')),
      MapEntry('العقد',_pathsOf(item,'contract_paths','contract_path')),
    ].where((e)=>e.value.isNotEmpty).toList();
    if(groups.isEmpty)return const SizedBox.shrink();
    return Padding(padding:const EdgeInsets.only(top:12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      for(final g in groups)...[
        Text('${g.key}: ${g.value.length} صورة',style:const TextStyle(fontSize:12,fontWeight:FontWeight.w700)),
        const SizedBox(height:6),
        SizedBox(height:74,child:ListView.separated(scrollDirection:Axis.horizontal,itemCount:g.value.length,separatorBuilder:(_,__)=>const SizedBox(width:8),itemBuilder:(_,i){final path=g.value[i];return GestureDetector(onTap:()=>showDialog(context:context,builder:(_)=>Dialog(child:InteractiveViewer(child:Image.file(File(path))))),child:ClipRRect(borderRadius:BorderRadius.circular(10),child:File(path).existsSync()?Image.file(File(path),width:74,height:74,fit:BoxFit.cover):Container(width:74,height:74,color:Colors.black12,child:const Icon(Icons.broken_image))));})),
        const SizedBox(height:8),
      ]
    ]));
  }

  // ---------------- Alerts tab ----------------
  Widget _alertsTab() {
    final a = _alerts;
    if (a.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle_outline, size: 72, color: Colors.black26),
              SizedBox(height: 12),
              Text(
                'لا توجد تنبيهات حالياً\nلا متأخرات ولا مواعيد سداد قريبة',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.black54),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: a.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, i) => _alertCard(a[i]),
    );
  }

  Widget _alertCard(Map<String, dynamic> item) {
    final days = daysToDue(item)!;
    final late = days < 0;
    final c = late ? const Color(0xFFC62828) : const Color(0xFFEF6C00);
    final due = parseDue(item)!;
    final title = late
        ? '${item['tenant_name'] ?? 'المستأجر'} مؤجّر "${item['name'] ?? ''}" ولم يسدد'
        : 'يقترب موعد سداد "${item['name'] ?? ''}"';
    final sub = (late
            ? 'متأخر ${-days} يوم'
            : (days == 0 ? 'يستحق اليوم' : 'يستحق بعد $days يوم')) +
        ' • الاستحقاق ${_dateFmt.format(due)}';
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: c.withAlpha(30),
                  child: Icon(
                      late ? Icons.warning_amber_rounded : Icons.schedule,
                      color: c),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      Text(sub, style: TextStyle(color: c, fontSize: 12)),
                    ],
                  ),
                ),
                Text(fmt(_total(item)),
                    style: TextStyle(fontWeight: FontWeight.w800, color: c)),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _waButton(
                      late ? 'تنبيه تأخير' : 'تذكير',
                      late ? Icons.warning_amber_rounded : Icons.notifications_active,
                      c,
                      () => _whatsapp(item, late ? 'late' : 'reminder')),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _waButton('سداد', Icons.price_check,
                      const Color(0xFF1B5E85), () => _pay(item)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editPayment(Map<String,dynamic> pay) async {
    final amountC=TextEditingController(text:plain(num0(pay['amount'])));
    final noteC=TextEditingController(text:(pay['note']??'').toString());
    var date=DateTime.tryParse((pay['paid_at']??'').toString())??DateTime.now();
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,setD)=>AlertDialog(title:Text('تعديل الإيصال ${receiptNo(pay)}'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
      TextField(controller:amountC,keyboardType:const TextInputType.numberWithOptions(decimal:true),inputFormatters:[FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],decoration:const InputDecoration(labelText:'المبلغ')),
      const SizedBox(height:10),OutlinedButton.icon(onPressed:() async {final d=await showDatePicker(context:ctx,initialDate:date,firstDate:DateTime(2020),lastDate:DateTime(2100));if(d!=null)setD(()=>date=d);},icon:const Icon(Icons.event),label:Text(_dateFmt.format(date))),
      const SizedBox(height:10),TextField(controller:noteC,decoration:const InputDecoration(labelText:'ملاحظات')),
    ])),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('حفظ'))])));
    if(ok==true){final a=double.tryParse(amountC.text)??0;if(a<=0){_toast('أدخل مبلغاً صحيحاً');return;}await DB.updatePayment(pay['id'] as int,a,noteC.text.trim(),_isoFmt.format(date));await _load();_toast('تم تعديل عملية السداد وتحديث الرصيد');}
  }

  Future<void> _deletePayment(Map<String,dynamic> pay) async {
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>AlertDialog(title:const Text('حذف عملية السداد'),content:Text('حذف الإيصال ${receiptNo(pay)}؟ سيتم تحديث الرصيد المرتبط به.'),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),style:FilledButton.styleFrom(backgroundColor:Colors.red),child:const Text('حذف'))]));
    if(ok==true){await DB.deletePayment(pay['id'] as int);await _load();_toast('تم حذف عملية السداد وتحديث الرصيد');}
  }

  Future<void> _printAllPropertiesReport() async {
    try{
      final reg=pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans.ttf'));
      final bold=pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans-Bold.ttf'));
      final doc=pw.Document(theme:pw.ThemeData.withFont(base:reg,bold:bold));
      final totalIncome=_payments.fold<double>(0,(a,b)=>a+num0(b['amount']));
      doc.addPage(pw.MultiPage(pageFormat:PdfPageFormat.a4,textDirection:pw.TextDirection.rtl,margin:const pw.EdgeInsets.all(28),build:(_)=>[
        pw.Text('التقرير المالي المجمع لجميع العقارات',style:pw.TextStyle(fontSize:20,fontWeight:pw.FontWeight.bold)),pw.SizedBox(height:6),pw.Text('إجمالي الإيرادات المسجلة: ${fmt(totalIncome)}'),pw.SizedBox(height:14),
        pw.TableHelper.fromTextArray(headers:['العقار','ID','المستأجر','عدد الدفعات','الإيرادات'],data:_items.map((pr){final ps=_payments.where((x)=>x['property_id']==pr['id']).toList();final sum=ps.fold<double>(0,(a,b)=>a+num0(b['amount']));return ['${pr['name']??''}','${pr['id']}','${pr['tenant_name']??''}','${ps.length}',fmt(sum)];}).toList()),
        pw.SizedBox(height:18),pw.Text('تفاصيل العمليات',style:pw.TextStyle(fontSize:16,fontWeight:pw.FontWeight.bold)),pw.SizedBox(height:8),
        pw.TableHelper.fromTextArray(headers:['السيريال','العقار','النوع','التاريخ','القيمة'],data:_payments.map((x)=>[receiptNo(x),'${x['property_name']??''}',(x['payment_type']??'rent')=='rent'?'إيجار':'مرافق/خدمات',_payDate(x),fmt(num0(x['amount']))]).toList()),
      ]));
      await Printing.layoutPdf(name:'all-properties-financial-report.pdf',onLayout:(_)=>doc.save());
    }catch(e){_toast('تعذر إنشاء التقرير المجمع');}
  }

  // ---------------- Reports tab ----------------
  Widget _reportsTab() {
    double rent = 0, utils = 0, deposit = 0, due = 0;
    int rented = 0, vacant = 0, late = 0;
    for (final i in _items) {
      rent += num0(i['rent_amount']);
      utils += num0(i['electricity']) + num0(i['water']) + num0(i['gas']);
      deposit += num0(i['deposit_amount']);
      if (effStatus(i) == 'متأخرات') {
        due += _total(i);
        late++;
      } else if (effStatus(i) == 'شاغر') {
        vacant++;
      } else {
        rented++;
      }
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        AppCard(
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: const LinearGradient(
                colors: [Color(0xFF1B5E85), Color(0xFF2A8AB8)],
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('إجمالي الإيجارات الشهرية',
                    style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 6),
                Text(fmt(rent),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Text('${_items.length} عقار  •  مؤجر $rented  •  شاغر $vacant  •  متأخرات $late',
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          _stat('المرافق', fmt(utils), Icons.bolt, const Color(0xFFEF6C00)),
          const SizedBox(width: 12),
          _stat('التأمينات', fmt(deposit), Icons.savings, const Color(0xFF00897B)),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          _stat('متأخرات مستحقة', fmt(due), Icons.warning_amber_rounded,
              const Color(0xFFC62828)),
          const SizedBox(width: 12),
          _stat('عقارات شاغرة', '$vacant', Icons.key, const Color(0xFF6A1B9A)),
        ]),
        const SizedBox(height: 20),
        SizedBox(width:double.infinity,child:FilledButton.icon(onPressed:_printAllPropertiesReport,icon:const Icon(Icons.picture_as_pdf),label:const Text('استخراج تقرير PDF شامل لكل العقارات'))),
        const SizedBox(height: 24),
        const Text('إيصالات السداد',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        if (_payments.isEmpty)
          const Text('لا توجد مدفوعات مسجلة بعد. استخدم زر "سداد الإيجار" في بطاقة العقار.',
              style: TextStyle(color: Colors.black54))
        else
          for (final pay in _payments.take(50))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: AppCard(
                child: ListTile(
                  title: Text('${receiptNo(pay)} • ${pay['property_name'] ?? ''}',
                      style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text(
                      '${pay['tenant_name'] ?? ''} • ${fmt(num0(pay['amount']))} • ${_payDate(pay)}'),
                  trailing: PopupMenuButton<String>(onSelected:(v){if(v=='pdf')_printReceipt(pay);if(v=='edit')_editPayment(pay);if(v=='delete')_deletePayment(pay);},itemBuilder:(_)=>const [
                    PopupMenuItem(value:'pdf',child:ListTile(leading:Icon(Icons.picture_as_pdf),title:Text('PDF'))),
                    PopupMenuItem(value:'edit',child:ListTile(leading:Icon(Icons.edit_outlined),title:Text('تعديل'))),
                    PopupMenuItem(value:'delete',child:ListTile(leading:Icon(Icons.delete_outline,color:Colors.red),title:Text('حذف',style:TextStyle(color:Colors.red))))
                  ]),
                ),
              ),
            ),
      ],
    );
  }

  Widget _stat(String title, String value, IconData icon, Color c) => Expanded(
        child: AppCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                    radius: 18,
                    backgroundColor: c.withAlpha(30),
                    child: Icon(icon, color: c, size: 20)),
                const SizedBox(height: 10),
                Text(title,
                    style: const TextStyle(fontSize: 12, color: Colors.black54)),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(value,
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: c)),
                ),
              ],
            ),
          ),
        ),
      );

  // ---------------- PDF receipt ----------------
  String _payDate(Map<String, dynamic> pay) {
    final d = DateTime.tryParse((pay['paid_at'] ?? '').toString());
    return d == null ? '' : _dateFmt.format(d);
  }

  Future<void> _printReceipt(Map<String, dynamic> pay) async {
    try {
      final reg = pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans.ttf'));
      final bold =
          pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans-Bold.ttf'));
      final doc = pw.Document(theme: pw.ThemeData.withFont(base: reg, bold: bold));
      final rent = num0(pay['rent_amount']);
      final elec = num0(pay['electricity']);
      final water = num0(pay['water']);
      final gas = num0(pay['gas']);
      final isUtility = (pay['payment_type'] ?? 'rent') != 'rent';
      final total = isUtility ? num0(pay['amount']) : rent + elec + water + gas;
      final paid = num0(pay['amount']);
      final no = receiptNo(pay);
      final dueD = DateTime.tryParse((pay['due_date'] ?? '').toString());
      final note = (pay['note'] ?? '').toString();

      pw.Widget row(String a, String b, {bool strong = false}) => pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 6),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                pw.Text(a,
                    style: pw.TextStyle(
                        fontWeight: strong ? pw.FontWeight.bold : null)),
                pw.Text(b,
                    style: pw.TextStyle(
                        fontWeight: strong ? pw.FontWeight.bold : null)),
              ],
            ),
          );

      doc.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a5,
          margin: const pw.EdgeInsets.all(24),
          textDirection: pw.TextDirection.rtl,
          build: (_) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.Center(
                child: pw.Text(isUtility ? 'إيصال سداد مرافق / خدمات' : 'إيصال استلام إيجار ومرافق',
                    style: pw.TextStyle(
                        fontSize: 18, fontWeight: pw.FontWeight.bold)),
              ),
              pw.SizedBox(height: 4),
              pw.Center(
                  child: pw.Text('رقم الإيصال: $no',
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold))),
              pw.SizedBox(height: 2),
              pw.Center(child: pw.Text('تاريخ السداد: ${_payDate(pay)}')),
              pw.Divider(),
              pw.SizedBox(height: 8),
              pw.Text('العقار: ${pay['property_name'] ?? ''}'),
              pw.SizedBox(height: 4),
              pw.Text('المستأجر: ${pay['tenant_name'] ?? ''}'),
              pw.SizedBox(height: 4),
              pw.Text('الهاتف: ${pay['tenant_phone'] ?? ''}'),
              if (dueD != null) ...[
                pw.SizedBox(height: 4),
                pw.Text('عن استحقاق: ${_dateFmt.format(dueD)}'),
              ],
              pw.SizedBox(height: 14),
              pw.Container(
                padding: const pw.EdgeInsets.all(10),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey500),
                  borderRadius: pw.BorderRadius.circular(8),
                ),
                child: pw.Column(children: [
                  row('الإيجار الشهري', fmt(rent)),
                  row('كهرباء', fmt(elec)),
                  row('مياه', fmt(water)),
                  row('غاز', fmt(gas)),
                  pw.Divider(),
                  row('الإجمالي المستحق', fmt(total)),
                  row('المبلغ المسدد', fmt(paid), strong: true),
                ]),
              ),
              if (note.isNotEmpty) ...[
                pw.SizedBox(height: 8),
                pw.Text('ملاحظات: $note'),
              ],
              pw.Spacer(),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text('توقيع المستلم: ..................'),
                  pw.Text('ختم: ..................'),
                ],
              ),
            ],
          ),
        ),
      );

      await Printing.layoutPdf(
        name: '$no.pdf',
        onLayout: (PdfPageFormat f) async => doc.save(),
      );
    } catch (e) {
      _toast('تعذر إنشاء الإيصال');
    }
  }
}

class UtilitiesScreen extends StatefulWidget {
  final Map<String,dynamic> property;
  const UtilitiesScreen({super.key,required this.property});
  @override State<UtilitiesScreen> createState()=>_UtilitiesScreenState();
}
class _UtilitiesScreenState extends State<UtilitiesScreen>{
  List<Map<String,dynamic>> _dues=[]; bool _loading=true;
  @override void initState(){super.initState();_load();}
  Future<void> _load() async {final x=await DB.utilityDues(widget.property['id'] as int);if(mounted)setState((){_dues=x;_loading=false;});}
  void _msg(String m){ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(m)));}
  Future<void> _add() async {
    String kind='كهرباء';final note=TextEditingController(),amount=TextEditingController();
    final ok=await showDialog<bool>(context:context,builder:(ctx)=>StatefulBuilder(builder:(ctx,setD)=>AlertDialog(title:const Text('إضافة مستحق مرافق/خدمة'),content:SingleChildScrollView(child:Column(mainAxisSize:MainAxisSize.min,children:[
      DropdownButtonFormField<String>(value:kind,items:['كهرباء','مياه','غاز','خدمات أخرى'].map((x)=>DropdownMenuItem(value:x,child:Text(x))).toList(),onChanged:(v)=>setD(()=>kind=v??kind),decoration:const InputDecoration(labelText:'البند')),
      const SizedBox(height:10),TextField(controller:note,decoration:InputDecoration(labelText:kind=='خدمات أخرى'?'ملاحظات (مطلوب)':'ملاحظات')),
      const SizedBox(height:10),TextField(controller:amount,keyboardType:const TextInputType.numberWithOptions(decimal:true),inputFormatters:[FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],decoration:const InputDecoration(labelText:'القيمة')),
    ])),actions:[TextButton(onPressed:()=>Navigator.pop(ctx,false),child:const Text('إلغاء')),FilledButton(onPressed:()=>Navigator.pop(ctx,true),child:const Text('إضافة'))])));
    if(ok!=true)return;final a=double.tryParse(amount.text)??0;if(a<=0){_msg('أدخل قيمة صحيحة');return;}if(kind=='خدمات أخرى'&&note.text.trim().isEmpty){_msg('ملاحظات خدمات أخرى مطلوبة');return;}
    await DB.addUtilityDue(widget.property['id'] as int,kind,note.text.trim(),a);await _load();_msg('تمت إضافة المستحق');
  }
  Future<void> _pay(Map<String,dynamic> due) async {
    final remaining=num0(due['amount'])-num0(due['paid_amount']);
    final pay=<String,dynamic>{'property_id':widget.property['id'],'property_name':widget.property['name'],'tenant_name':widget.property['tenant_name'],'tenant_phone':widget.property['tenant_phone'],'rent_amount':0.0,'electricity':due['kind']=='كهرباء'?remaining:0.0,'water':due['kind']=='مياه'?remaining:0.0,'gas':due['kind']=='غاز'?remaining:0.0,'amount':remaining,'paid_at':_isoFmt.format(DateTime.now()),'due_date':'','note':'${due['kind']}: ${due['note']??''}','payment_type':'utility','utility_due_id':due['id']};
    final r=await DB.recordPayment(widget.property['id'] as int,pay,(widget.property['due_date']??'').toString());
    await _load();_msg('تم السداد وتصفير المستحق - إيصال ${r['receipt_serial']}');
  }
  @override Widget build(BuildContext context)=>Scaffold(appBar:AppBar(title:Text('مرافق ${widget.property['name']??''}')),floatingActionButton:FloatingActionButton.extended(onPressed:_add,icon:const Icon(Icons.add),label:const Text('إضافة مستحق')),body:_loading?const Center(child:CircularProgressIndicator()):_dues.isEmpty?const Center(child:Text('لا توجد مستحقات مرافق أو خدمات أخرى حالياً')):ListView.separated(padding:const EdgeInsets.fromLTRB(16,12,16,90),itemCount:_dues.length,separatorBuilder:(_,__)=>const SizedBox(height:10),itemBuilder:(_,i){final d=_dues[i];final remain=num0(d['amount'])-num0(d['paid_amount']);return AppCard(child:ListTile(leading:const CircleAvatar(child:Icon(Icons.receipt_long)),title:Text('${d['kind']} • ${fmt(remain)}',style:const TextStyle(fontWeight:FontWeight.w800)),subtitle:Text((d['note']??'').toString()),trailing:FilledButton(onPressed:()=>_pay(d),child:const Text('سداد'))));}));
}

class PropertyAccountScreen extends StatefulWidget{
  final Map<String,dynamic> property;
  const PropertyAccountScreen({super.key,required this.property});
  @override State<PropertyAccountScreen> createState()=>_PropertyAccountScreenState();
}
class _PropertyAccountScreenState extends State<PropertyAccountScreen>{
  List<Map<String,dynamic>> _pays=[]; bool _loading=true;
  @override void initState(){super.initState();_load();}
  Future<void> _load() async {final p=await DB.paymentsForProperty(widget.property['id'] as int);if(mounted)setState((){_pays=p;_loading=false;});}
  String _date(Map<String,dynamic> x){final d=DateTime.tryParse((x['paid_at']??'').toString());return d==null?'':_dateFmt.format(d);}
  Future<void> _pdf() async {try{
    final reg=pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans.ttf'));final bold=pw.Font.ttf(await rootBundle.load('assets/fonts/DejaVuSans-Bold.ttf'));final doc=pw.Document(theme:pw.ThemeData.withFont(base:reg,bold:bold));final total=_pays.fold<double>(0,(a,b)=>a+num0(b['amount']));
    doc.addPage(pw.MultiPage(pageFormat:PdfPageFormat.a4,textDirection:pw.TextDirection.rtl,margin:const pw.EdgeInsets.all(28),build:(_)=>[
      pw.Text('الحساب الخاص بالعقار',style:pw.TextStyle(fontSize:20,fontWeight:pw.FontWeight.bold)),pw.SizedBox(height:6),pw.Text('العقار: ${widget.property['name']??''}   •   ID: ${widget.property['id']}'),pw.Text('الموقع: ${widget.property['location']??''}'),pw.Text('المستأجر: ${widget.property['tenant_name']??''}'),pw.SizedBox(height:8),pw.Text('إجمالي الإيرادات: ${fmt(total)}',style:pw.TextStyle(fontWeight:pw.FontWeight.bold)),pw.SizedBox(height:14),
      pw.TableHelper.fromTextArray(headers:['السيريال','النوع','التاريخ','القيمة','ملاحظات'],data:_pays.map((x)=>[receiptNo(x),(x['payment_type']??'rent')=='rent'?'إيجار':'مرافق/خدمات',_date(x),fmt(num0(x['amount'])),'${x['note']??''}']).toList())
    ]));await Printing.layoutPdf(name:'property-${widget.property['id']}-account.pdf',onLayout:(_)=>doc.save());
  }catch(_){if(mounted)ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content:Text('تعذر إنشاء PDF')));}}
  @override Widget build(BuildContext context){final total=_pays.fold<double>(0,(a,b)=>a+num0(b['amount']));return Scaffold(appBar:AppBar(title:Text('حساب ${widget.property['name']??''}'),actions:[IconButton(onPressed:_pdf,tooltip:'تصدير PDF',icon:const Icon(Icons.picture_as_pdf))]),body:_loading?const Center(child:CircularProgressIndicator()):ListView(padding:const EdgeInsets.all(16),children:[
    AppCard(child:Padding(padding:const EdgeInsets.all(16),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text('ID العقار: ${widget.property['id']}',style:const TextStyle(fontWeight:FontWeight.w700)),Text('الموقع: ${widget.property['location']??''}'),const SizedBox(height:8),Text('إجمالي الحركة المالية: ${fmt(total)}',style:const TextStyle(fontSize:18,fontWeight:FontWeight.w800))]))),const SizedBox(height:14),
    SizedBox(width:double.infinity,child:FilledButton.icon(onPressed:_pdf,icon:const Icon(Icons.picture_as_pdf),label:const Text('استخراج تقرير PDF لهذا العقار'))),const SizedBox(height:16),
    if(_pays.isEmpty)const Center(child:Text('لا توجد عمليات مالية مسجلة')) else for(final x in _pays)Padding(padding:const EdgeInsets.only(bottom:8),child:AppCard(child:ListTile(title:Text('${receiptNo(x)} • ${fmt(num0(x['amount']))}',style:const TextStyle(fontWeight:FontWeight.w700)),subtitle:Text('${(x['payment_type']??'rent')=='rent'?'إيجار':'مرافق/خدمات'} • ${_date(x)}\n${x['note']??''}'))))
  ]));}
}

// ---------------------------------------------------------
// Add / Edit form (full screen)
// ---------------------------------------------------------
class PropertyFormScreen extends StatefulWidget {
  final Map<String, dynamic>? property;
  const PropertyFormScreen({super.key, this.property});
  @override State<PropertyFormScreen> createState() => _PropertyFormScreenState();
}

class _PropertyFormScreenState extends State<PropertyFormScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name, _address, _location, _tenant, _phone, _altPhone;
  late final TextEditingController _rent, _deposit, _elec, _water, _gas;
  late String _status;
  List<String> _idPaths = [], _contractPaths = [];
  DateTime? _due;
  bool _saving = false;
  bool get _isEdit => widget.property != null;

  List<String> _decodePaths(dynamic raw, dynamic legacy) {
    try {
      final x = jsonDecode((raw ?? '[]').toString());
      if (x is List) return x.map((e)=>e.toString()).where((e)=>e.isNotEmpty).toList();
    } catch (_) {}
    final old=(legacy??'').toString();
    return old.isEmpty?[]:[old];
  }

  @override void initState() {
    super.initState();
    final x=widget.property;
    String s(String k)=>(x?[k]??'').toString();
    String n(String k)=>x==null?'':plain(num0(x[k]));
    _name=TextEditingController(text:s('name'));
    _address=TextEditingController(text:s('address'));
    _location=TextEditingController(text:s('location'));
    _tenant=TextEditingController(text:s('tenant_name'));
    _phone=TextEditingController(text:s('tenant_phone'));
    _altPhone=TextEditingController(text:s('tenant_alt_phone'));
    _rent=TextEditingController(text:n('rent_amount'));
    _deposit=TextEditingController(text:n('deposit_amount'));
    _elec=TextEditingController(text:n('electricity'));
    _water=TextEditingController(text:n('water'));
    _gas=TextEditingController(text:n('gas'));
    _status=kStatuses.contains(x?['status'])?x!['status']:'مؤجر';
    _due=x==null?null:parseDue(x);
    _idPaths=_decodePaths(x?['id_card_paths'],x?['id_card_path']);
    _contractPaths=_decodePaths(x?['contract_paths'],x?['contract_path']);
  }

  @override void dispose(){
    for(final c in [_name,_address,_location,_tenant,_phone,_altPhone,_rent,_deposit,_elec,_water,_gas]){c.dispose();}
    super.dispose();
  }

  Future<String> _persist(XFile img) async {
    final dir=await getApplicationDocumentsDirectory();
    final dest=p.join(dir.path,'img_${DateTime.now().microsecondsSinceEpoch}${p.extension(img.path)}');
    await File(img.path).copy(dest);
    return dest;
  }

  Future<void> _addImages(List<String> target) async {
    if(target.length>=20){_msg('الحد الأقصى 20 صورة لكل مستند');return;}
    final source=await showModalBottomSheet<String>(context:context,builder:(ctx)=>SafeArea(child:Column(mainAxisSize:MainAxisSize.min,children:[
      ListTile(leading:const Icon(Icons.photo_camera_outlined),title:const Text('التقاط صورة بالكاميرا'),onTap:()=>Navigator.pop(ctx,'camera')),
      ListTile(leading:const Icon(Icons.photo_library_outlined),title:const Text('اختيار صور من المعرض'),onTap:()=>Navigator.pop(ctx,'gallery')),
    ])));
    if(source==null)return;
    try{
      final picker=ImagePicker();
      final free=20-target.length;
      if(source=='camera'){
        final img=await picker.pickImage(source:ImageSource.camera,maxWidth:1600,imageQuality:80);
        if(img!=null) target.add(await _persist(img));
      }else{
        final imgs=await picker.pickMultiImage(maxWidth:1600,imageQuality:80);
        final chosen=imgs.take(free).toList();
        for(final img in chosen){target.add(await _persist(img));}
        if(imgs.length>free)_msg('تم اختيار أول $free صورة فقط لأن الحد الأقصى 20');
      }
      if(mounted)setState((){});
    }catch(_){_msg('تعذر الوصول للصور');}
  }
  void _msg(String x){if(mounted)ScaffoldMessenger.of(context).showSnackBar(SnackBar(content:Text(x)));}

  Future<void> _pickDue() async {
    final d=await showDatePicker(context:context,initialDate:_due??DateTime.now(),firstDate:DateTime(2020),lastDate:DateTime(2100));
    if(d!=null)setState(()=>_due=d);
  }

  Future<void> _save() async {
    if(!_formKey.currentState!.validate())return;
    setState(()=>_saving=true);
    double d(TextEditingController c)=>double.tryParse(c.text.trim())??0;
    final data=<String,dynamic>{
      'name':_name.text.trim(),'address':_address.text.trim(),'location':_location.text.trim(),
      'tenant_name':_tenant.text.trim(),'tenant_phone':_phone.text.trim(),'tenant_alt_phone':_altPhone.text.trim(),
      'rent_amount':d(_rent),'deposit_amount':d(_deposit),'electricity':d(_elec),'water':d(_water),'gas':d(_gas),
      'status':_status,'due_date':_due==null?'':_isoFmt.format(_due!),
      'id_card_paths':jsonEncode(_idPaths),'contract_paths':jsonEncode(_contractPaths),
      'id_card_path':_idPaths.isEmpty?'':_idPaths.first,'contract_path':_contractPaths.isEmpty?'':_contractPaths.first,
    };
    if(_isEdit) await DB.update(widget.property!['id'] as int,data); else await DB.insert(data);
    if(mounted)Navigator.pop(context,true);
  }

  Widget _field(String label,TextEditingController c,{IconData? icon,bool number=false,bool phone=false,bool required=false})=>Padding(
    padding:const EdgeInsets.only(bottom:12),child:TextFormField(controller:c,
      keyboardType:number?const TextInputType.numberWithOptions(decimal:true):(phone?TextInputType.phone:TextInputType.text),
      inputFormatters:number?[FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]:null,
      validator:required?(v)=>(v==null||v.trim().isEmpty)?'هذا الحقل مطلوب':null:null,
      decoration:InputDecoration(labelText:label,prefixIcon:icon==null?null:Icon(icon))));
  Widget _section(String t)=>Padding(padding:const EdgeInsets.only(top:8,bottom:12),child:Text(t,style:const TextStyle(fontSize:16,fontWeight:FontWeight.w800)));

  Widget _attachments(String title,List<String> paths,IconData icon)=>AppCard(child:Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
    Row(children:[Icon(icon),const SizedBox(width:8),Expanded(child:Text('$title (${paths.length}/20)',style:const TextStyle(fontWeight:FontWeight.w700))),TextButton.icon(onPressed:paths.length>=20?null:()=>_addImages(paths),icon:const Icon(Icons.add_photo_alternate_outlined),label:const Text('إضافة'))]),
    if(paths.isEmpty)const Padding(padding:EdgeInsets.all(12),child:Center(child:Text('لا توجد صور مرفقة',style:TextStyle(color:Colors.black45))))
    else SizedBox(height:94,child:ListView.separated(scrollDirection:Axis.horizontal,itemCount:paths.length,separatorBuilder:(_,__)=>const SizedBox(width:8),itemBuilder:(_,i){final path=paths[i];return Stack(children:[
      ClipRRect(borderRadius:BorderRadius.circular(10),child:File(path).existsSync()?Image.file(File(path),width:90,height:90,fit:BoxFit.cover):Container(width:90,height:90,color:Colors.black12,child:const Icon(Icons.broken_image))),
      PositionedDirectional(top:3,end:3,child:CircleAvatar(radius:13,backgroundColor:Colors.black54,child:IconButton(padding:EdgeInsets.zero,iconSize:15,color:Colors.white,onPressed:()=>setState(()=>paths.removeAt(i)),icon:const Icon(Icons.close))))
    ]);}))
  ])));

  @override Widget build(BuildContext context)=>Scaffold(
    appBar:AppBar(title:Text(_isEdit?'تعديل عقار':'إضافة عقار جديد',style:const TextStyle(fontWeight:FontWeight.w800))),
    body:Form(key:_formKey,child:ListView(padding:const EdgeInsets.fromLTRB(16,8,16,32),children:[
      _section('بيانات العقار'),
      if(_isEdit) Padding(padding:const EdgeInsets.only(bottom:12),child:InputDecorator(decoration:const InputDecoration(labelText:'ID العقار',prefixIcon:Icon(Icons.numbers)),child:Text('${widget.property!['id']}'))),
      _field('اسم العقار',_name,icon:Icons.apartment,required:true),
      _field('العنوان',_address,icon:Icons.place_outlined),
      _field('موقع العقار',_location,icon:Icons.location_on_outlined),
      DropdownButtonFormField<String>(value:_status,items:kStatuses.map((s)=>DropdownMenuItem(value:s,child:Text(s))).toList(),onChanged:(v)=>setState(()=>_status=v??_status),decoration:const InputDecoration(labelText:'حالة العقار',prefixIcon:Icon(Icons.flag_outlined))),
      const SizedBox(height:12),_section('بيانات المستأجر'),
      _field('اسم المستأجر',_tenant,icon:Icons.person_outline),
      _field('رقم الهاتف',_phone,icon:Icons.phone_outlined,phone:true),
      _field('رقم هاتف بديل',_altPhone,icon:Icons.phone_in_talk_outlined,phone:true),
      _section('الماليات'),
      Padding(padding:const EdgeInsets.only(bottom:12),child:InkWell(borderRadius:BorderRadius.circular(14),onTap:_pickDue,child:InputDecorator(decoration:InputDecoration(labelText:'تاريخ الاستحقاق',prefixIcon:const Icon(Icons.event_outlined),suffixIcon:_due==null?null:IconButton(icon:const Icon(Icons.close),onPressed:()=>setState(()=>_due=null))),child:Text(_due==null?'اضغط لاختيار التاريخ':_dateFmt.format(_due!))))),
      _field('الإيجار الشهري',_rent,icon:Icons.payments_outlined,number:true),
      _field('قيمة التأمين',_deposit,icon:Icons.savings_outlined,number:true),
      _field('فاتورة الكهرباء',_elec,icon:Icons.bolt_outlined,number:true),
      _field('فاتورة المياه',_water,icon:Icons.water_drop_outlined,number:true),
      _field('فاتورة الغاز',_gas,icon:Icons.local_fire_department_outlined,number:true),
      _section('المرفقات - بحد أقصى 20 صورة لكل مستند'),
      _attachments('بطاقة المستأجر',_idPaths,Icons.badge_outlined),const SizedBox(height:12),
      _attachments('العقد',_contractPaths,Icons.description_outlined),const SizedBox(height:24),
      SizedBox(height:52,child:FilledButton.icon(onPressed:_saving?null:_save,icon:const Icon(Icons.check),label:Text(_isEdit?'تحديث':'حفظ',style:const TextStyle(fontSize:16,fontWeight:FontWeight.w700))))
    ])));
}
