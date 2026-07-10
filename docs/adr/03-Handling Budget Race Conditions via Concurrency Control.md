Context:
In the invoice processing system that we use, we have a system called workflow service which is designed to execute a payment process that checks for approved invoices and deducts the amounts from the budgets of different departments in the Redis database via Dapr/
An issue related to concurrency was recognized during testing. In case multiple approved invoices attempting to modify the same department budget are processed simultaneously, they can use the same starting budget balance. Hence if two of them execute their 
SaveAsync() calls simultaneously via Dapr in its default Last-Write-Wins mode it would overwrite each other.

Decision: 
In order to avoid any mistakes in calculations, we used Optimistic Concurrency Control on the basis of Dapr’s ETag versioning system along with random back-off retries.

In particular, the system is:
- Fetching budget status along with its ETag version utilizing GetStateAndETagAsync.
- Checking if the requested amount is valid.
- Trying to save the budget by calling TrySaveStateAsync with the ConcurrencyMode.FirstWrite option.
- In case the ETag has changed indicating some other container took over the budget during the period of time required for performing calculations, the write attempt is instantly rejected by Dapr.
- The system catches this rejection and initiates the try catch retry loop with a random delay of 10-50ms in order to avoid blocking threads.

Consequences: 
Positive: 
Idempotency & Security: The mechanism promises that budget caps will never be exceeded even under massive load and parallel usage.
Robustness: Thanks to the retry loop, the software manages database write conflicts efficiently without terminating the .NET thread or leading to failure of the entire saga.
Data Integrity: Meets the expectations for financial ledger accuracy.

Negative: 
Waiting Time: In highly concurrent scenarios, response time for one invoice might be increased by no more than several dozen milliseconds due to random back-off time.
Difficulty: The saga programming in С# is rather complicated as it requires more than just calling SaveAsync() methods, since it has to deal with state preferences and loops.
