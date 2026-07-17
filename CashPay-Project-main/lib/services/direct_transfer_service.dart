import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../data/database_helper.dart';
import '../core/session_manager.dart';
import '../core/transaction_service.dart';
import '../core/piggy_bank_service.dart';
import '../security/crypto_helper.dart';

/// نتيجة البحث عن مستخدم برقم الهوية على Firestore، تُستخدم لعرض اسمه
/// للتأكيد قبل تنفيذ التحويل المباشر.
class DirectTransferRecipient {
  final String idNumber;
  final String name;
  DirectTransferRecipient({required this.idNumber, required this.name});
}

/// خدمة الدفع الأونلاين المباشر بدون QR: يُدخل المستخدم رقم هوية المستقبل
/// فيتم البحث عنه على Firestore والتحويل الفوري بينهما (يتطلب اتصال إنترنت).
class DirectTransferService {
  static final _firestore = FirebaseFirestore.instance;

  /// يبحث عن مستخدم عبر رقم هويته على Firestore. يعيد null إن لم يوجد.
  static Future<DirectTransferRecipient?> lookupByIdNumber(
      String idNumber) async {
    final doc = await _firestore.collection('users').doc(idNumber).get();
    if (!doc.exists) return null;
    final data = doc.data();
    if (data == null) return null;
    return DirectTransferRecipient(
      idNumber: idNumber,
      name: (data['name'] ?? 'مستخدم') as String,
    );
  }

  /// ينفذ التحويل الفوري: يتحقق من الحظر واحتيال التكرار محلياً، ثم يجري
  /// عملية Firestore transaction ذرّية على رصيد الطرفين، ثم يحدّث القاعدة
  /// المحلية للمرسل ويسجّل العملية. يعيد مقدار ما تم اقتطاعه للحصالة الذكية إن وجد.
  static Future<double> transfer({
    required int senderId,
    required String receiverIdNumber,
    required double amount,
  }) async {
    if (amount <= 0) throw Exception("أدخل مبلغاً صحيحاً");

    if (await SessionManager.isBlocked()) {
      throw Exception("التطبيق مقفل مؤقتاً");
    }
    await TransactionService.checkFraudLimit(senderId);

    final db = DatabaseHelper.instance;
    final senderIdNumber = await db.getUserIdNumber(senderId);
    if (senderIdNumber == null) {
      throw Exception("تعذر التحقق من هوية المرسل");
    }
    if (senderIdNumber == receiverIdNumber) {
      throw Exception("لا يمكن تحويل الأموال لنفسك");
    }

    final localBalance = await db.getUserBalance(senderId);
    if (localBalance < amount) {
      throw Exception("رصيدك الحالي غير كافٍ");
    }

    final senderRef = _firestore.collection('users').doc(senderIdNumber);
    final receiverRef = _firestore.collection('users').doc(receiverIdNumber);

    final String txId =
        "DT_${senderId}_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(99999)}";
    final int timestamp = DateTime.now().millisecondsSinceEpoch;
    final String amountStr = amount.toStringAsFixed(2);
    final String signature = CryptoHelper.sign(
      CryptoHelper.buildRawData(
        txId: txId,
        senderId: senderId,
        amountStr: amountStr,
        timestamp: timestamp,
      ),
      senderId,
    );

    // 1) تنفيذ التحويل الذري على Firestore (يفشل بالكامل إن لم يكفِ الرصيد
    // أو لم يوجد أحد الطرفين، فلا يحدث خصم بدون إيداع أو العكس).
    await _firestore.runTransaction((txn) async {
      final senderSnap = await txn.get(senderRef);
      final receiverSnap = await txn.get(receiverRef);

      if (!senderSnap.exists) throw Exception("تعذر إيجاد حسابك على السيرفر");
      if (!receiverSnap.exists) throw Exception("رقم الهوية غير مسجل");

      final double serverSenderBalance =
          ((senderSnap.data()?['balance'] ?? 0) as num).toDouble();
      final double serverReceiverBalance =
          ((receiverSnap.data()?['balance'] ?? 0) as num).toDouble();

      if (serverSenderBalance < amount) {
        throw Exception("رصيدك على السيرفر غير كافٍ، تأكد من مزامنة رصيدك");
      }

      txn.update(senderRef, {'balance': serverSenderBalance - amount});
      txn.update(receiverRef, {'balance': serverReceiverBalance + amount});
    });

    // 2) تسجيل العملية للتدقيق (خارج الـ transaction لأنها ليست حرجة الذرّية)
    await _firestore.collection('transactions').doc(txId).set({
      'tx_id': txId,
      'sender_id_number': senderIdNumber,
      'receiver_id_number': receiverIdNumber,
      'amount': amount,
      'type': 'direct_online',
      'status': 'completed',
      'signature': signature,
      'timestamp': timestamp,
      'created_at': FieldValue.serverTimestamp(),
    });

    // 3) تحديث القاعدة المحلية للمرسل فوراً حتى لو انقطع الاتصال بعدها
    await db.updateBalance(senderId, -amount);
    await db.saveCompletedOutgoingTransaction(
      txId: txId,
      senderId: senderId,
      amount: amount,
      signature: signature,
      timestamp: timestamp,
    );

    debugPrint("Direct online transfer completed: $txId");

    // 4) تطبيق الاستقطاع التلقائي للحصالة الذكية إن وُجد هدف نشط
    double piggyCut = 0.0;
    try {
      piggyCut = await PiggyBankService.applyAutoSaveOnPayment(
        userId: senderId,
        paymentAmount: amount,
      );
    } catch (e) {
      debugPrint("Piggy auto-save error on direct transfer (ignored): $e");
    }
    return piggyCut;
  }
}
