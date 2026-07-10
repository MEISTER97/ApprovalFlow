Context:
an application system using two different technology stacks: Python 3.11 / FastAPI (api-gateway, ai-service, payment-service) and ASP.NET Core /.NET 10 (workflow-service). It takes a lot of time and unavoidably results in some flaws when creating specialized infrastructure boilerplate for communications, state storage, retries, and secrets management for two languages.

Decision:
I use Redis as the backend store for Dapr (Distributed Application Runtime) sidecars. Common Dapr primitives are used in all cross-service interactions: Secrets Management (secrets.json), State Store ledgers (budget:{dept}), Pub/Sub messaging (invoice_submitted), and Service Invocation.

Consequences: 
Positive: significantly cuts down language specific boilerplate and provides infrastructure concerns in both Python and C# stacks uniformly
Negative: Using a Dapr sidecar for each application container causes an increase in the local Docker memory usage. It also requires keeping track of the resource allocation of containers and latency between the application and the sidecar.