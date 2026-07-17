import 'package:flutter/foundation.dart';
import '../data/database_helper.dart';

/// خدمة الحصالة الذكية: إدارة الأهداف، الاستقطاع التلقائي بالنسبة المئوية،
/// وتحديد متى يستحق المستخدم شارة جديدة.
class PiggyBankService {
  // مفاتيح الشارات المدعومة حالياً
  static const String badgeConsistentSaver = "consistent_saver"; // المتدخر المستمر
  static const String badgeFirstGoal = "first_goal"; // أول هدف ادخار
  static const String badgeGoalReached = "goal_reached"; // تحقيق الهدف

  /// يُستدعى بعد كل عملية دفع/تحويل ناجحة من المرسل.
  /// إذا كان لديه هدف نشط بطريقة "نسبة مئوية"، يُقتطع مبلغ إضافي تلقائياً
  /// من رصيده ويُضاف للحصالة (خصم إضافي منفصل عن مبلغ التحويل نفسه).
  ///
  /// يعيد المبلغ الذي تم اقتطاعه للحصالة (0 إن لم يوجد هدف نشط بهذه الطريقة).
  static Future<double> applyAutoSaveOnPayment({
    required int userId,
    required double paymentAmount,
  }) async {
    final db = DatabaseHelper.instance;
    final goal = await db.getActivePiggyGoal(userId);
    if (goal == null) return 0.0;

    final double percentage = (goal['percentage'] as num).toDouble();
    if (percentage <= 0) return 0.0;

    final double cut = double.parse(
        (paymentAmount * percentage / 100).toStringAsFixed(2));
    if (cut <= 0) return 0.0;

    final double balance = await db.getUserBalance(userId);
    // لا نقتطع إذا كان الرصيد لا يكفي بعد دفع المبلغ الأساسي + نسبة الحصالة
    if (balance < cut) {
      debugPrint("Piggy auto-save skipped: insufficient balance for cut");
      return 0.0;
    }

    await db.updateBalance(userId, -cut);
    await db.depositToPiggy(
      goalId: goal['id'] as int,
      userId: userId,
      amount: cut,
      source: 'auto_percentage',
    );

    await _checkAndAwardBadges(userId, goal['id'] as int);
    return cut;
  }

  /// إيداع يدوي في الهدف النشط (أو هدف محدد) من رصيد المستخدم مباشرة
  static Future<void> manualDeposit({
    required int userId,
    required int goalId,
    required double amount,
  }) async {
    final db = DatabaseHelper.instance;
    final balance = await db.getUserBalance(userId);
    if (amount <= 0) throw Exception("أدخل مبلغاً صحيحاً");
    if (amount > balance) throw Exception("رصيدك الحالي لا يكفي");

    await db.updateBalance(userId, -amount);
    await db.depositToPiggy(
      goalId: goalId,
      userId: userId,
      amount: amount,
      source: 'manual',
    );
    await _checkAndAwardBadges(userId, goalId);
  }

  /// "خلي الفكة" - يُعرض بعد شحن الرصيد: تحويل مبلغ ثابت مباشرة للهدف
  static Future<void> keepTheChange({
    required int userId,
    required int goalId,
    required double amount,
  }) async {
    final db = DatabaseHelper.instance;
    final balance = await db.getUserBalance(userId);
    if (amount > balance) throw Exception("المبلغ أكبر من الرصيد المتاح");

    await db.updateBalance(userId, -amount);
    await db.depositToPiggy(
      goalId: goalId,
      userId: userId,
      amount: amount,
      source: 'keep_change',
    );
    await _checkAndAwardBadges(userId, goalId);
  }

  /// إنشاء هدف جديد، ومنح شارة "أول هدف" إن كانت أول مرة
  static Future<int> createGoal({
    required int userId,
    required String name,
    required double targetAmount,
    String? targetDate,
    double percentage = 0,
  }) async {
    final db = DatabaseHelper.instance;
    final id = await db.createPiggyGoal(
      userId: userId,
      name: name,
      targetAmount: targetAmount,
      targetDate: targetDate,
      percentage: percentage,
    );
    await db.awardBadgeIfNew(userId, badgeFirstGoal);
    return id;
  }

  static Future<void> _checkAndAwardBadges(int userId, int goalId) async {
    final db = DatabaseHelper.instance;

    // شارة "المتدخر المستمر": ادخار في 4 أيام مختلفة على الأقل خلال آخر 30 يوم
    final distinctDays = await db.countDistinctSavingDays(userId, days: 30);
    if (distinctDays >= 4) {
      await db.awardBadgeIfNew(userId, badgeConsistentSaver);
    }

    // شارة "تحقيق الهدف": الوصول أو تجاوز الهدف المطلوب
    final goals = await db.getAllPiggyGoals(userId);
    final active = goals.firstWhere(
      (g) => g['id'] == goalId,
      orElse: () => {},
    );
    if (active.isNotEmpty) {
      final double saved = (active['saved_amount'] as num).toDouble();
      final double target = (active['target_amount'] as num).toDouble();
      if (target > 0 && saved >= target) {
        await db.awardBadgeIfNew(userId, badgeGoalReached);
      }
    }
  }

  /// اسم عرض ورمز تعبيري لكل شارة (تُستخدم بالواجهة)
  static Map<String, String> badgeMeta(String key) {
    switch (key) {
      case badgeConsistentSaver:
        return {"title": "المتدخر المستمر", "emoji": "🔥"};
      case badgeFirstGoal:
        return {"title": "أول خطوة", "emoji": "🌱"};
      case badgeGoalReached:
        return {"title": "حقق الهدف", "emoji": "🏆"};
      default:
        return {"title": key, "emoji": "⭐"};
    }
  }
}
