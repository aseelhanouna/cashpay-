import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../core/stats_service.dart';

class StatsPage extends StatefulWidget {
  final int userId;
  const StatsPage({super.key, required this.userId});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  static const Color primaryColor = Color(0xFF001F3F);

  bool _loading = true;
  List<Map<String, dynamic>> _monthly = [];
  Map<String, double> _indicator = {'sent': 0, 'received': 0, 'saved': 0, 'rate': 0};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final monthly = await StatsService.getMonthlyTotals(widget.userId, months: 6);
    final indicator = await StatsService.getSavingsIndicator(widget.userId);
    if (!mounted) return;
    setState(() {
      _monthly = monthly;
      _indicator = indicator;
      _loading = false;
    });
  }

  String _shortMonth(String ym) {
    // ym بصيغة YYYY-MM
    const names = [
      "", "يناير", "فبراير", "مارس", "أبريل", "مايو", "يونيو",
      "يوليو", "أغسطس", "سبتمبر", "أكتوبر", "نوفمبر", "ديسمبر"
    ];
    final parts = ym.split('-');
    if (parts.length != 2) return ym;
    final m = int.tryParse(parts[1]) ?? 0;
    return m >= 1 && m <= 12 ? names[m] : ym;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text("الإحصائيات المالية"),
        backgroundColor: primaryColor,
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
                    _buildSavingsIndicator(),
                    const SizedBox(height: 28),
                    const Text(
                      "الإرسال والاستلام خلال آخر 6 أشهر",
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                    _buildMonthlyChart(),
                    const SizedBox(height: 24),
                    _buildLegend(),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildSavingsIndicator() {
    final rate = _indicator['rate'] ?? 0;
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: primaryColor,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            height: 80,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: rate / 100,
                  strokeWidth: 8,
                  backgroundColor: Colors.white24,
                  valueColor: const AlwaysStoppedAnimation(Colors.amberAccent),
                ),
                Text(
                  "${rate.toStringAsFixed(0)}٪",
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                ),
              ],
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("مؤشر الادخار هذا الشهر",
                    style: TextStyle(color: Colors.white70, fontSize: 13)),
                const SizedBox(height: 6),
                Text(
                  "وفرت ${(_indicator['saved'] ?? 0).toStringAsFixed(2)} ₪ بالحصالة",
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                ),
                const SizedBox(height: 4),
                Text(
                  "من إجمالي ${(_indicator['received'] ?? 0).toStringAsFixed(2)} ₪ دخل هذا الشهر",
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMonthlyChart() {
    if (_monthly.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Text("لا توجد بيانات كافية بعد لعرض الرسم البياني",
              style: TextStyle(color: Colors.grey)),
        ),
      );
    }

    double maxVal = 10;
    for (final m in _monthly) {
      final sent = (m['sent'] as num).toDouble();
      final received = (m['received'] as num).toDouble();
      if (sent > maxVal) maxVal = sent;
      if (received > maxVal) maxVal = received;
    }
    maxVal *= 1.2;

    return SizedBox(
      height: 240,
      child: BarChart(
        BarChartData(
          maxY: maxVal,
          alignment: BarChartAlignment.spaceAround,
          borderData: FlBorderData(show: false),
          gridData: const FlGridData(show: false),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                return BarTooltipItem(
                  rod.toY.toStringAsFixed(1),
                  const TextStyle(color: Colors.white, fontSize: 11),
                );
              },
            ),
          ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (value, meta) {
                  final idx = value.toInt();
                  if (idx < 0 || idx >= _monthly.length) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(_shortMonth(_monthly[idx]['month'] as String),
                        style: const TextStyle(fontSize: 10)),
                  );
                },
              ),
            ),
          ),
          barGroups: List.generate(_monthly.length, (i) {
            final sent = (_monthly[i]['sent'] as num).toDouble();
            final received = (_monthly[i]['received'] as num).toDouble();
            return BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                    toY: sent, color: Colors.redAccent, width: 8,
                    borderRadius: BorderRadius.circular(4)),
                BarChartRodData(
                    toY: received, color: Colors.green, width: 8,
                    borderRadius: BorderRadius.circular(4)),
              ],
            );
          }),
        ),
      ),
    );
  }

  Widget _buildLegend() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _legendDot(Colors.redAccent, "مُرسل"),
        const SizedBox(width: 20),
        _legendDot(Colors.green, "مُستلم"),
      ],
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 13)),
      ],
    );
  }
}
