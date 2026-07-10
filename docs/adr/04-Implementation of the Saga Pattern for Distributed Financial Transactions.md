Context:
Workflow service process the invoice and subtract money from the department’s budget once it gets approval. Nonetheless, the actual transaction process will be asynchronous and might fail. The system should ensure that once the budget has been reserved for the invoice payment process but fails, the money gets released back to the department.

Decision:
We will use Choreography based Saga Pattern in Dapr Pub/Sub and State Management.
On approval of an invoice, the budget is reserved in the state store, and the status is set to BUDGET_RESERVED.  We have created an /api/workflow/payment-failed endpoint which subscribes to the payment_failed topic.
In case of trigger, a compensating action is performed, which releases the budget of the department, which we called ReleaseBudgetAsync, and the state is set to PAYMENT_FAILED.
We have created an /api/workflow/payment-succeeded endpoint, which triggers on successful completion of an event using an idempotency check.


Consequences:
Positive: Service is very loose with respect to the payment gateway, responding resiliently to asynchronous successes and failures.
Negative: Increases complexity in the workflow and requires custom state management rather than a mere database transaction.





