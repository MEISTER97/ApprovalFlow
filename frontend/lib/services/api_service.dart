import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/workflow_models.dart';

class ApiService {
  // Point directly to Docker API Gateway container
  static const String baseUrl = 'http://localhost:8080/api';

  // --- SUBMITTER ENDPOINTS ---

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

  // Submitter provides requested information (Round-trip)
  Future<bool> submitClarification(String trackingId, String clarificationNotes) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/escalations/$trackingId/action'),
        headers: {'Content-Type': 'application/json'},
        // We reuse the HumanActionRequest endpoint, but the action is "RESUBMIT"
        body: json.encode({'Action': 'RESUBMIT', 'Notes': clarificationNotes}),
      );
      return response.statusCode == 200;
    } catch (e) {
      print('❌ Clarification error: $e');
    }
    return false;
  }

  // --- APPROVER ENDPOINTS ---

  // Fetch only escalated items for the Approver queue (F4, F6)
  Future<List<WorkflowState>> getEscalatedInvoices() async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/escalations'));
      if (response.statusCode == 200) {
        final decoded = json.decode(response.body);
        final List<dynamic> data = decoded['queue'];
        return data.map((json) => WorkflowState.fromJson(json)).toList();
      }
    } catch (e) {
      print('❌ Fetch escalations error: $e');
    }
    return [];
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

  // --- CONTROLLER ENDPOINTS ---

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

 // --- CONTROLLER ENDPOINTS (F7) ---

  Future<String?> getPolicyMarkdown() async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/policy'));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['policy'];
      }
    } catch (e) {
      print('❌ Fetch policy error: $e');
    }
    return null;
  }

Future<bool> updatePolicyMarkdown(String policyText) async {
    try {
      final response = await http.post(
        Uri.parse('$baseUrl/policy'),
        headers: {'Content-Type': 'application/json'},
        // FIX: Ensure 'policy' is lowercase to match C# JSON binding rules
        body: json.encode({'policy': policyText}),
      );

      if (response.statusCode == 200) {
        return true;
      } else {
        // NEW: Print the exact error response from the C# backend!
        print('❌ Server rejected policy update. Code: ${response.statusCode}');
        print('❌ Server response: ${response.body}');
        return false;
      }
    } catch (e) {
      print('❌ Update policy network error: $e');
    }
    return false;
  }

  // --- AUDITOR ENDPOINTS ---

// AUDITOR ENDPOINT (F9, F10)
  Future<Map<String, dynamic>?> getAuditTrail(String correlationId) async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/audit/$correlationId'));
      if (response.statusCode == 200) {
        return json.decode(response.body); // Returns a single object, not a list
      }
    } catch (e) {
      print('❌ Fetch audit trail error: $e');
    }
    return null;
  }


}