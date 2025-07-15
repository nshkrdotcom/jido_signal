# Jido Signal Usage Rules

Essential guidelines for the Jido Signal library - an Elixir toolkit for event-driven and agent-based systems.

## Core Principles

- **Signal-First**: Use Signals for all inter-process communication (CloudEvents v1.0.2 compliant)
- **Bus-Centric**: Route all signals through the Bus for history, replay, and pattern-based subscriptions
- **Hierarchical Types**: Use dot notation (`"user.created"`, `"payment.processed"`)
- **Validation**: Define custom signal types with schemas for type safety

## Signal Creation

```elixir
# Basic signal (type, source, data required)
{:ok, signal} = Jido.Signal.new(%{
  type: "user.created",
  source: "user_service", 
  data: %{user_id: 123, email: "user@example.com"}
})

# Custom signal types (preferred - with validation)
defmodule UserCreated do
  use Jido.Signal,
    type: "user.created",
    schema: [user_id: [type: :integer, required: true]]
end

{:ok, signal} = UserCreated.new(%{source: "user_service", data: %{user_id: 123}})
```

**Naming**: Use dot notation (`"user.created"`, `"payment.processed"`) - avoid camelCase or underscores.

## Bus Operations

```elixir
# Start bus in supervision tree
children = [{Jido.Signal.Bus, name: :my_bus}]

# Subscribe with patterns
Bus.subscribe(:my_bus, "user.created", dispatch: {:pid, target: self()})  # exact
Bus.subscribe(:my_bus, "user.*", dispatch: {:pid, target: self()})        # single wildcard  
Bus.subscribe(:my_bus, "user.**", dispatch: {:pid, target: self()})       # multi wildcard

# Publish (always as lists)
Bus.publish(:my_bus, [signal])
Bus.publish(:my_bus, [signal1, signal2, signal3])
```

## Routing and Dispatch

```elixir
# Simple routes (pattern, handler, optional priority)
{"user.created", HandleUserCreated}
{"audit.**", AuditLogger, 100}  # high priority

# Function-based routing
{"payment.processed", fn signal -> signal.data.amount > 1000 end, HandleLargePayment}

# Multiple dispatch targets
{"system.error", [
  {MetricsAdapter, [type: :error]},
  {AlertAdapter, [priority: :high]},
  {LogAdapter, [level: :error]}
]}
```

**Priority**: -100 to 100 (higher first). Specific paths execute before wildcards.

## Dispatch Adapters

**Available**: `:pid`, `:pubsub`, `:logger`, `:http`, `:webhook`, `:console`, `:noop`

```elixir
# Single dispatch
dispatch: {:pubsub, topic: "events"}

# Multiple targets
dispatch: [
  {:pubsub, topic: "events"},
  {:logger, level: :info},
  {:webhook, url: "https://api.example.com/webhook"}
]

# PID with options
dispatch: {:pid, target: self(), delivery_mode: :async}
```

## Middleware

```elixir
# Custom middleware
defmodule MyMiddleware do
  @behaviour Jido.Signal.Bus.Middleware
  def process(signal, _opts), do: {:ok, signal}
end

# Configure in bus
{Jido.Signal.Bus, name: :my_bus, middleware: [{MyMiddleware, []}]}
```

**Use for**: logging, metrics, validation, auth. Executes before routing in registration order.

## Error Handling

```elixir
# Signal creation
case Jido.Signal.new(params) do
  {:ok, signal} -> Bus.publish(:my_bus, [signal])
  {:error, reason} -> Logger.error("Failed: #{inspect(reason)}")
end

# Dispatch errors
case Dispatch.dispatch(signal, config) do
  :ok -> :ok
  {:error, reason} -> Logger.error("Dispatch failed: #{inspect(reason)}")
end
```

**Validation**: Use custom signal types with schemas. Handle errors gracefully.

## Performance

**Memory**: Bus keeps signal history in-memory. Use snapshots for long-running systems.
**Subscriptions**: Unsubscribe on termination. Use persistent subscriptions for critical handlers.
**Routing**: Exact matches perform better than wildcards. Consider signal volume in design.

## Testing

```elixir
# Test signal flow
{:ok, signal} = UserCreated.new(%{source: "test", data: %{user_id: 123}})
Bus.subscribe(:test_bus, "user.*", dispatch: {:pid, target: self()})
Bus.publish(:test_bus, [signal])
assert_receive {:signal, ^signal}
```

**Debug**: Use `:console` adapter, enable middleware logging, `:noop` for testing.

## Integration

```elixir
# Webhook
dispatch: {:webhook, [url: "https://api.example.com/webhook", secret: "secret"]}

# HTTP API
dispatch: {:http, [url: "https://api.example.com/events", method: :post]}

# Phoenix PubSub
dispatch: {:pubsub, topic: "user_events"}

# Channel broadcasting
def handle_info({:signal, signal}, socket) do
  push(socket, "signal", signal)
  {:noreply, socket}
end
```

## Anti-Patterns

