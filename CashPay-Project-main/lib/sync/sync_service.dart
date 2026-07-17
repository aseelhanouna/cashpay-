import 'package:myapp/data/database_helper.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

class SyncService {

  static Future<void> syncAll(int userId) async {
    debugPrint("🔄 بدء عملية المزامنة الشاملة للمستخدم: $userId");
    await syncTransactions(userId);
    await syncUserProfile(userId);
  }

  static Future<void> syncTransactions(int userId) async {
    final db = DatabaseHelper.instance;
    final pending = await db.getPendingTransactions();

    if (pending.isEmpty) return;

    // ⚠️ مستند المستخدم على Firestore مفتاحه رقم الهوية (id_number) وليس
    // المعرف الرقمي المحلي، لأن التسجيل/الدخول ينشئ المستند بهذا الشكل.
    final String? idNumber = await db.getUserIdNumber(userId);
    if (idNumber == null) {
      debugPrint("⚠️ تعذر إيجاد رقم الهوية محلياً، تخطي المزامنة");
      return;
    }

    for (var tx in pending) {
      final String txId = tx["tx_id"] as String;
      try {
        // استخدمي writeBatch إذا كانت العمليات كثيرة، لكن حالياً الكود سليم
        await FirebaseFirestore.instance
            .collection("transactions") // يفضل وضع كل العمليات في كولكشن موحد للبحث لاحقاً
            .doc(txId)
            .set({
              ...tx,
              "synced_at": FieldValue.serverTimestamp(),
            });

        // تحديث رصيد المستخدم في السيرفر بناءً على هذه العملية
        final bool isSender = tx['sender_id'] == userId;
        final double amount = (tx['amount'] as num).toDouble();
        final double balanceDelta = isSender ? -amount : amount;

        await FirebaseFirestore.instance
            .collection("users")
            .doc(idNumber)
            .update({
              "balance": FieldValue.increment(balanceDelta),
            });

        await db.markAsSynced(txId);
        await db.logSync(userId: userId, txId: txId, status: 'success');
      } on FirebaseException catch (e) {
        // أخطاء Firebase محددة (صلاحيات، مستند غير موجود...) نسجلها كفشل
        // دائم لهذه العملية بدل تعليق كل قائمة الانتظار عليها
        debugPrint("❌ Firebase error syncing $txId (${e.code}): ${e.message}");
        await db.markAsFailed(txId);
        await db.logSync(
          userId: userId,
          txId: txId,
          status: 'failed',
          message: "${e.code}: ${e.message}",
        );
        if (e.code == 'unavailable' || e.code == 'network-request-failed') {
          // لا داعي لمحاولة بقية القائمة إذا كان السبب انقطاع الشبكة
          break;
        }
      } catch (e) {
        debugPrint("❌ فشل رفع العملية $txId: $e");
        await db.logSync(
            userId: userId, txId: txId, status: 'failed', message: e.toString());
        // على الأغلب انقطاع إنترنت عام: لا تكمل المزامنة على بقية القائمة الآن
        break;
      }
    }
  }

  static Future<void> syncUserProfile(int userId) async {
    try {
      final db = DatabaseHelper.instance;
      double currentBalance = await db.getUserBalance(userId);
      String userName = await db.getUserName(userId);
      final String? idNumber = await db.getUserIdNumber(userId);
      if (idNumber == null) return;

      await FirebaseFirestore.instance
          .collection("users")
          .doc(idNumber)
          .update({
        "name": userName,
        "last_sync_balance": currentBalance,
        "last_online": FieldValue.serverTimestamp(),
      });

      debugPrint("✅ تم تحديث بيانات الملف الشخصي سحابياً.");
    } on FirebaseException catch (e) {
      debugPrint("⚠️ فشل تحديث بيانات الملف الشخصي (${e.code}): ${e.message}");
    } catch (e) {
      debugPrint("⚠️ فشل تحديث بيانات الملف الشخصي: $e");
    }
  }
}
