class LineItem {
  final String description;
  final int quantity;
  final double unitPrice;

  LineItem({
    required this.description,
    required this.quantity,
    required this.unitPrice,
  });

  Map<String, dynamic> toJson() => {
    'description': description,
    'quantity': quantity,
    'unitPrice': unitPrice,
  };
}

class InvoiceSubmission {
  final String vendor;
  final double total;
  final String currency;
  final String description;
  final bool receiptPresent;
  final String department;
  final String category;
  final List<LineItem>? lineItems;

  InvoiceSubmission({
    required this.vendor,
    required this.total,
    this.currency = 'USD',
    required this.description,
    this.receiptPresent = true,
    this.department = 'engineering-2026Q2',
    this.category = 'hardware',
    this.lineItems,
  });

  Map<String, dynamic> toJson() => {
    'vendor': vendor,
    'total': total,
    'currency': currency,
    'description': description,
    'receiptPresent': receiptPresent,
    'department': department,
    'category': category,
    if (lineItems != null)
      'lineItems': lineItems!.map((item) => item.toJson()).toList(),
  };
}

class WorkflowState {
  final String id;
  final String status;
  final List<String> violations;
  final String reason;
  final String? correlationId;
  final String? finalActor;
  final String? paymentOutcome;
  final double? confidence; // NEW: For F4 Approver View
  final List<String> citedPolicyClauses; // NEW: For F4 Approver View
  final Map<String, dynamic>? payload;

  WorkflowState({
    required this.id,
    required this.status,
    required this.violations,
    required this.reason,
    this.correlationId,
    this.finalActor,
    this.paymentOutcome,
    this.confidence,
    this.citedPolicyClauses = const [],
    this.payload,
  });

  factory WorkflowState.fromJson(Map<String, dynamic> json) {
    return WorkflowState(
      id: json['id'] ?? '',
      status: json['status'] ?? 'UNKNOWN',
      violations: List<String>.from(json['violations'] ?? []),
      reason: json['reason'] ?? 'No reason provided.',
      correlationId: json['correlationId'],
      finalActor: json['finalActor'],
      paymentOutcome: json['paymentOutcome'],
      confidence: json['confidence'] != null ? (json['confidence'] as num).toDouble() : null,
      citedPolicyClauses: List<String>.from(json['citedPolicyClauses'] ?? []),
      payload: json['payload'],
    );
  }
}