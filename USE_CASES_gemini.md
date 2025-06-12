Of course. Here is a comprehensive list of use cases for the `jido_signal` library, along with the specific integration points and code modules that enable them.

### Use Cases and Integration Points

The architecture of `jido_signal` is designed to support a wide range of messaging patterns, from simple service decoupling to complex, durable workflow choreography.

---

#### 1. Core Use Case: Service Decoupling & Asynchronous Messaging

This is the most fundamental use case, enabling an event-driven architecture where components can communicate without having direct knowledge of one another.

*   **What it is:** A "publisher" service emits a signal about something that happened. One or more "subscriber" services listen for that type of signal and react to it independently. The publisher doesn't know or care who is listening.
*   **How `jido_signal` enables it:** The `Jido.Signal.Bus` acts as the central intermediary. The router's path-based matching (`user.*`, `payment.processed`, etc.) is the core mechanism for this decoupling.
*   **Integration Points:**
    *   **Publishing a Signal:** A service creates a `%Jido.Signal{}` and publishes it to a named bus.
        ```elixir
        signal = %Jido.Signal{type: "order.created", source: "/orders", data: %{id: 123}}
        Jido.Signal.Bus.publish(:main_bus, [signal])
        ```
    *   **Subscribing to a Signal:** A service (typically a `GenServer`) subscribes to a path pattern during its initialization. The bus will then send messages to its process mailbox.
        ```elixir
        # In your GenServer (e.g., NotificationService)
        def init(opts) do
          Jido.Signal.Bus.subscribe(:main_bus, "order.*")
          {:ok, %{}}
        end

        # Handle the incoming signal
        def handle_info({:signal, %Jido.Signal{type: "order.created"} = signal}, state) do
          # Send an email, push notification, etc.
          {:noreply, state}
        end
        ```
*   **Relevant Modules:**
    *   `Jido.Signal`: For creating the message payload.
    *   `Jido.Signal.Bus`: The `publish/2` and `subscribe/3` functions are the primary API.
    *   `Jido.Signal.Router`: The underlying engine that makes the path matching efficient.

---

#### 2. Advanced Use Case: Complex Workflow Choreography

For multi-step business processes where the completion of one step triggers the next, often involving multiple services.

*   **What it is:** A sequence of actions is "choreographed" by events. For example, `Order Placed` -> `Payment Processed` -> `Shipment Prepared` -> `Shipment Dispatched`. Each service listens for the previous event and emits the next one.
*   **How `jido_signal` enables it:** The system allows services to be both publishers and subscribers. The `Jido.Signal.Journal` is critical here, as it can track the causal chain of events.
*   **Integration Points:**
    *   **Establishing Causality:** When a service consumes a signal and produces a new one, it should record the original signal's ID as the `cause_id`.
        ```elixir
        # In ShippingService, after consuming the "payment.processed" signal
        def handle_info({:signal, payment_signal}, state) do
          # ... prepare shipment ...
          shipment_signal = %Jido.Signal{type: "shipment.prepared", ...}

          # Record the new signal in a journal, linking it to the cause
          Jido.Signal.Journal.record(state.journal, shipment_signal, payment_signal.id)

          # Publish the next signal in the chain
          Jido.Signal.Bus.publish(:main_bus, [shipment_signal])
          {:noreply, state}
        end
        ```
    *   **Tracing a Workflow:** To debug or inspect a full workflow, you can use the journal.
        ```elixir
        # Get the full history of what happened after a specific payment
        Jido.Signal.Journal.trace_chain(journal, "payment_signal_id", :forward)
        ```
    *   **Correlation:** The `subject` field of a `Jido.Signal` can be used to hold a correlation ID (e.g., the `order_id`), allowing you to retrieve all signals related to a specific business transaction using `Jido.Signal.Journal.get_conversation/2`.
*   **Relevant Modules:**
    *   `Jido.Signal.Journal`: The core component for tracking causality.
    *   `Jido.Signal.Bus`: For the event passing.
    *   `Jido.Signal`: The `id` and `subject` fields are crucial for linking.

---

#### 3. Use Case: Auditing, Logging, and System Monitoring

Creating an observable system by capturing a stream of all important activities.

*   **What it is:** A centralized way to log, audit, or monitor signals flowing through the system for security, compliance, or operational insight.
*   **How `jido_signal` enables it:** Through middleware, wildcard subscriptions, and specialized dispatch adapters.
*   **Integration Points:**
    *   **Built-in Logging Middleware:** The easiest way to get visibility. Simply add the middleware when starting the bus.
        ```elixir
        # In your application supervisor
        children = [
          {Jido.Signal.Bus, name: :main_bus, middleware: [
            {Jido.Signal.Bus.Middleware.Logger, [level: :info, include_signal_data: true]}
          ]}
        ]
        ```
    *   **Wildcard Subscription for Auditing:** An auditor service can subscribe to all signals (`"**"`) and forward them to a secure data store or external monitoring system.
        ```elixir
        # In an AuditorService
        def init(_) do
          dispatch_config = {:webhook, [
            url: "https://audits.mycompany.com/ingest",
            secret: System.get_env("AUDIT_WEBHOOK_SECRET")
          ]}
          Jido.Signal.Bus.subscribe(:main_bus, "**", dispatch: dispatch_config)
          {:ok, %{}}
        end
        ```
    *   **Targeted Monitoring:** Subscribe to specific error or metric paths.
        ```elixir
        Jido.Signal.Bus.subscribe(:main_bus, "system.error.**", dispatch: {:logger, [level: :error]})
        ```
