import 'dart:async';
import 'package:flutter/material.dart';
import 'models/workflow_models.dart';
import 'services/api_service.dart';

void main() {
  runApp(const ZionetWorkflowApp());
}

class ZionetWorkflowApp extends StatelessWidget {
  const ZionetWorkflowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZioNet AI Workflow Portal',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.indigo,
          brightness: Brightness.light,
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final ApiService _apiService = ApiService();

  // Form Controllers
  final TextEditingController _vendorController = TextEditingController(text: 'RackSpace Supplies');
  final TextEditingController _totalController = TextEditingController(text: '9500.00');
  final TextEditingController _descController = TextEditingController(text: 'Server rack components.');
  bool _hasReceipt = true;

  // Tracker State
  final TextEditingController _trackingIdController = TextEditingController();
  WorkflowState? _currentState;
  bool _isSubmitting = false;
  bool _isPolling = false;
  String _errorMessage = '';
  Timer? _autoRefreshTimer;

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _vendorController.dispose();
    _totalController.dispose();
    _descController.dispose();
    _trackingIdController.dispose();
    super.dispose();
  }

  // --- Actions ---

  Future<void> _submitInvoice() async {
    final double? total = double.tryParse(_totalController.text.trim());
    if (total == null || _vendorController.text.trim().isEmpty) {
      setState(() => _errorMessage = 'Please enter a valid vendor name and total amount.');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = '';
      _currentState = null;
    });

    final submission = InvoiceSubmission(
      vendor: _vendorController.text.trim(),
      total: total,
      description: _descController.text.trim(),
    );

    final trackingId = await _apiService.submitInvoice(submission);

    if (trackingId != null) {
      _trackingIdController.text = trackingId;
      await _fetchState(trackingId);
      _startAutoRefresh(trackingId);
    } else {
      setState(() => _errorMessage = 'Failed to submit invoice. Is the backend running?');
    }

    setState(() => _isSubmitting = false);
  }

  Future<void> _fetchState(String trackingId) async {
    if (trackingId.trim().isEmpty) return;
    setState(() => _isPolling = true);

    final state = await _apiService.getInvoiceState(trackingId.trim());
    setState(() {
      _currentState = state;
      _isPolling = false;
      if (state == null) {
        _errorMessage = 'Tracking ID not found in Redis.';
      }
    });
  }

  void _startAutoRefresh(String trackingId) {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_currentState?.status == 'PENDING' || _currentState?.status == 'UNKNOWN') {
        await _fetchState(trackingId);
      } else {
        timer.cancel(); // Stop polling once AI routes it or Saga completes
      }
    });
  }

  Future<void> _executeHitlAction(String action) async {
    if (_currentState == null) return;
    setState(() => _isPolling = true);

    final updatedState = await _apiService.executeAction(
      _currentState!.id,
      action,
      'Manager override executed via Flutter UI ($action).',
    );

    if (updatedState != null) {
      setState(() => _currentState = updatedState);
      // If approved, poll briefly to watch the Saga Payment Service execute
      if (action == 'APPROVE') {
        Timer(const Duration(seconds: 2), () => _fetchState(_currentState!.id));
      }
    } else {
      setState(() => _errorMessage = 'HITL action failed. Check container logs.');
      setState(() => _isPolling = false);
    }
  }

  void _applyPreset(String vendor, String total, String desc) {
    _vendorController.text = vendor;
    _totalController.text = total;
    _descController.text = desc;
  }

  // --- UI Helpers ---

  Color _getStatusColor(String status) {
    switch (status) {
      case 'APPROVED':
        return Colors.green;
      case 'PENDING_HUMAN_REVIEW':
        return Colors.amber.shade800;
      case 'PAYMENT_FAILED':
      case 'REJECTED':
        return Colors.red;
      case 'DUPLICATE_DISCARDED':
        return Colors.orange;
      default:
        return Colors.blue;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.hub, color: Colors.indigo),
            SizedBox(width: 10),
            Text('ZioNet AI Microservice Portal', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.surfaceVariant,
        elevation: 1,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              children: [
                if (_errorMessage.isNotEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      border: Border.all(color: Colors.red.shade300),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(_errorMessage, style: TextStyle(color: Colors.red.shade900)),
                  ),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Left Panel: Submission Form
                      Expanded(
                        flex: 5,
                        child: _buildSubmissionCard(),
                      ),
                      const SizedBox(width: 24),
                      // Right Panel: Live Inspector & HITL Actions
                      Expanded(
                        flex: 6,
                        child: _buildInspectorCard(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSubmissionCard() {
  return Card(
    elevation: 2,
    child: Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        mainAxisSize: MainAxisSize.min, // Prevents unbounded layout errors
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '1. Submit New Invoice',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const Divider(),
          const SizedBox(height: 8),

          // 1. Quick Presets Section (Label + Chips grouped together)
          const Text(
            'Quick Presets:',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8, // Handles clean spacing if chips wrap to line 2
            children: [
              ActionChip(
                label: const Text('💥 Saga Rollback (\$9,500 RackSpace)'),
                onPressed: () => _applyPreset(
                  'RackSpace Supplies',
                  '9500.00',
                  'Server rack components.',
                ),
              ),
              ActionChip(
                label: const Text('✅ Auto-Approve (\$150 Office)'),
                onPressed: () => _applyPreset(
                  'Staples Office Depot',
                  '150.00',
                  'Printer paper and pens.',
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // 2. Core Invoice Input Fields
          TextField(
            controller: _vendorController,
            decoration: const InputDecoration(
              labelText: 'Vendor Name',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.store),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _totalController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Total Amount (\$ USD)',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.attach_money),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _descController,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Description / Notes',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.description),
            ),
          ),
          const SizedBox(height: 12),

          // 3. Receipt Verification Toggle
          SwitchListTile(
            contentPadding: EdgeInsets.zero, // Aligns flush with TextFields
            title: const Text(
              'Receipt Attached / Verified',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
            ),
            subtitle: Text(
              _hasReceipt
                  ? 'Will pass receipt policy check'
                  : 'Will flag missing receipt violation',
              style: const TextStyle(fontSize: 12),
            ),
            value: _hasReceipt,
            onChanged: (val) => setState(() => _hasReceipt = val),
            secondary: Icon(
              _hasReceipt ? Icons.receipt_long : Icons.no_sim,
              color: _hasReceipt ? Colors.green : Colors.grey,
            ),
          ),
          const SizedBox(height: 20),

          // 4. Action Button
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton.icon(
              onPressed: _isSubmitting ? null : _submitInvoice,
              icon: _isSubmitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.send),
              label: Text(
                _isSubmitting
                    ? 'Submitting to C# Engine...'
                    : 'Submit Invoice to Workflow',
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

  Widget _buildInspectorCard() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('2. Live Tracker & Manager Override', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const Divider(),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _trackingIdController,
                    decoration: const InputDecoration(
                      labelText: 'Tracking ID (Guid)',
                      hintText: 'Enter invoice UUID...',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: () => _fetchState(_trackingIdController.text),
                  icon: _isPolling ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh),
                  tooltip: 'Query Redis State',
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _currentState == null
                  ? const Center(child: Text('Submit an invoice or enter a Tracking ID above to view live microservice state.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
                  : _buildStateDetails(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStateDetails() {
    final state = _currentState!;
    final statusColor = _getStatusColor(state.status);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(color: statusColor.withOpacity(0.1), border: Border.all(color: statusColor), borderRadius: BorderRadius.circular(8)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('STATUS: ${state.status}', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: statusColor)),
                Icon(Icons.circle, color: statusColor, size: 14),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (state.violations.isNotEmpty) ...[
            const Text('AI Policy Violations Flagged:', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              children: state.violations.map((v) => Chip(label: Text(v, style: const TextStyle(fontSize: 11)), backgroundColor: Colors.red.shade50, side: BorderSide(color: Colors.red.shade200))).toList(),
            ),
            const SizedBox(height: 12),
          ],
          const Text('Decision Reason / Notes:', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(top: 4, bottom: 16),
            decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(6)),
            child: Text(state.reason.isEmpty ? 'No notes provided.' : state.reason, style: const TextStyle(fontFamily: 'monospace')),
          ),
          // HITL Dashboard Actions
          if (state.status == 'PENDING_HUMAN_REVIEW') ...[
            const Divider(),
            const Text('⚠️ Human-in-the-Loop Intervention Required', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.amber)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Colors.green),
                    onPressed: () => _executeHitlAction('APPROVE'),
                    icon: const Icon(Icons.check),
                    label: const Text('Approve (& Trigger Payment Saga)'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: Colors.red),
                    onPressed: () => _executeHitlAction('REJECT'),
                    icon: const Icon(Icons.close),
                    label: const Text('Reject Invoice'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}