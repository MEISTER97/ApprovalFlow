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
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: Brightness.light),
      ),
      home: const MainPortalLayout(),
    );
  }
}

class MainPortalLayout extends StatefulWidget {
  const MainPortalLayout({super.key});

  @override
  State<MainPortalLayout> createState() => _MainPortalLayoutState();
}

class _MainPortalLayoutState extends State<MainPortalLayout> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.hub, color: Colors.indigo),
            SizedBox(width: 10),
            Text('ZioNet Enterprise', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.surfaceVariant,
        elevation: 1,
      ),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (int index) {
              setState(() {
                _selectedIndex = index;
              });
            },
            labelType: NavigationRailLabelType.all,
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.upload_file),
                selectedIcon: Icon(Icons.upload_file, color: Colors.indigo),
                label: Text('Submitter'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.fact_check),
                selectedIcon: Icon(Icons.fact_check, color: Colors.indigo),
                label: Text('Approver'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.account_balance),
                selectedIcon: Icon(Icons.account_balance, color: Colors.indigo),
                label: Text('Controller'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.policy),
                selectedIcon: Icon(Icons.policy, color: Colors.indigo),
                label: Text('Auditor'),
              ),
            ],
          ),
          const VerticalDivider(thickness: 1, width: 1),
          Expanded(
            child: _buildSelectedScreen(),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectedScreen() {
    switch (_selectedIndex) {
      case 0:
        return const SubmitterScreen();
      case 1:
        return const ApproverScreen();
      case 2:
        return const ControllerScreen();
      case 3:
        return const AuditorScreen();
      default:
        return const SubmitterScreen();
    }
  }
}

// ==========================================
// 1. SUBMITTER SCREEN (F1, F2, F3)
// ==========================================
class SubmitterScreen extends StatefulWidget {
  const SubmitterScreen({super.key});

  @override
  State<SubmitterScreen> createState() => _SubmitterScreenState();
}

class _SubmitterScreenState extends State<SubmitterScreen> {
  final ApiService _apiService = ApiService();

  final TextEditingController _vendorController = TextEditingController(
      text: 'RackSpace Supplies');
  final TextEditingController _totalController = TextEditingController(
      text: '9500.00');
  final TextEditingController _descController = TextEditingController(
      text: 'Server rack components.');

  bool _hasReceipt = true;
  String _selectedDept = 'engineering-2026Q2';
  String _selectedCategory = 'hardware';

  // Tracker & Anti-Double Submission State
  final TextEditingController _trackingIdController = TextEditingController();
  WorkflowState? _currentState;
  bool _isSubmitting = false;
  String _errorMessage = '';
  String? _lastSubmittedHash; // F3: Protect against duplicate double-clicks
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

  void _applyPreset(String vendor, String total, String desc, String dept,
      String cat, bool receipt) {
    setState(() {
      _vendorController.text = vendor;
      _totalController.text = total;
      _descController.text = desc;
      _selectedDept = dept;
      _selectedCategory = cat;
      _hasReceipt = receipt;
    });
  }

