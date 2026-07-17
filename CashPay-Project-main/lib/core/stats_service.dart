import '../data/database_helper.dart';

/// خدمة الإحصائيات: تجميع بيانات الإرسال/الاستلام/الادخار شهرياً لعرضها
/// بالرسوم البيانية ومؤشر الادخار بالداشبورد.
class StatsService {
  /// بيانات آخر [months] شهراً: كل عنصر فيه الشهر، مجموع المُرسل، مجموع المُستلم
  static Future<List<Map<String, dynamic>>> getMonthlyTotals(int userId,
      {int months = 6}) {
    return DatabaseHelper.instance.getMonthlyTotals(userId, months: months);
  }

  /// ملخص الشهر الحالي + نسبة الادخار (المدَّخر ÷ الداخل) كمؤشر مئوي
  static Future<Map<String, double>> getSavingsIndicator(int userId) async {
    final summary =
        await DatabaseHelper.instance.getCurrentMonthSummary(userId);
    final double received = summary['received'] ?? 0.0;
    final double sent = summary['sent'] ?? 0.0;
    final double saved = summary['saved'] ?? 0.0;

    // نسبة الادخار: كم بالمية من الداخل (الرصيد المستلم) تم توفيره بالحصالة.
    // إذا ما دخل شيء هالشهر، نحسب النسبة نسبة للمصروف كتقريب معقول.
    final double base = received > 0 ? received : sent;
    final double rate = base > 0 ? (saved / base * 100).clamp(0, 100) : 0;

    return {
      'sent': sent,
      'received': received,
      'saved': saved,
      'rate': rate,
    };
  }
}
