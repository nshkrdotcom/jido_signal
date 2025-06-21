# Jido Signal Usage Rules

This document provides essential guidelines for working with the Jido Signal library, an Elixir toolkit for building event-driven and agent-based systems.

## Core Architecture Principles

### Signal-First Design
- **Always use Signals for inter-process communication** instead of raw Elixir messages
- **Signals are CloudEvents v1.0.2 compliant** with Jido-specific extensions
- **Every event, command, and state change should flow through Signals**
- **Signals provide standardized structure, routing, and traceability**

### Bus-Centric Architecture
- **Use the Signal Bus as the central nervous system** of your application
- **All signal routing and distribution goes through the Bus**
- **The Bus maintains complete signal history and provides replay capabilities**
- **Subscriptions are pattern-based using dot notation with wildcards**

## Signal Creation and Structure

### Required Fields
- **`type`**: Use hierarchical dot notation (e.g., `"user.created"`, `"payment.processed"`)
- **`source`**: Identify the originating service/component (e.g., `"user_service"`, `"payment_processor"`)
- **`data`**: The actual event payload (keep it flat and focused)

### Signal Type Naming Conventions
```elixir
# ✅ Correct patterns
"user.created"
"user.profile.updated"
"payment.transaction.completed"
"inventory.item.stock.low"

# ❌ Avoid these patterns
"userCreated"
"user_created"
"USER.CREATED"
```

### Creating Signals
```elixir
# Basic signal creation
{:ok, signal} = Jido.Signal.new(%{
  type: "user.created",
  source: "user_service",
  data: %{user_id: 123, email: "user@example.com"}
})

# With custom signal types (preferred for validation)
defmodule UserCreated do
  use Jido.Signal,
    type: "user.created",
    schema: [
      user_id: [type: :integer, required: true],
      email: [type: :string, required: true]
    ]
end

{:ok, signal} = UserCreated.new(%{
  source: "user_service",
  data: %{user_id: 123, email: "user@example.com"}
})
```

## Bus Configuration and Usage

### Starting a Bus
```elixir
# In your application supervision tree
children = [
  {Jido.Signal.Bus, name: :my_app_bus}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

### Subscribing to Signals
```elixir
# Exact match
Bus.subscribe(:my_bus, "user.created", dispatch: {:pid, target: self()})

# Single-level wildcard
Bus.subscribe(:my_bus, "user.*", dispatch: {:pid, target: self()})

# Multi-level wildcard
Bus.subscribe(:my_bus, "user.**", dispatch: {:pid, target: self()})
```

### Publishing Signals
```elixir
# Always publish lists of signals
Bus.publish(:my_bus, [signal])

# Multiple signals
Bus.publish(:my_bus, [signal1, signal2, signal3])
```

## Routing Patterns

### Path Complexity and Priority
- **More specific paths execute before wildcards**
- **Use exact matches when possible** for better performance
- **Priority ranges: -100 to 100** (higher executes first)
- **Reserve high priorities (75-100) for critical handlers**
- **Use default priority (0) for standard business logic**

### Pattern Matching
```elixir
# Simple route
{"user.created", HandleUserCreated}

# High-priority audit logging
{"audit.**", AuditLogger, 100}

# Pattern matching for specific conditions
{"payment.processed",
  fn signal -> signal.data.amount > 1000 end,
  HandleLargePayment}

# Multiple dispatch targets
{"system.error", [
  {MetricsAdapter, [type: :error]},
  {AlertAdapter, [priority: :high]},
  {LogAdapter, [level: :error]}
]}
```

## Dispatch System

### Built-in Adapters
- **`:pid`** - Direct delivery to a specific process
- **`:pubsub`** - Delivery via PubSub mechanism
- **`:logger`** - Log signals using Logger
- **`:http`** - HTTP requests using :httpc
- **`:webhook`** - Webhook delivery with signatures
- **`:console`** - Print signals to console (development)
- **`:noop`** - No-op adapter for testing

### Dispatch Configuration
```elixir
# Single dispatch
jido_dispatch: {:pubsub, topic: "events"}

# Multiple dispatch targets
jido_dispatch: [
  {:pubsub, topic: "events"},
  {:logger, level: :info},
  {:webhook, url: "https://api.example.com/webhook"}
]

# PID dispatch with options
jido_dispatch: {:pid, target: self(), delivery_mode: :async}
```

## Middleware and Extensions

### Middleware Pipeline
- **Middleware processes signals before routing**
- **Use for cross-cutting concerns** (logging, metrics, validation)
- **Middleware executes in registration order**
- **Built-in logger middleware available**

### Custom Middleware
```elixir
defmodule MyMiddleware do
  @behaviour Jido.Signal.Bus.Middleware

  def process(signal, _opts) do
    # Process signal
    {:ok, signal}
  end
end

# Configure in bus
{Jido.Signal.Bus, name: :my_bus, middleware: [{MyMiddleware, []}]}
```

## Error Handling and Validation

### Signal Validation
- **Always validate signal data** using custom signal types with schemas
- **Handle validation errors gracefully**
- **Use NimbleOptions schemas** for type safety

### Error Patterns
```elixir
# Handle signal creation errors
case Jido.Signal.new(params) do
  {:ok, signal} -> 
    Bus.publish(:my_bus, [signal])
  {:error, reason} -> 
    Logger.error("Failed to create signal: #{inspect(reason)}")
