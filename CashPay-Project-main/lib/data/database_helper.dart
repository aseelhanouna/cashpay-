import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';
import '../core/session_manager.dart';
import 'package:flutter/foundation.dart';
import '../security/crypto_helper.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;

  final _secureStorage = const FlutterSecureStorage();

  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('cashpay.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);
    String? key = await _secureStorage.read(key: 'db_key');
    if (key == null) {
      key = base64Url.encode(
        List<int>.generate(32, (_) => Random.secure().nextInt(256)),
      );
      await _secureStorage.write(key: 'db_key', value: key);
    }
    return await openDatabase(
      path,
      version: 4,
      password: key,
      onCreate: _createDB,
      onUpgrade: _onUpgrade,
    );
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
      CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        id_number TEXT UNIQUE,
        name TEXT,
        password TEXT,
        birthDate TEXT,
        pin TEXT,
        salt TEXT,
        balance REAL DEFAULT 100.0,
        sync_status TEXT DEFAULT 'pending'
      )
    ''');
    await db.execute('''
      CREATE TABLE transactions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        tx_id TEXT UNIQUE NOT NULL,
        sender_id INTEGER NOT NULL,
        receiver_id INTEGER,
        amount REAL NOT NULL,
        type TEXT NOT NULL,
        status TEXT NOT NULL,
        signature TEXT NOT NULL,
        used INTEGER DEFAULT 0,
        created_at INTEGER NOT NULL,
        sync_status TEXT DEFAULT 'pending',
        timestamp INTEGER,
        synced_at INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE fraud_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        tx_id TEXT,
        reason TEXT,
        created_at INTEGER
      )
    ''');
    await _createPiggyTables(db);
    await _createSyncLogsTable(db);
  }

  Future _createPiggyTables(Database db) async {
    // هدف/أهداف الحصالة الذكية لكل مستخدم
    await db.execute('''
      CREATE TABLE piggy_goals (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        name TEXT NOT NULL,
        target_amount REAL NOT NULL DEFAULT 0,
        target_date TEXT,
        saved_amount REAL NOT NULL DEFAULT 0,
        percentage REAL NOT NULL DEFAULT 0,
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at INTEGER NOT NULL
      )
    ''');
    // سجل كل إيداع/سحب في الحصالة (لعرض الأنيميشن والتاريخ ولحساب الشارات)
    await db.execute('''
      CREATE TABLE piggy_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        goal_id INTEGER NOT NULL,
        user_id INTEGER NOT NULL,
        amount REAL NOT NULL,
        source TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    // الشارات التي حصل عليها المستخدم
    await db.execute('''
      CREATE TABLE badges (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        badge_key TEXT NOT NULL,
        earned_at INTEGER NOT NULL,
        UNIQUE(user_id, badge_key)
      )
    ''');
  }

  Future _createSyncLogsTable(Database db) async {
    // سجل المزامنة: يوثّق كل محاولة مزامنة ناجحة أو فاشلة لتسهيل التتبع والتشخيص
    await db.execute('''
      CREATE TABLE sync_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id INTEGER NOT NULL,
        tx_id TEXT,
        status TEXT NOT NULL,
        message TEXT,
        created_at INTEGER NOT NULL
      )
    ''');
  }

  Future _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE transactions RENAME TO transactions_old');
      await db.execute('''
        CREATE TABLE transactions (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          tx_id TEXT UNIQUE NOT NULL,
          sender_id INTEGER NOT NULL,
          receiver_id INTEGER,
          amount REAL NOT NULL,
          type TEXT NOT NULL,
          status TEXT NOT NULL,
          signature TEXT NOT NULL,
          used INTEGER DEFAULT 0,
          created_at INTEGER NOT NULL,
          sync_status TEXT DEFAULT 'pending',
          timestamp INTEGER,
          synced_at INTEGER
        )
      ''');
      await db.execute('INSERT INTO transactions SELECT * FROM transactions_old');
      await db.execute('DROP TABLE transactions_old');
      debugPrint("DB upgraded to v2: receiver_id now nullable");
    }
    if (oldVersion < 3) {
      await _createPiggyTables(db);
      debugPrint("DB upgraded to v3: piggy bank & badges tables added");
    }
    if (oldVersion < 4) {
      await _createSyncLogsTable(db);
      debugPrint("DB upgraded to v4: sync_logs table added");
    }
  }

  Future<int> createUser(Map<String, dynamic> user) async {
    final dbClient = await database;
    final existing = await dbClient.query(
      'users',
      where: 'id_number = ?',
      whereArgs: [user['id_number']],
    );
    if (existing.isNotEmpty) {
      throw Exception("رقم الهوية هذا مستخدم مسبقاً");
    }
    return await dbClient.insert(
      'users',
      user,
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
  }

  Future<Map<String, dynamic>?> login(String idNumber, String password) async {
    final db = await database;
    final result = await db.query(
      'users',
      where: 'id_number = ?',
      whereArgs: [idNumber],
    );
    if (result.isEmpty) return null;
    final user = result.first;
    final salt = user['salt']?.toString() ?? "";
    final hashedPassword =
        sha256.convert(utf8.encode(password + salt)).toString();
    if (hashedPassword != user['password']) return null;
    return {'id': user['id'], 'name': user['name']};
  }

   
   
Future<void> receiveTokens({
  required String txId,
  required int senderId,
  required dynamic receiverId, // جعلناه dynamic ليقبل نص أو رقم
  required double amount,
  required String signature,
  required int timestamp,
}) async {
  final db = await database;

  await db.transaction((txn) async {
    // 1. التأكد من عدم تكرار العملية
    final existing = await txn.query('transactions', where: 'tx_id = ?', whereArgs: [txId]);
    if (existing.isNotEmpty) throw Exception("الرمز مستخدم مسبقاً");

    // 2. التحديث الذكي: يبحث عن المستخدم برقم هويته (id_number) 
    // وهذا سيحل مشكلة "فشل التحديث للمستخدم 123456789"
    int count = await txn.rawUpdate(
      'UPDATE users SET balance = balance + ? WHERE id_number = ?',
      [amount, receiverId.toString()], // نحول المعرف لنص للبحث في id_number
    );

    // 3. إذا لم يجد رقم الهوية، نجرب البحث بالـ ID التسلسلي (احتياطاً)
    if (count == 0) {
      count = await txn.rawUpdate(
        'UPDATE users SET balance = balance + ? WHERE id = ?',
        [amount, receiverId],
      );
    }

    // 4. تسجيل العملية في السجل (حتى لو فشل تحديث الرصيد، السجل يثبت الحق)
    await txn.insert('transactions', {
      'tx_id': txId,
      'sender_id': senderId,
      'receiver_id': receiverId.toString(),
      'amount': amount,
      'type': 'receive',
      'status': 'completed',
      'signature': signature,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'timestamp': timestamp,
      'sync_status': 'pending',
    });
    
    debugPrint("✅ تمت العملية بنجاح للمستقبل: $receiverId");
  });
}

    
  Future<double> getUserBalance(int userId) async {
    final db = await database;
    final result = await db.query(
      'users',
      where: 'id = ?',
      whereArgs: [userId],
      columns: ['balance'],
    );
    if (result.isNotEmpty) {
      return (result.first['balance'] as num).toDouble();
    }
    return 100.0;
  }

  Future<List<Map<String, dynamic>>> getRecentTransactions(int userId) async {
    final db = await database;
    return await db.query(
      'transactions',
      where: '(sender_id = ? OR receiver_id = ?) AND status = ?',
      whereArgs: [userId, userId, 'completed'],
      orderBy: 'created_at DESC',
      limit: 20,
    );
  }

  Future<List<Map<String, dynamic>>> getUserTransactions(int userId) async {
  final db = await database;
  return await db.rawQuery('''
    SELECT t.*,
      -- إذا لم يجد اسم المرسل محلياً، يكتب "مرسل (رقم المعرف)"
      IFNULL(sender.name, 'مرسل رقم: ' || t.sender_id) AS sender_name,
      -- إذا لم يجد اسم المستقبل محلياً، يكتب "مستقبل (رقم المعرف)"
      IFNULL(receiver.name, 'مستقبل رقم: ' || t.receiver_id) AS receiver_name
    FROM transactions t
    LEFT JOIN users sender ON sender.id = t.sender_id
    LEFT JOIN users receiver ON receiver.id = t.receiver_id
    WHERE (t.sender_id = ? OR t.receiver_id = ?) 
      AND t.status = 'completed'
    ORDER BY t.created_at DESC
  ''', [userId, userId]);
}


  Future<bool> isTransactionExists(String txId) async {
    final db = await database;
    final result = await db.query(
      'transactions',
      where: 'tx_id = ? AND status = ?',
      whereArgs: [txId, 'completed'],
    );
    return result.isNotEmpty;
  }

  Future<String?> getUserIdNumber(int userId) async {
    final db = await database;
    final res = await db.query(
      'users',
      where: 'id = ?',
      whereArgs: [userId],
      columns: ['id_number'],
    );
    if (res.isNotEmpty) return res.first['id_number'] as String?;
    return null;
  }

  Future<String> getUserName(int userId) async {
    final db = await database;
    final res = await db.query(
      'users',
      where: 'id = ?',
      whereArgs: [userId],
      columns: ['name'],
    );
    if (res.isNotEmpty) return res.first['name'] as String;
    return "مستخدم";
  }

  Future<List<Map<String, dynamic>>> getPendingTransactions() async {
    final db = await instance.database;
    return await db.query(
      'transactions',
      where: '(sync_status = ? OR sync_status = ?) AND status = ?',
      whereArgs: ['pending', 'failed', 'completed'],
    );
  }

  Future<int> countRecentTransactions(int userId) async {
    final db = await database;
    final int fiveMinutesAgo = DateTime.now()
        .subtract(const Duration(minutes: 5))
        .millisecondsSinceEpoch;
    final result = await db.rawQuery('''
      SELECT COUNT(*) as total
      FROM transactions
      WHERE (sender_id = ? OR receiver_id = ?)
      AND created_at > ?
      AND status = 'completed'
    ''', [userId, userId, fiveMinutesAgo]);
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> markAsSynced(String txId) async {
    final db = await database;
    await db.update(
      'transactions',
      {
        'sync_status': 'synced',
        'synced_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'tx_id = ?',
      whereArgs: [txId],
    );
  }

  Future<void> markAsFailed(String txId) async {
    final db = await database;
    await db.update(
      'transactions',
      {'sync_status': 'failed'},
      where: 'tx_id = ?',
      whereArgs: [txId],
    );
  }

  Future<void> logFraud(String txId, String reason) async {
    final db = await database;
    await db.insert('fraud_logs', {
      'tx_id': txId,
      'reason': reason,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<int> topUpBalance(int userId, double amount) async {
    final db = await instance.database;
    return await db.rawUpdate(
      'UPDATE users SET balance = balance + ? WHERE id = ?',
      [amount, userId],
    );
  }

  Future<void> updateUserBalance(int userId, double newBalance) async {
    final db = await instance.database;
    await db.rawUpdate('''
      UPDATE users
      SET balance = ?,
          sync_status = 'pending'
      WHERE id = ?
    ''', [newBalance, userId]);
    debugPrint("تم تحديث الرصيد للمستخدم $userId إلى $newBalance");
  }

 Future<void> updateBalance(int userId, double amount) async {
  final db = await database;

  // استخدام Transaction لضمان دقة البيانات
  await db.transaction((txn) async {
    // 1. جلب الرصيد الحالي داخل الترانزاكشن
    final List<Map<String, dynamic>> res = await txn.query(
      'users',
      columns: ['balance'],
      where: 'id = ?',
      whereArgs: [userId],
    );

    if (res.isEmpty) return;

    double current = (res.first['balance'] as num).toDouble();

    // 2. التحقق: إذا كان المبلغ المطلوب خصمه (amount سالب) أكبر من الرصيد المتوفر
    if (amount < 0 && (current + amount) < 0) {
      throw Exception("عذراً، رصيدك الحالي ($current ₪) لا يكفي");
    }

    // 3. التحديث إذا نجح الفحص
    await txn.rawUpdate(
      '''
      UPDATE users
      SET balance = balance + ?,
          sync_status = 'pending'
      WHERE id = ?
      ''',
      [amount, userId],
    );
  });
}


  Future<void> saveOutgoingTransaction({
    required String txId,
    required int senderId,
    required double amount,
    required String signature,
    required int timestamp,
  }) async {
    final db = await database;
    await db.insert(
      'transactions',
      {
        'tx_id': txId,
        'sender_id': senderId,
        'receiver_id': null,
        'amount': amount,
        'signature': signature,
        'timestamp': timestamp,
        'type': 'outgoing',
        'status': 'pending',
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'sync_status': 'pending',
      },
      conflictAlgorithm: ConflictAlgorithm.abort,
    );
    debugPrint("Outgoing transaction saved: $txId");
  }
Future<void> saveCompletedOutgoingTransaction({
  required String txId,
  required int senderId,
  required double amount,
  required String signature,
  required int timestamp,
}) async {
  final db = await database;

  await db.insert(
    'transactions',
    {
      'tx_id': txId,
      'sender_id': senderId,
      'receiver_id': null,
      'amount': amount,
      'signature': signature,
      'timestamp': timestamp,
      'type': 'transfer',
      'status': 'completed',
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'sync_status': 'pending',
    },
  );
}
Future<void> addTransaction({
  required int senderId,
  required int receiverId,
  required double amount,
  required String type,
}) async {
  final db = await database;

  await db.insert('transactions', {
    'sender_id': senderId,    
    'receiver_id': receiverId,
    'amount': amount,
    'type': type,
    'tx_id': DateTime.now().millisecondsSinceEpoch.toString(), 
    'status': 'completed', 
    'signature': 'manual',
    'created_at': DateTime.now().millisecondsSinceEpoch, 
    'timestamp': DateTime.now().millisecondsSinceEpoch,
  });
}

  // ============================================================
  // الحصالة الذكية (Smart Piggy Bank)
  // ============================================================

  /// إنشاء هدف ادخار جديد. يعطّل أي هدف نشط سابق (هدف واحد نشط بكل مرة).
  Future<int> createPiggyGoal({
    required int userId,
    required String name,
    required double targetAmount,
    String? targetDate,
    double percentage = 0,
  }) async {
    final db = await database;
    await db.update(
      'piggy_goals',
      {'is_active': 0},
      where: 'user_id = ? AND is_active = 1',
      whereArgs: [userId],
    );
    return await db.insert('piggy_goals', {
      'user_id': userId,
      'name': name,
      'target_amount': targetAmount,
      'target_date': targetDate,
      'saved_amount': 0.0,
      'percentage': percentage,
      'is_active': 1,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// الهدف النشط الحالي للمستخدم (إن وجد)
  Future<Map<String, dynamic>?> getActivePiggyGoal(int userId) async {
    final db = await database;
    final result = await db.query(
      'piggy_goals',
      where: 'user_id = ? AND is_active = 1',
      whereArgs: [userId],
      limit: 1,
    );
    return result.isNotEmpty ? result.first : null;
  }

  /// كل أهداف المستخدم (نشطة ومنتهية) الأحدث أولاً
  Future<List<Map<String, dynamic>>> getAllPiggyGoals(int userId) async {
    final db = await database;
    return await db.query(
      'piggy_goals',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'created_at DESC',
    );
  }

  /// إيداع مبلغ بالحصالة (يدوي أو تلقائي) + تسجيله بالسجل لعرض الأنيميشن والتاريخ
  Future<void> depositToPiggy({
    required int goalId,
    required int userId,
    required double amount,
    required String source, // 'manual' | 'auto_percentage' | 'keep_change'
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.rawUpdate(
        'UPDATE piggy_goals SET saved_amount = saved_amount + ? WHERE id = ?',
        [amount, goalId],
      );
      await txn.insert('piggy_log', {
        'goal_id': goalId,
        'user_id': userId,
        'amount': amount,
        'source': source,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
    });
  }

  /// سحب من الحصالة إلى الرصيد الرئيسي مباشرة
  Future<void> withdrawFromPiggy({
    required int goalId,
    required int userId,
    required double amount,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      final res = await txn.query('piggy_goals',
          where: 'id = ?', whereArgs: [goalId], columns: ['saved_amount']);
      if (res.isEmpty) throw Exception("الهدف غير موجود");
      final double saved = (res.first['saved_amount'] as num).toDouble();
      if (amount > saved) throw Exception("رصيد الحصالة لا يكفي لهذا السحب");

      await txn.rawUpdate(
        'UPDATE piggy_goals SET saved_amount = saved_amount - ? WHERE id = ?',
        [amount, goalId],
      );
      await txn.rawUpdate(
        "UPDATE users SET balance = balance + ?, sync_status = 'pending' WHERE id = ?",
        [amount, userId],
      );
      await txn.insert('piggy_log', {
        'goal_id': goalId,
        'user_id': userId,
        'amount': -amount,
        'source': 'withdraw',
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
    });
  }

  /// سجل الإيداعات الأخيرة لهدف معيّن (يُستخدم لأنيميشن سقوط القطع بالوعاء)
  Future<List<Map<String, dynamic>>> getPiggyLog(int goalId,
      {int limit = 30}) async {
    final db = await database;
    return await db.query(
      'piggy_log',
      where: 'goal_id = ?',
      whereArgs: [goalId],
      orderBy: 'created_at DESC',
      limit: limit,
    );
  }

  /// عدد الأيام المختلفة التي تم فيها الادخار خلال آخر [days] يوم (لحساب شارة الاستمرارية)
  Future<int> countDistinctSavingDays(int userId, {int days = 30}) async {
    final db = await database;
    final since = DateTime.now()
        .subtract(Duration(days: days))
        .millisecondsSinceEpoch;
    final result = await db.rawQuery('''
      SELECT COUNT(DISTINCT date(created_at / 1000, 'unixepoch')) as total
      FROM piggy_log
      WHERE user_id = ? AND amount > 0 AND created_at > ?
    ''', [userId, since]);
    return Sqflite.firstIntValue(result) ?? 0;
  }

  // ============================================================
  // الشارات (Badges)
  // ============================================================

  /// يمنح شارة إن لم تكن ممنوحة مسبقاً. يعيد true إذا كانت شارة جديدة (لإظهار احتفال بالواجهة)
  Future<bool> awardBadgeIfNew(int userId, String badgeKey) async {
    final db = await database;
    try {
      await db.insert(
        'badges',
        {
          'user_id': userId,
          'badge_key': badgeKey,
          'earned_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.abort,
      );
      return true;
    } catch (_) {
      return false; // موجودة مسبقاً
    }
  }

  Future<List<Map<String, dynamic>>> getUserBadges(int userId) async {
    final db = await database;
    return await db.query(
      'badges',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'earned_at DESC',
    );
  }

  // ============================================================
  // سجل المزامنة (Sync Logs)
  // ============================================================

  Future<void> logSync({
    required int userId,
    String? txId,
    required String status, // 'success' | 'failed'
    String? message,
  }) async {
    final db = await database;
    await db.insert('sync_logs', {
      'user_id': userId,
      'tx_id': txId,
      'status': status,
      'message': message,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<List<Map<String, dynamic>>> getSyncLogs(int userId, {int limit = 50}) async {
    final db = await database;
    return await db.query(
      'sync_logs',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'created_at DESC',
      limit: limit,
    );
  }

  // ============================================================
  // الإحصائيات الشهرية (Monthly Statistics)
  // ============================================================

  /// إجمالي المُرسل والمُستلم لكل شهر خلال آخر [months] شهراً (لعرضها برسم بياني)
  Future<List<Map<String, dynamic>>> getMonthlyTotals(int userId,
      {int months = 6}) async {
    final db = await database;
    final since = DateTime.now()
        .subtract(Duration(days: months * 31))
        .millisecondsSinceEpoch;

    final sentRows = await db.rawQuery('''
      SELECT strftime('%Y-%m', created_at / 1000, 'unixepoch') as ym,
             SUM(amount) as total
      FROM transactions
      WHERE sender_id = ? AND status = 'completed' AND created_at > ?
      GROUP BY ym
    ''', [userId, since]);

    final receivedRows = await db.rawQuery('''
      SELECT strftime('%Y-%m', created_at / 1000, 'unixepoch') as ym,
             SUM(amount) as total
      FROM transactions
      WHERE receiver_id = ? AND status = 'completed' AND created_at > ?
      GROUP BY ym
    ''', [userId, since]);

    final Map<String, Map<String, double>> merged = {};
    for (final row in sentRows) {
      final ym = row['ym'] as String;
      merged[ym] = {'sent': (row['total'] as num).toDouble(), 'received': 0.0};
    }
    for (final row in receivedRows) {
      final ym = row['ym'] as String;
      final received = (row['total'] as num).toDouble();
      if (merged.containsKey(ym)) {
        merged[ym]!['received'] = received;
      } else {
        merged[ym] = {'sent': 0.0, 'received': received};
      }
    }

    final keys = merged.keys.toList()..sort();
    return keys
        .map((k) => {'month': k, 'sent': merged[k]!['sent'], 'received': merged[k]!['received']})
        .toList();
  }

  /// إجمالي ما تم إرساله واستلامه وتوفيره خلال الشهر الحالي (لمؤشر الادخار بالداشبورد)
  Future<Map<String, double>> getCurrentMonthSummary(int userId) async {
    final db = await database;
    final now = DateTime.now();
    final startOfMonth =
        DateTime(now.year, now.month, 1).millisecondsSinceEpoch;

    final sentRes = await db.rawQuery('''
      SELECT IFNULL(SUM(amount), 0) as total FROM transactions
      WHERE sender_id = ? AND status = 'completed' AND created_at >= ?
    ''', [userId, startOfMonth]);
    final receivedRes = await db.rawQuery('''
      SELECT IFNULL(SUM(amount), 0) as total FROM transactions
      WHERE receiver_id = ? AND status = 'completed' AND created_at >= ?
    ''', [userId, startOfMonth]);
    final savedRes = await db.rawQuery('''
      SELECT IFNULL(SUM(amount), 0) as total FROM piggy_log
      WHERE user_id = ? AND amount > 0 AND created_at >= ?
    ''', [userId, startOfMonth]);

    return {
      'sent': ((sentRes.first['total'] as num?) ?? 0).toDouble(),
      'received': ((receivedRes.first['total'] as num?) ?? 0).toDouble(),
      'saved': ((savedRes.first['total'] as num?) ?? 0).toDouble(),
    };
  }

}