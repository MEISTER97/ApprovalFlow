Context:
an application system using two different technology stacks: Python 3.11 / FastAPI (api-gateway, ai-service, payment-service) and ASP.NET Core /.NET 10 (workflow-service). It takes a lot of time and unavoidably results in some flaws when creating specialized infrastructure boilerplate for communications, state storage, retries, and secrets management for two languages.

Decision:
I use Redis as the backend store for Dapr sidecars. Common Dapr primitives are used in all cross-service interactions: 
Secrets Management (secrets.json), State Store ledgers (budget:{dept}), Pub/Sub messaging (invoice_submitted), and Service Invocation.

Consequences: 
Positive: significantly reduce language specific boilerplate and handles infrastructure issues in both Python and C# stacks in a similar way.
Negative: Using a Dapr sidecar for each application container causes an increase in the local Docker memory usage. This also means you have to monitor the resource allocation of containers, You must also keep track of how it takes for the application to communicate with the sidecar and it also add latency between application and the the Dapr sidecar.