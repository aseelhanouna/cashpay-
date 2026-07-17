import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../data/database_helper.dart';
import '../core/piggy_bank_service.dart';

class PiggyBankPage extends StatefulWidget {
  final int userId;
  const PiggyBankPage({super.key, required this.userId});

  @override
  State<PiggyBankPage> createState() => _PiggyBankPageState();
}

class _PiggyBankPageState extends State<PiggyBankPage> {
  static const Color primaryColor = Color(0xFF001F3F);

  Map<String, dynamic>? _goal;
  List<Map<String, dynamic>> _log = [];
  List<Map<String, dynamic>> _badges = [];
  double _balance = 0.0;
  bool _loading = true;
  int _coinBurst = 0; // يزيد رقمه لتشغيل أنيميشن سقوط عملة جديدة

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final db = DatabaseHelper.instance;
    final goal = await db.getActivePiggyGoal(widget.userId);
    final balance = await db.getUserBalance(widget.userId);
    final badges = await db.getUserBadges(widget.userId);
    List<Map<String, dynamic>> log = [];
    if (goal != null) {
      log = await db.getPiggyLog(goal['id'] as int);
    }
    if (!mounted) return;
    setState(() {
      _goal = goal;
      _balance = balance;
      _badges = badges;
      _log = log;
      _loading = false;
    });
  }

  Future<void> _createGoalDialog() async {
    final nameCtrl = TextEditingController();
    final targetCtrl = TextEditingController();
    final percentCtrl = TextEditingController(text: "5");
    DateTime? pickedDate;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text("هدف ادخار جديد"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: "اسم الهدف (مثال: لابتوب جديد)",
                    prefixIcon: Icon(Icons.flag),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: targetCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: "المبلغ المستهدف (₪)",
                    prefixIcon: Icon(Icons.attach_money),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: percentCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: "نسبة الاستقطاع التلقائي من كل عملية دفع (%)",
                    prefixIcon: Icon(Icons.percent),
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_today),
                  title: Text(pickedDate == null
                      ? "اختر تاريخاً مستهدفاً (اختياري)"
                      : "${pickedDate!.year}/${pickedDate!.month}/${pickedDate!.day}"),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: DateTime.now().add(const Duration(days: 30)),
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 3650)),
                    );
                    if (picked != null) {
                      setDialogState(() => pickedDate = picked);
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("إلغاء"),
            ),
            ElevatedButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                final target = double.tryParse(targetCtrl.text.trim()) ?? 0;
                final percent = double.tryParse(percentCtrl.text.trim()) ?? 0;
                if (name.isEmpty || target <= 0) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text("أدخل اسم الهدف والمبلغ المستهدف")));
                  return;
                }
                await PiggyBankService.createGoal(
                  userId: widget.userId,
                  name: name,
                  targetAmount: target,
                  targetDate: pickedDate?.toIso8601String(),
                  percentage: percent.clamp(0, 100),
                );
                if (ctx.mounted) Navigator.pop(ctx);
                _load();
              },
              child: const Text("إنشاء"),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _manualAction({required bool isDeposit}) async {
    if (_goal == null) return;
    final ctrl = TextEditingController();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isDeposit ? "إيداع في الحصالة" : "سحب من الحصالة"),
        content: TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: "المبلغ (₪)"),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text("إلغاء")),
          ElevatedButton(
            onPressed: () async {
              final amount = double.tryParse(ctrl.text.trim()) ?? 0;
              try {
                if (isDeposit) {
                  await PiggyBankService.manualDeposit(
                    userId: widget.userId,
                    goalId: _goal!['id'] as int,
                    amount: amount,
                  );
                } else {
                  await DatabaseHelper.instance.withdrawFromPiggy(
                    goalId: _goal!['id'] as int,
                    userId: widget.userId,
                    amount: amount,
                  );
                }
                if (ctx.mounted) Navigator.pop(ctx);
                setState(() => _coinBurst++);
                _load();
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                      content:
                          Text(e.toString().replaceFirst("Exception: ", ""))));
                }
              }
            },
            child: const Text("تأكيد"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text("الحصالة الذكية"),
        backgroundColor: primaryColor,
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: "هدف جديد",
            onPressed: _createGoalDialog,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_goal == null) _buildEmptyState() else _buildGoalCard(),
                    const SizedBox(height: 28),
                    _buildBadgesSection(),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildEmptyState() {
    return Container(
      padding: const EdgeInsets.all(30),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        children: [
          const Icon(Icons.savings, size: 70, color: primaryColor),
          const SizedBox(height: 15),
          const Text(
            "ما عندك هدف ادخار بعد",
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            "أنشئ هدفاً (مثلاً لابتوب أو رحلة) وحدد نسبة تُقتطع تلقائياً من كل عملية دفع",
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: _createGoalDialog,
            icon: const Icon(Icons.add),
            label: const Text("إنشاء هدف ادخار"),
          ),
        ],
      ),
    );
  }

  Widget _buildGoalCard() {
    final double saved = (_goal!['saved_amount'] as num).toDouble();
    final double target = (_goal!['target_amount'] as num).toDouble();
    final double percentage = (_goal!['percentage'] as num).toDouble();
    final double progress = target > 0 ? (saved / target).clamp(0, 1) : 0;

    return Column(
      children: [
        Text(
          _goal!['name'] as String,
          style: const TextStyle(
              fontSize: 20, fontWeight: FontWeight.bold, color: primaryColor),
        ),
        const SizedBox(height: 6),
        Text(
          "${saved.toStringAsFixed(2)} ₪ من ${target.toStringAsFixed(2)} ₪",
          style: const TextStyle(color: Colors.grey, fontSize: 14),
        ),
        const SizedBox(height: 20),
        _buildJar(progress),
        const SizedBox(height: 20),
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: LinearProgressIndicator(
            value: progress.toDouble(),
            minHeight: 12,
            backgroundColor: Colors.grey.shade200,
            valueColor: const AlwaysStoppedAnimation(primaryColor),
          ),
        ),
        const SizedBox(height: 6),
        Text("${(progress * 100).toStringAsFixed(0)}٪ من الهدف",
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
        if (percentage > 0) ...[
          const SizedBox(height: 14),
          Chip(
            avatar: const Icon(Icons.autorenew, size: 18, color: Colors.white),
            label: Text("استقطاع تلقائي ${percentage.toStringAsFixed(0)}٪ من كل دفعة"),
            backgroundColor: primaryColor,
            labelStyle: const TextStyle(color: Colors.white),
          ),
        ],
        const SizedBox(height: 22),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _manualAction(isDeposit: true),
                icon: const Icon(Icons.add_circle_outline),
                label: const Text("إيداع"),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _manualAction(isDeposit: false),
                icon: const Icon(Icons.remove_circle_outline),
                label: const Text("سحب"),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        TextButton.icon(
          onPressed: _createGoalDialog,
          icon: const Icon(Icons.flag_outlined),
          label: const Text("بدء هدف جديد بدلاً منه"),
        ),
        const SizedBox(height: 10),
        if (_log.isNotEmpty) _buildRecentLog(),
      ],
    );
  }

  Widget _buildRecentLog() {
    return Align(
      alignment: Alignment.centerRight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text("آخر الحركات", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          ..._log.take(6).map((entry) {
            final amount = (entry['amount'] as num).toDouble();
            final isPositive = amount >= 0;
            final source = entry['source'] as String;
            String label;
            switch (source) {
              case 'auto_percentage':
                label = "استقطاع تلقائي";
                break;
              case 'keep_change':
                label = "خلي الفكة";
                break;
              case 'withdraw':
                label = "سحب";
                break;
              default:
                label = "إيداع يدوي";
            }
            return ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: Icon(
                isPositive ? Icons.arrow_downward : Icons.arrow_upward,
                color: isPositive ? Colors.green : Colors.red,
                size: 18,
              ),
              title: Text(label, style: const TextStyle(fontSize: 13)),
              trailing: Text(
                "${isPositive ? '+' : ''}${amount.toStringAsFixed(2)} ₪",
                style: TextStyle(
                  color: isPositive ? Colors.green : Colors.red,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildBadgesSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("الشارات", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        _badges.isEmpty
            ? const Text("لسا ما حصلت على شارات، استمر بالادخار!",
                style: TextStyle(color: Colors.grey))
            : Wrap(
                spacing: 12,
                runSpacing: 12,
                children: _badges.map((b) {
                  final meta = PiggyBankService.badgeMeta(b['badge_key'] as String);
                  return Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade50,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.amber.shade200),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(meta["emoji"]!, style: const TextStyle(fontSize: 20)),
                        const SizedBox(width: 6),
                        Text(meta["title"]!,
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ).animate().scale(duration: 300.ms);
                }).toList(),
              ),
      ],
    );
  }

  /// وعاء زجاجي بسيط برسم مخصص، مع "عملات" تتساقط بشكل عشوائي بحسب نسبة الادخار
  Widget _buildJar(double progress) {
    return SizedBox(
      height: 180,
      width: 160,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          CustomPaint(
            size: const Size(160, 180),
            painter: _JarPainter(fill: progress),
          ),
          ...List.generate(min(8, (progress * 8).ceil()), (i) {
            final rnd = Random(i + _coinBurst);
            return Positioned(
              bottom: 15 + rnd.nextInt(40).toDouble(),
              left: 40 + rnd.nextInt(70).toDouble(),
              child: const Text("🪙", style: TextStyle(fontSize: 18))
                  .animate()
                  .fadeIn(duration: 400.ms)
                  .moveY(begin: -60, end: 0, duration: 500.ms, curve: Curves.bounceOut),
            );
          }),
        ],
      ),
    );
  }
}

class _JarPainter extends CustomPainter {
  final double fill; // 0..1
  _JarPainter({required this.fill});

  @override
  void paint(Canvas canvas, Size size) {
    final glassPaint = Paint()
      ..color = Colors.blueGrey.withOpacity(0.15)
      ..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..color = Colors.blueGrey.shade300
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    final coinFillPaint = Paint()
      ..color = Colors.amber.withOpacity(0.85)
      ..style = PaintingStyle.fill;

    final jarRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(10, 20, size.width - 20, size.height - 30),
      const Radius.circular(24),
    );

    canvas.drawRRect(jarRect, glassPaint);
    canvas.drawRRect(jarRect, borderPaint);

    // غطاء الحصالة
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(size.width / 2 - 25, 4, 50, 18),
        const Radius.circular(6),
      ),
      Paint()..color = Colors.blueGrey.shade400,
    );

    // مستوى "المال" داخل الوعاء
    final fillHeight = (size.height - 34) * fill.clamp(0, 1);
    final fillRect = Rect.fromLTWH(
      13,
      size.height - 14 - fillHeight,
      size.width - 26,
      fillHeight,
    );
    canvas.save();
    canvas.clipRRect(jarRect);
    canvas.drawRect(fillRect, coinFillPaint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _JarPainter oldDelegate) =>
      oldDelegate.fill != fill;
}
