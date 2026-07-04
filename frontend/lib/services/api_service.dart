import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/workflow_models.dart';

class ApiService {
  // Point directly to your Docker API Gateway container
  static const String baseUrl = 'http://localhost:8080/api';

  // Endpoint 1: Submit new invoice (F1)
  Future<String?> submitInvoice(InvoiceSubmission invoice) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/invoices'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode(invoice.toJson()),
      );

      if (response.statusCode == 202) {
        final data = json.decode(response.body);
        return data['trackingId'];
      }
    } catch (e) {
      print('❌ Submit error: $e');
    }
    return null;
  }

  // Endpoint 3: Poll invoice status (F2)
  Future<WorkflowState?> getInvoiceState(String trackingId) async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/invoices/$trackingId'));
      if (response.statusCode == 200) {
        return WorkflowState.fromJson(json.decode(response.body));
      }
    } catch (e) {
      print('❌ Fetch state error: $e');
    }
    return null;
  }

  // Endpoint 5: Execute HITL Manager Override (F5)
  Future<WorkflowState?> executeAction(
    String trackingId,
    String action,
    String notes,
  ) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/escalations/$trackingId/action'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'Action': action, 'Notes': notes}),
      );

      if (response.statusCode == 200) {
        return WorkflowState.fromJson(json.decode(response.body));
      }
    } catch (e) {
      print('❌ Action error: $e');
    }
    return null;
  }

  // Endpoint 8: Fetch F8 Controller Dashboard Metrics
  Future<Map<String, dynamic>?> getDashboardMetrics() async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/dashboard/metrics'));
      if (response.statusCode == 200) {
        return json.decode(response.body);
      }
    } catch (e) {
      print('❌ Metrics error: $e');
    }
    return null;
  }
}