  Future<void> _submitInvoice() async {
    final double? total = double.tryParse(_totalController.text.trim());
    if (total == null || _vendorController.text
        .trim()
        .isEmpty) {
      setState(() =>
      _errorMessage = 'Please enter a valid vendor name and total amount.');
      return;
    }

    // F3 Requirement: Prevent an identical invoice from firing twice concurrently
    final currentPayloadHash = "${_vendorController.text
        .trim()}-$total-${_selectedDept}";
    if (currentPayloadHash == _lastSubmittedHash && _isSubmitting) {
      setState(() =>
      _errorMessage = 'Submission blocked: Duplicate click detected (F3).');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _errorMessage = '';
      _currentState = null;
      _lastSubmittedHash = currentPayloadHash;
    });

    // Building the exact submission object with all original fields
    final submission = InvoiceSubmission(
      vendor: _vendorController.text.trim(),
      total: total,
      description: _descController.text.trim(),
      receiptPresent: _hasReceipt,
      department: _selectedDept,
      category: _selectedCategory,
    );

    // Immediate acknowledgement / non-blocking delivery (F1)
    final trackingId = await _apiService.submitInvoice(submission);

    if (trackingId != null) {
      _trackingIdController.text = trackingId;
      await _fetchState(trackingId);
      _startAutoRefresh(trackingId);
    } else {
      setState(() =>
      _errorMessage =
      'Failed to submit invoice. Is the API Gateway gateway up?');
    }

    setState(() => _isSubmitting = false);
  }

  Future<void> _fetchState(String trackingId) async {
    if (trackingId
        .trim()
        .isEmpty) return;
    final state = await _apiService.getInvoiceState(trackingId.trim());
    setState(() {
      _currentState = state;
      if (state == null) {
        _errorMessage = 'Tracking ID not found in Redis.';
      }
    });
  }

  void _startAutoRefresh(String trackingId) {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer =
        Timer.periodic(const Duration(seconds: 2), (timer) async {
          if (_currentState?.status == 'PENDING' ||
              _currentState?.status == 'UNKNOWN' || _currentState == null) {
            await _fetchState(trackingId);
          } else {
            timer.cancel();
          }
        });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
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
              child: Text(
                  _errorMessage, style: TextStyle(color: Colors.red.shade900)),
            ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left Column: Original Submission Form
                Expanded(flex: 5, child: _buildFormCard()),
                const SizedBox(width: 24),
                // Right Column: Live Plain-Language Status Tracker
                Expanded(flex: 6, child: _buildTrackerCard()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFormCard() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('1. Submit New Invoice (F1, F3)',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const Divider(),
              const SizedBox(height: 8),
              const Text('Quick Presets:', style: TextStyle(fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ActionChip(
                    label: const Text('💥 Saga Rollback (\$9,500)'),
                    onPressed: () =>
                        _applyPreset('RackSpace Supplies', '9500.00',
                            'Server rack components.', 'engineering-2026Q2',
                            'hardware', true),
                  ),
                  ActionChip(
                    label: const Text('✅ Auto-Approve (\$42 Meal)'),
                    onPressed: () =>
                        _applyPreset(
                            'Bistro 19', '42.00', 'Team lunch meeting.',
                            'engineering-2026Q2', 'meals', true),
                  ),
                  ActionChip(
                    label: const Text('⚠️ Escalate (\$300 SaaS)'),
                    onPressed: () =>
                        _applyPreset(
                            'PixelForge', '300.00', 'Design tool license.',
                            'sales-2026Q2', 'saas', true),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _vendorController,
                decoration: const InputDecoration(labelText: 'Vendor Name',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.store)),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _totalController,
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true),
                decoration: const InputDecoration(
                    labelText: 'Total Amount (\$ USD)',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.attach_money)),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _selectedDept,
                      decoration: const InputDecoration(labelText: 'Department',
                          border: OutlineInputBorder()),
                      items: [
                        'engineering-2026Q2',
                        'sales-2026Q2',
                        'marketing-2026Q2'
                      ]
                          .map((d) =>
                          DropdownMenuItem(value: d, child: Text(
                              d, style: const TextStyle(fontSize: 13))))
                          .toList(),
                      onChanged: (v) => setState(() => _selectedDept = v!),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _selectedCategory,
                      decoration: const InputDecoration(
                          labelText: 'Category', border: OutlineInputBorder()),
                      items: ['hardware', 'meals', 'travel', 'saas', 'other']
                          .map((c) =>
                          DropdownMenuItem(value: c, child: Text(
                              c, style: const TextStyle(fontSize: 13))))
                          .toList(),
                      onChanged: (v) => setState(() => _selectedCategory = v!),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descController,
                maxLines: 2,
                decoration: const InputDecoration(
                    labelText: 'Description / Notes',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.description)),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Receipt Attached / Verified',
                    style: TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14)),
                subtitle: Text(_hasReceipt
                    ? 'Passes receipt verification check'
                    : 'Will trigger missing receipt violation',
                    style: const TextStyle(fontSize: 12)),
                value: _hasReceipt,
                onChanged: (val) => setState(() => _hasReceipt = val),
                secondary: Icon(_hasReceipt ? Icons.receipt_long : Icons.no_sim,
                    color: _hasReceipt ? Colors.green : Colors.grey),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton.icon(
                  onPressed: _isSubmitting ? null : _submitInvoice,
                  icon: _isSubmitting ? const SizedBox(width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2)) : const Icon(
                      Icons.send),
                  label: Text(_isSubmitting
                      ? 'Submitting to Engine...'
                      : 'Submit Invoice to Workflow'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // NEW state variable for the clarification text box
  final TextEditingController _clarificationController = TextEditingController();

  Widget _buildTrackerCard() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('2. Live Submission Status (F2)',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const Divider(),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _trackingIdController,
                    decoration: const InputDecoration(
                        labelText: 'Tracking ID (UUID)',
                        hintText: 'Tracking details will load automatically...',
                        isDense: true,
                        border: OutlineInputBorder()),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  onPressed: () => _fetchState(_trackingIdController.text),
                  icon: const Icon(Icons.search),
                  // Updated to a search/check icon!
                  tooltip: 'Check Status',
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _currentState == null
                  ? const Center(child: Text(
                  'Fill the form and submit to monitor your transaction status in real-time.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey)))
                  : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Dynamic Status Banner
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: _currentState!.status == 'PENDING_MORE_INFO'
                          ? Colors.purple.shade50
                          : Colors.indigo.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                          color: _currentState!.status == 'PENDING_MORE_INFO'
                              ? Colors.purple.shade200
                              : Colors.indigo.shade200),
                    ),
                    child: Text(
                      'STATUS: ${_currentState!.status}',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: _currentState!.status == 'PENDING_MORE_INFO'
                              ? Colors.purple
                              : Colors.indigo
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Mini-Receipt (Payload data)
                  if (_currentState!.payload != null) ...[
                    const Text('Receipt Details:', style: TextStyle(
                        fontWeight: FontWeight.bold, color: Colors.grey)),
                    const SizedBox(height: 4),
                    Text('Vendor: ${_currentState!
                        .payload!['vendor']} | Dept: ${_currentState!
                        .payload!['department']} | Cat: ${_currentState!
                        .payload!['category']}',
                        style: const TextStyle(fontSize: 12)),
                    Text('Desc: ${_currentState!.payload!['description']}',
                        style: const TextStyle(
                            fontSize: 12, fontStyle: FontStyle.italic)),
                    const SizedBox(height: 16),
                  ],

                  const Text('Outcome Reasoning / Notes:', style: TextStyle(
                      fontWeight: FontWeight.bold, color: Colors.grey)),
                  const SizedBox(height: 4),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(6)),
                    child: Text(
                      _currentState!.reason.isEmpty
                          ? 'Processing outcome reasoning...'
                          : _currentState!.reason,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 13),
                    ),
                  ),

                  // NEW: Actionable Reply Box for PENDING_MORE_INFO
                  if (_currentState!.status == 'PENDING_MORE_INFO') ...[
                    const SizedBox(height: 16),
                    const Divider(),
                    const Text('Action Required:', style: TextStyle(
                        fontWeight: FontWeight.bold, color: Colors.purple)),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _clarificationController,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        hintText: 'Type your clarification here...',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                          backgroundColor: Colors.purple),
                      onPressed: () async {
                        bool success = await _apiService.submitClarification(
                            _currentState!.id, _clarificationController.text);
                        if (success) {
                          _clarificationController.clear();
                          await _fetchState(_currentState!
                              .id); // Refresh to see it go back to PENDING_HUMAN_REVIEW
                        }
                      },
                      icon: const Icon(Icons.send),
                      label: const Text('Send back to Manager'),
                    ),
                  ]

                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