end

# Handle dispatch errors
case Dispatch.dispatch(signal, config) do
  :ok -> 
    Logger.info("Signal dispatched successfully")
  {:error, reason} -> 
    Logger.error("Dispatch failed: #{inspect(reason)}")
end
```

## Performance and Scalability

### Bus Performance
- **Bus maintains in-memory signal history** - monitor memory usage
- **Use snapshots for long-running systems** to manage memory
- **Consider signal volume** when designing routing patterns
- **Batch operations** for high-throughput scenarios

### Subscription Management
- **Unsubscribe when processes terminate** to prevent memory leaks
- **Use persistent subscriptions** for critical handlers
- **Monitor subscription count** in production

## Testing and Development

### Testing Patterns
```elixir
# Test signal creation
{:ok, signal} = UserCreated.new(%{
  source: "test",
  data: %{user_id: 123, email: "test@example.com"}
})

# Test bus interactions
Bus.subscribe(:test_bus, "user.*", dispatch: {:pid, target: self()})
Bus.publish(:test_bus, [signal])

# Verify signal received
assert_receive {:signal, ^signal}
```

### Development Tools
- **Use `:console` adapter** for debugging signal flow
- **Enable middleware logging** for development
- **Use `:noop` adapter** for testing without side effects

## Integration Patterns

### External Services
```elixir
# Webhook integration
jido_dispatch: {:webhook, [
  url: "https://api.example.com/webhook",
  secret: "webhook_secret",
  event_type_map: %{"user:created" => "user.created"}
]}

# HTTP API integration
jido_dispatch: {:http, [
  url: "https://api.example.com/events",
  method: :post,
  headers: [{"x-api-key", "secret"}]
]}
```

### Phoenix Integration
```elixir
# PubSub integration
jido_dispatch: {:pubsub, topic: "user_events"}

# Channel broadcasting
def handle_info({:signal, signal}, socket) do
  push(socket, "signal", signal)
  {:noreply, socket}
end
```

## Common Anti-Patterns

### ❌ Don't Do This
```elixir
# Don't use raw Elixir messages
send(pid, {:user_created, user_id})

# Don't bypass the bus
GenServer.cast(handler, {:signal, signal})

# Don't use generic signal types
"event"
"message"
"data"

# Don't ignore dispatch errors
Dispatch.dispatch(signal, config)  # No error handling
```

### ✅ Do This Instead
```elixir
# Use structured signals
{:ok, signal} = UserCreated.new(%{user_id: user_id})
Bus.publish(:my_bus, [signal])

# Use specific signal types
"user.created"
"payment.processed"
"inventory.updated"

# Handle dispatch errors
case Dispatch.dispatch(signal, config) do
  :ok -> :ok
  {:error, reason} -> Logger.error("Dispatch failed: #{reason}")
end
```

## Debugging and Monitoring

### Signal Tracing
- **Use signal IDs** for correlation across services
- **Leverage signal history** for debugging
- **Monitor signal flow** through middleware
- **Use replay capabilities** for post-mortem analysis

### Observability
```elixir
# Add telemetry for monitoring
:telemetry.attach_many(
  "jido-signal-handler",
  [
    [:jido, :signal, :published],
    [:jido, :signal, :dispatched],
    [:jido, :signal, :routed]
  ],
  &MyTelemetryHandler.handle_event/4,
  nil
)
```

## Migration from Traditional Messaging

### From GenServer Messages
```elixir
# Before
GenServer.cast(user_handler, {:user_created, user_id, email})

# After
{:ok, signal} = UserCreated.new(%{user_id: user_id, email: email})
Bus.publish(:my_bus, [signal])
```

### From Phoenix PubSub
```elixir
# Before
Phoenix.PubSub.broadcast(MyApp.PubSub, "user_events", {:user_created, user})

# After
{:ok, signal} = UserCreated.new(%{user: user})
Bus.publish(:my_bus, [signal])
```

## Best Practices Summary

1. **Always use Signals** for inter-process communication
2. **Define custom signal types** with validation schemas
3. **Use descriptive, hierarchical type names**
4. **Route through the Bus** for all signal distribution
5. **Handle errors gracefully** in signal creation and dispatch
6. **Monitor signal volume** and memory usage
7. **Use appropriate dispatch adapters** for different use cases
8. **Test signal flow** thoroughly in development
9. **Document your signal types** and routing patterns
10. **Use middleware** for cross-cutting concerns

## Getting Help

- **Documentation**: https://hexdocs.pm/jido_signal/
- **GitHub**: https://github.com/agentjido/jido_signal
- **Jido Project**: https://agentjido.xyz
- **CloudEvents Spec**: https://cloudevents.io/

Remember: Jido Signal transforms Elixir's message passing into a sophisticated communication system that scales from simple GenServer interactions to complex multi-agent orchestration across distributed systems. 