*   **Relevant Modules:**
    *   `Jido.Signal.Bus.Middleware.Logger`: For easy, built-in logging.
    *   `Jido.Signal.Dispatch.Webhook`, `Http`, `LoggerAdapter`: Dispatch adapters are the key to sending audit trails to external systems.
    *   `Jido.Signal.Router`: The wildcard matching (`**`) is what makes universal subscriptions possible.

---

#### 4. Use Case: Durable, At-Least-Once Delivery for Critical Tasks

Ensuring that a critical signal is processed, even if the subscribing service crashes or is temporarily unavailable.

*   **What it is:** For tasks like processing payments, fulfilling orders, or updating critical data, you cannot afford to lose a signal. The system must guarantee that the signal will eventually be processed.
*   **How `jido_signal` enables it:** The `PersistentSubscription` model is designed specifically for this. It acts as a durable mailbox for the client.
*   **Integration Points:**
    *   **Creating a Persistent Subscription:** The subscriber process requests it on `subscribe`.
        ```elixir
        # In a critical BillingWorker GenServer
        def init(_) do
          {:ok, sub_id} = Jido.Signal.Bus.subscribe(:main_bus, "payment.charge.due", persistent?: true)
          {:ok, %{subscription_id: sub_id}}
        end
        ```
    *   **Acknowledging a Signal:** After a signal is *successfully and fully processed*, the worker MUST acknowledge it.
        ```elixir
        def handle_info({:signal, signal}, %{subscription_id: sub_id} = state) do
          # ... attempt to charge the credit card ...
          case Billing.charge(signal.data) do
            :ok ->
              Jido.Signal.Bus.ack(:main_bus, sub_id, signal.id)
            {:error, _reason} ->
              # Do not ack. The signal will be redelivered later.
              # May want to implement a dead-letter queue mechanism here.
          end
          {:noreply, state}
        end
        ```
    *   **Reconnecting:** If the worker restarts, it should reconnect to its persistent subscription to receive any unacknowledged or missed signals.
        ```elixir
        # Logic to store and retrieve subscription_id is required
        Jido.Signal.Bus.reconnect(:main_bus, "retrieved_sub_id", self())
        ```
*   **Relevant Modules:**
    *   `Jido.Signal.Bus.PersistentSubscription`: The `GenServer` that manages the state for a single durable subscriber.
    *   `Jido.Signal.Bus.Subscriber`: Handles the logic for creating the persistent subscription process.
    *   `Jido.Signal.Bus`: The `ack/3` and `reconnect/3` API.

---

#### 5. Use Case: System Debugging and State Inspection

Interactively inspecting the flow of signals and the state of the system, especially during development or troubleshooting.

*   **What it is:** Gaining insight into the runtime behavior of the system without having to add extensive logging and redeploy.
*   **How `jido_signal` enables it:** The bus maintains an in-memory log of recent signals which can be queried and even replayed.
*   **Integration Points:** These are typically used from an `IEx` remote console.
    *   **Creating a Snapshot:** Capture a filtered view of the signal log at a point in time.
        ```elixir
        # In an IEx session
        iex> {:ok, ref} = Jido.Signal.Bus.snapshot_create(:main_bus, "user.123.**")
        iex> {:ok, snapshot_data} = Jido.Signal.Bus.snapshot_read(:main_bus, ref.id)
        iex> IO.inspect(snapshot_data.signals)
        ```
    *   **Replaying Signals:** Re-send historical signals to a new subscriber to debug its behavior. This is extremely powerful for reproducing bugs.
        ```elixir
        # Start a temporary, interactive listener process
        iex> {:ok, listener_pid} = MyDebugListener.start_link()
        iex> Jido.Signal.Bus.subscribe(:main_bus, "order.failed", dispatch: {:pid, target: listener_pid})

        # Now, replay the failed order signals from the last hour
        iex> start_time = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_unix(:millisecond)
        iex> Jido.Signal.Bus.replay(:main_bus, "order.failed", start_time)
        ```
    *   **Process Topology:** Understand the supervision tree and relationships between running agent processes.
        ```elixir
        # In IEx
        iex> topology = build_my_app_topology() # Application-specific function
        iex> Jido.Signal.Topology.print(topology)
        # ├── my_app_supervisor (<0.123.0>)
        # │   ├── main_bus (<0.124.0>)
        # │   ├── OrderService (<0.125.0>)
        ```
*   **Relevant Modules:**
    *   `Jido.Signal.Bus.Snapshot`: Manages point-in-time views of the log.
    *   `Jido.Signal.Bus.Stream`: The `filter` function used by `replay` and `snapshot`.
    *   `Jido.Signal.Topology`: For building and visualizing process hierarchies.
