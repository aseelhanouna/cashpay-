import 'package:flutter/material.dart';
import '../data/database_helper.dart';
import '../services/direct_transfer_service.dart';

class DirectTransferPage extends StatefulWidget {
  final int userId;
  const DirectTransferPage({super.key, required this.userId});

  @override
  State<DirectTransferPage> createState() => _DirectTransferPageState();
}

class _DirectTransferPageState extends State<DirectTransferPage> {
  static const Color primaryColor = Color(0xFF001F3F);

  final _idController = TextEditingController();
  final _amountController = TextEditingController();

  double _currentBalance = 0.0;
  bool _isSearching = false;
  bool _isSending = false;
  DirectTransferRecipient? _recipient;
  String? _searchError;

  @override
  void initState() {
    super.initState();
    _loadBalance();
  }

  @override
  void dispose() {
    _idController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  Future<void> _loadBalance() async {
    final balance = await DatabaseHelper.instance.getUserBalance(widget.userId);
    if (mounted) setState(() => _currentBalance = balance);
  }

  Future<void> _searchRecipient() async {
    final idNumber = _idController.text.trim();
    if (idNumber.isEmpty) {
      _showError("أدخل رقم هوية المستقبل");
      return;
    }
    setState(() {
      _isSearching = true;
      _recipient = null;
      _searchError = null;
    });
    try {
      final result = await DirectTransferService.lookupByIdNumber(idNumber);
      if (result == null) {
        setState(() => _searchError = "لا يوجد مستخدم بهذا الرقم");
      } else {
        setState(() => _recipient = result);
      }
    } catch (e) {
      setState(() => _searchError = "تعذر البحث، تأكد من اتصال الإنترنت");
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  Future<void> _confirmAndSend() async {
    final amount = double.tryParse(_amountController.text.trim());
    if (amount == null || amount <= 0) {
      _showError("أدخل مبلغاً صحيحاً");
      return;
    }
    if (amount > _currentBalance) {
      _showError("رصيدك الحالي غير كافٍ");
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("تأكيد التحويل"),
        content: Text(
          "بدك تحول ${amount.toStringAsFixed(2)} ₪ إلى ${_recipient!.name}؟",
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text("إلغاء")),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text("تأكيد وإرسال")),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isSending = true);
    try {
      final piggyCut = await DirectTransferService.transfer(
        senderId: widget.userId,
        receiverIdNumber: _recipient!.idNumber,
        amount: amount,
      );
      if (!mounted) return;

      await _loadBalance();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(piggyCut > 0
              ? "تم التحويل بنجاح ✅ | 🐷 وُفّر ${piggyCut.toStringAsFixed(2)} ₪ بحصالتك"
              : "تم التحويل بنجاح ✅"),
          backgroundColor: Colors.green,
        ),
      );
      setState(() {
        _recipient = null;
        _idController.clear();
        _amountController.clear();
      });
    } catch (e) {
      _showError(e.toString().replaceFirst("Exception: ", ""));
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("تنبيه"),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text("حسناً")),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("تحويل مباشر بدون QR"),
        backgroundColor: primaryColor,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              color: Colors.blue.shade50,
              child: ListTile(
                leading: const Icon(Icons.account_balance_wallet, color: Colors.blue),
                title: const Text("رصيدك الحالي"),
                trailing: Text(
                  "${_currentBalance.toStringAsFixed(2)} ₪",
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              "⚠️ هذه العملية تحتاج اتصال إنترنت لأنها تتم مباشرة بدون رمز QR",
              style: TextStyle(color: Colors.orange, fontSize: 13),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _idController,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: "رقم هوية المستقبل",
                prefixIcon: const Icon(Icons.badge),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: _isSearching ? null : _searchRecipient,
                ),
              ),
              onSubmitted: (_) => _searchRecipient(),
            ),
            const SizedBox(height: 10),
            if (_isSearching) const Center(child: CircularProgressIndicator()),
            if (_searchError != null)
              Text(_searchError!, style: const TextStyle(color: Colors.red)),
            if (_recipient != null)
              Card(
                color: Colors.green.shade50,
                child: ListTile(
                  leading: const Icon(Icons.person, color: Colors.green),
                  title: Text(_recipient!.name,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text("رقم الهوية: ${_recipient!.idNumber}"),
                ),
              ),
            const SizedBox(height: 20),
            if (_recipient != null) ...[
              TextField(
                controller: _amountController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: "المبلغ",
                  prefixIcon: Icon(Icons.attach_money),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),
              _isSending
                  ? const Center(child: CircularProgressIndicator())
                  : ElevatedButton.icon(
                      icon: const Icon(Icons.send),
                      label: const Text("إرسال الآن"),
                      onPressed: _confirmAndSend,
                      style: ElevatedButton.styleFrom(
                          minimumSize: const Size.fromHeight(50)),
                    ),
            ],
          ],
        ),
      ),
    );
  }
}