// ==========================================
// 2. APPROVER SCREEN (F4, F5, F6)
// ==========================================
class ApproverScreen extends StatefulWidget {
  const ApproverScreen({super.key});

  @override
  State<ApproverScreen> createState() => _ApproverScreenState();
}

class _ApproverScreenState extends State<ApproverScreen> {
  final ApiService _apiService = ApiService();
  List<WorkflowState> _escalationQueue = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchQueue();
  }

  Future<void> _fetchQueue() async {
    setState(() => _isLoading = true);

    // Fetch from backend
    final items = await _apiService.getEscalatedInvoices();

    setState(() {
      // F6: Ensure we NEVER show auto-approved items here, just to be strictly safe
      _escalationQueue = items.where((item) =>
        item.status == 'PENDING_HUMAN_REVIEW' ||
        item.status == 'PENDING_MORE_INFO'
      ).toList();
      _isLoading = false;
    });
  }

  Future<void> _handleManagerAction(String trackingId, String action) async {
    setState(() => _isLoading = true);

    String notes = action == 'APPROVE'
        ? 'Manager approved via UI override.'
        : action == 'SEND_BACK'
            ? 'Manager requested itemized details.'
            : 'Manager rejected invoice.';

    // F5: One click to execute and resume the workflow
    final updatedState = await _apiService.executeAction(trackingId, action, notes);

    if (updatedState != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Action $action applied to $trackingId'), backgroundColor: Colors.green),
      );
      // Refresh the queue (this item should now be gone!)
      await _fetchQueue();
    } else {
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Action failed. Check API logs.'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Escalation Queue (F4, F6)', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                  Text('Only items requiring manual review appear here.', style: TextStyle(color: Colors.grey)),
                ],
              ),
              FilledButton.tonalIcon(
                onPressed: _fetchQueue,
                icon: _isLoading
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh),
                label: const Text('Refresh Queue'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(),
          const SizedBox(height: 16),
          Expanded(
            child: _isLoading && _escalationQueue.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : _escalationQueue.isEmpty
                    ? const Center(
                        child: Text(
                          '🎉 Inbox Zero!\nAll items handled autonomously by AI.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey, fontSize: 18),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _escalationQueue.length,
                        itemBuilder: (context, index) {
                          final item = _escalationQueue[index];
                          return _buildQueueItem(item);
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildQueueItem(WorkflowState item) {
    // Extract basic info from the payload if it exists
    final vendor = item.payload?['vendor'] ?? 'Unknown Vendor';
    final total = item.payload?['total'] ?? 0.0;
    final conf = item.confidence != null ? (item.confidence! * 100).toStringAsFixed(1) : 'N/A';

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: Colors.amber.shade300)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: Vendor and Total
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  vendor.toString(),
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                Text(
                  '\$$total',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.indigo),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('Tracking ID: ${item.id}', style: const TextStyle(fontSize: 12, fontFamily: 'monospace', color: Colors.grey)),
            const SizedBox(height: 12),

            // F4: AI Recommendation & Violations
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.grey.shade50, borderRadius: BorderRadius.circular(8)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.smart_toy, size: 16, color: Colors.indigo),
                      const SizedBox(width: 8),
                      Text('AI Confidence: $conf%', style: const TextStyle(fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text('Reason for Escalation:', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
                  Text(item.reason, style: const TextStyle(fontSize: 13)),

                  if (item.violations.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    const Text('Policy Flags:', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: Colors.red)),
                    Wrap(
                      spacing: 6,
                      children: item.violations.map((v) => Chip(
                        label: Text(v, style: const TextStyle(fontSize: 10)),
                        backgroundColor: Colors.red.shade50,
                        padding: EdgeInsets.zero,
                      )).toList(),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),

            // F5: Action Buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _handleManagerAction(item.id, 'SEND_BACK'),
                  icon: const Icon(Icons.reply, color: Colors.purple),
                  label: const Text('Request Info', style: TextStyle(color: Colors.purple)),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => _handleManagerAction(item.id, 'REJECT'),
                  icon: const Icon(Icons.close, color: Colors.red),
                  label: const Text('Reject', style: TextStyle(color: Colors.red)),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: Colors.green),
                  onPressed: () => _handleManagerAction(item.id, 'APPROVE'),
                  icon: const Icon(Icons.check),
                  label: const Text('Approve'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================
// 3. CONTROLLER SCREEN (F7, F8)
// ==========================================
class ControllerScreen extends StatefulWidget {
  const ControllerScreen({super.key});

  @override
  State<ControllerScreen> createState() => _ControllerScreenState();
}

class _ControllerScreenState extends State<ControllerScreen> {
  final ApiService _apiService = ApiService();
  final TextEditingController _policyController = TextEditingController();
  Map<String, dynamic>? _metrics;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchDashboardData();
  }

  Future<void> _fetchDashboardData() async {
    setState(() => _isLoading = true);
    final metrics = await _apiService.getDashboardMetrics();


    final policy = await _apiService.getPolicyMarkdown() ?? "## Autonomy Thresholds\n\n- MAX_AUTO_APPROVE: 250.00\n- MEALS_PER_HEAD: 75.00";

    setState(() {
      _metrics = metrics;
      _policyController.text = policy;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // F7: Policy Management
          Expanded(
            flex: 1,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Policy Management (F7)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const Text('Edit thresholds without redeploying code.', style: TextStyle(color: Colors.grey)),
                    const Divider(),
                    Expanded(
                      child: TextField(
                        controller: _policyController,
                        maxLines: null,
                        expands: true,
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                        decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Markdown policy rules...'),
                      ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () async {
                          bool success = await _apiService.updatePolicyMarkdown(_policyController.text);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(success ? 'Policy Updated Successfully!' : 'Policy Update Failed.')),
                          );
                        },
                        icon: const Icon(Icons.save),
                        label: const Text('Save Policy & Hot Reload'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 24),
          // F8: Executive Dashboard
          Expanded(
            flex: 1,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Executive Dashboard (F8)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const Text('Live throughput and financial autonomy metrics.', style: TextStyle(color: Colors.grey)),
                    const Divider(),
                    if (_metrics != null) ...[
                      ListTile(
                        title: const Text('Auto-Approval Rate (Efficiency)'),
                        trailing: Text('${_metrics!['rates']['autoApprovalRatePct']}%', style: const TextStyle(color: Colors.green, fontSize: 24, fontWeight: FontWeight.bold)),
                      ),
                      ListTile(
                        title: const Text('Escalation Rate (HITL)'),
                        trailing: Text('${_metrics!['rates']['escalationRatePct']}%', style: const TextStyle(color: Colors.amber, fontSize: 24, fontWeight: FontWeight.bold)),
                      ),
                      const Divider(),
                      ListTile(
                        title: const Text('Autonomous Dollars Handled'),
                        trailing: Text('\$${_metrics!['financials']['autoApprovedDollars']}', style: const TextStyle(fontSize: 18)),
                      ),
                      ListTile(
                        title: const Text('Human Dollars Handled'),
                        trailing: Text('\$${_metrics!['financials']['humanApprovedDollars']}', style: const TextStyle(fontSize: 18)),
                      ),
                      const Divider(),
                      ListTile(
                        title: const Text('Total Invoices Processed'),
                        trailing: Text('${_metrics!['throughput']['totalEvaluated']}', style: const TextStyle(fontSize: 18)),
                      ),
                    ] else
                      const Text('Failed to load metrics. Ensure Dapr state store is running.'),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================
// 4. AUDITOR SCREEN (F9, F10)
// ==========================================
class AuditorScreen extends StatefulWidget {
  const AuditorScreen({super.key});

  @override
  State<AuditorScreen> createState() => _AuditorScreenState();
}

class _AuditorScreenState extends State<AuditorScreen> {
  final ApiService _apiService = ApiService();
  final TextEditingController _searchController = TextEditingController();
  Map<String, dynamic>? _auditData;
  bool _isLoading = false;
  String _errorMessage = '';

  Future<void> _searchAuditTrail() async {
    final searchId = _searchController.text.trim();
    if (searchId.isEmpty) return;

    setState(() {
      _isLoading = true;
      _errorMessage = '';
      _auditData = null;
    });

    final data = await _apiService.getAuditTrail(searchId);

    setState(() {
      if (data == null) {
        _errorMessage = 'No correlation ID found matching "$searchId".';
      } else {
        _auditData = data;
      }
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Audit & Compliance (F9, F10)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const Text('Search decision trails by Correlation ID or Tracking ID.', style: TextStyle(color: Colors.grey)),
              const Divider(),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      decoration: const InputDecoration(
                        labelText: 'Enter Tracking ID...',
                        prefixIcon: Icon(Icons.security),
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _searchAuditTrail(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _searchAuditTrail,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16.0),
                      child: Text('Search Ledger'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              if (_isLoading) const Center(child: CircularProgressIndicator()),
              if (_errorMessage.isNotEmpty)
                Center(child: Text(_errorMessage, style: const TextStyle(color: Colors.red))),

              if (_auditData != null)
                Expanded(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.indigo.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.indigo.shade200),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Immutable Trace for: ${_auditData!['correlationId']}', style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.bold)),
                          const Divider(),
                          const SizedBox(height: 8),
                          _buildTimelineStep('1', 'Data Extraction', 'Vendor: ${_auditData!['extractedData']['vendor']} | Total: \$${_auditData!['extractedData']['total']}'),
                          _buildTimelineStep('2', 'AI & Policy Rules Applied', 'Violations Flagged: ${(_auditData!['rulesApplied'] as List).isEmpty ? "None" : _auditData!['rulesApplied'].join(', ')}'),
                          _buildTimelineStep('3', 'System Routing Reason', '${_auditData!['agentReasoning']}'),
                          _buildTimelineStep('4', 'Final Authority (F10 Guarantee)', '${_auditData!['whoMadeFinalCall']}', highlight: true),
                          _buildTimelineStep('5', 'Saga Ledger Outcome', '${_auditData!['paymentOutcome']}'),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTimelineStep(String step, String title, String detail, {bool highlight = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 12,
            backgroundColor: highlight ? Colors.indigo : Colors.grey.shade400,
            child: Text(step, style: const TextStyle(color: Colors.white, fontSize: 12)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontWeight: FontWeight.bold, color: highlight ? Colors.indigo : Colors.black87)),
                Text(detail, style: const TextStyle(fontSize: 13, color: Colors.black54)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
