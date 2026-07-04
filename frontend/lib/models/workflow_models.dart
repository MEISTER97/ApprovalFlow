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
    'Description': description,
    'Quantity': quantity,
    'UnitPrice': unitPrice,
  };
}

class InvoiceSubmission {
  final String vendor;
  final double total;
  final String currency;
  final String description;
  final bool receiptPresent;
  final List<LineItem>? lineItems;

  InvoiceSubmission({
    required this.vendor,
    required this.total,
    this.currency = 'USD',
    required this.description,
    this.receiptPresent = true,
    this.lineItems,
  });

  Map<String, dynamic> toJson() => {
    'Vendor': vendor,
    'Total': total,
    'Currency': currency,
    'Description': description,
    'ReceiptPresent': receiptPresent,
    if (lineItems != null)
      'LineItems': lineItems!.map((item) => item.toJson()).toList(),
  };
}

class WorkflowState {
  final String id;
  final String status;
  final List<String> violations;
  final String reason;
  final Map<String, dynamic>? payload;

  WorkflowState({
    required this.id,
    required this.status,
    required this.violations,
    required this.reason,
    this.payload,
  });

  factory WorkflowState.fromJson(Map<String, dynamic> json) {
    return WorkflowState(
      id: json['id'] ?? '',
      status: json['status'] ?? 'UNKNOWN',
      violations: List<String>.from(json['violations'] ?? []),
      reason: json['reason'] ?? 'No reason provided.',
      payload: json['payload'],
    );
  }
}