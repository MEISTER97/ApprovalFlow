import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/workflow_models.dart';

class ApiService {
  static const String baseUrl = 'http://localhost:5001/api';

  // Endpoint 1: Submit new invoice
  Future<String?> submitInvoice(InvoiceSubmission invoice) async {
    final response = await http.post(
      Uri.parse('$baseUrl/invoices'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(invoice.toJson()),
    );

    if (response.statusCode == 202) {
      final data = json.decode(response.body);
      return data['trackingId'];
    }
    return null;
  }

  // Endpoint 3: Poll invoice status
  Future<WorkflowState?> getInvoiceState(String trackingId) async {
    final response = await http.get(Uri.parse('$baseUrl/invoices/$trackingId'));

    if (response.statusCode == 200) {
      return WorkflowState.fromJson(json.decode(response.body));
    }
    return null;
  }

  // Endpoint 5: Execute HITL Manager Override (APPROVE / REJECT)
  Future<WorkflowState?> executeAction(
    String trackingId,
    String action,
    String notes,
  ) async {
    final response = await http.post(
      Uri.parse('$baseUrl/escalations/$trackingId/action'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'Action': action, 'Notes': notes}),
    );

    if (response.statusCode == 200) {
      return WorkflowState.fromJson(json.decode(response.body));
    }
    return null;
  }
}