**❌ Don't:**
- Use raw Elixir messages: `send(pid, {:user_created, user_id})`
- Bypass the bus: `GenServer.cast(handler, {:signal, signal})`
- Use generic types: `"event"`, `"message"`, `"data"`
- Ignore dispatch errors: `Dispatch.dispatch(signal, config)`

**✅ Do:**
- Use structured signals: `{:ok, signal} = UserCreated.new(%{user_id: user_id})`
- Route through bus: `Bus.publish(:my_bus, [signal])`
- Use specific types: `"user.created"`, `"payment.processed"`
- Handle errors: `case Dispatch.dispatch(signal, config) do...`

## Debugging

**Tracing**: Use signal IDs for correlation. Leverage signal history and replay for analysis.
**Monitoring**: Add telemetry for `[:jido, :signal, :published]`, `[:jido, :signal, :dispatched]`, etc.

```elixir
:telemetry.attach_many("jido-signal-handler", [
  [:jido, :signal, :published],
  [:jido, :signal, :dispatched]
], &MyTelemetryHandler.handle_event/4, nil)
```

## Migration

```elixir
# From GenServer messages
GenServer.cast(handler, {:user_created, user_id})  # Before
{:ok, signal} = UserCreated.new(%{user_id: user_id})  # After
Bus.publish(:my_bus, [signal])

# From Phoenix PubSub
Phoenix.PubSub.broadcast(PubSub, "events", {:user_created, user})  # Before
{:ok, signal} = UserCreated.new(%{user: user})  # After
Bus.publish(:my_bus, [signal])
```

## Best Practices

1. Use Signals for all inter-process communication
2. Define custom signal types with validation schemas  
3. Use hierarchical type names (`"user.created"`)
4. Route through the Bus for distribution
5. Handle errors gracefully in creation and dispatch
6. Monitor signal volume and memory usage
7. Use appropriate dispatch adapters
8. Test signal flow thoroughly
9. Document signal types and routing patterns
10. Use middleware for cross-cutting concerns

## Advanced Features

### Journal (Causality Tracking)
```elixir
journal = Jido.Signal.Journal.new()
{:ok, journal} = Journal.record(journal, signal1)
{:ok, journal} = Journal.record(journal, signal2, signal1.id)  # causality
effects = Journal.get_effects(journal, signal1.id)
chain = Journal.trace_chain(journal, signal1.id, :forward)
```

### Serialization
```elixir
config :jido_signal, default_serializer: Jido.Signal.Serialization.JsonSerializer
{:ok, binary} = Serializer.serialize(signal, serializer: JsonSerializer)
# Available: JsonSerializer, ErlangTermSerializer, MsgpackSerializer
```

### Process Topology
```elixir
topology = Jido.Signal.Topology.new()
{:ok, topology} = Topology.register(topology, "parent", parent_pid)
{:ok, topology} = Topology.register(topology, "child", child_pid, parent_id: "parent")
tree = Topology.to_tree(topology)
```

### Persistent Subscriptions
```elixir
{:ok, sub_pid} = PersistentSubscription.start_link(
  bus_pid: bus_pid, path: "user.**", client_pid: self(), max_in_flight: 100)
GenServer.cast(sub_pid, {:ack, signal_id})
GenServer.cast(sub_pid, {:reconnect, new_client_pid})
```

### Bus Snapshots
```elixir
{:ok, snapshot_ref, new_state} = Snapshot.create(state, "user.**")
{:ok, snapshot_data} = Snapshot.read(state, snapshot_ref.id)
{:ok, new_state} = Snapshot.cleanup(state)
```

### Signal Replay
```elixir
{:ok, signals} = Bus.replay(bus_pid, "user.**", from_timestamp: yesterday)
{:ok, stream} = Bus.stream(bus_pid, "payment.**", start_from: :origin, batch_size: 100)
```

## Security & Production

**Security**: Validate signal data with schemas, sanitize external input, implement auth in middleware.
**Monitoring**: Add telemetry for signal events, monitor signal log size, use snapshots for memory management.
**Error Handling**: Log errors with signal context, create error signals for failed processing.

```elixir
# Secure webhook
dispatch: {:webhook, [url: "https://api.example.com/webhook", secret: "secret", verify_ssl: true]}

# Telemetry
:telemetry.attach_many("jido-signal-metrics", [
  [:jido, :signal, :published], [:jido, :signal, :failed]
], &MyApp.Telemetry.handle_event/4, %{})

# Error handling
defmodule MyApp.SignalErrorHandler do
  def handle_signal_error(signal, error) do
    Logger.error("Signal failed: #{signal.id}", error: inspect(error))
    {:ok, error_signal} = ErrorSignal.new(%{
      source: "error_handler", 
      data: %{original_signal_id: signal.id, error: inspect(error)}
    })
    Bus.publish(:error_bus, [error_signal])
  end
end
```

## Getting Help

- **Documentation**: https://hexdocs.pm/jido_signal/
- **GitHub**: https://github.com/agentjido/jido_signal
- **Jido Project**: https://agentjido.xyz
- **CloudEvents Spec**: https://cloudevents.io/

Remember: Jido Signal transforms Elixir's message passing into a sophisticated communication system that scales from simple GenServer interactions to complex multi-agent orchestration across distributed systems. 