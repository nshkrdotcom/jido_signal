# API Reference

This section provides quick access to Jido.Signal's API documentation and common usage patterns.

## Documentation Links

For complete API documentation, see the auto-generated HexDocs:

- **[Jido.Signal](https://hexdocs.pm/jido_signal/Jido.Signal.html)** - Core signal structure and creation
- **[Jido.Signal.Bus](https://hexdocs.pm/jido_signal/Jido.Signal.Bus.html)** - Pub/sub bus operations
- **[Jido.Signal.Router](https://hexdocs.pm/jido_signal/Jido.Signal.Router.html)** - Pattern-based routing
- **[Jido.Signal.Dispatch](https://hexdocs.pm/jido_signal/Jido.Signal.Dispatch.html)** - Signal delivery system
- **[Jido.Signal.Journal](https://hexdocs.pm/jido_signal/Jido.Signal.Journal.html)** - Causality tracking

## Module Overview

### Core Modules

| Module | Purpose | Key Functions |
|--------|---------|---------------|
| `Jido.Signal` | Signal creation and structure | `new/1`, `validate/1` |
| `Jido.Signal.Bus` | Pub/sub message bus | `publish/2`, `subscribe/3`, `replay/4` |
| `Jido.Signal.Router` | Path-based routing | `match/2`, `add_route/3` |
| `Jido.Signal.Dispatch` | Signal delivery | `dispatch/2`, `dispatch_async/2` |
| `Jido.Signal.Journal` | Causality tracking | `record/3`, `get_cause/2`, `get_effects/2` |

### Extension Points

| Module | Purpose | Implementation |
|--------|---------|----------------|
| `Jido.Signal.Dispatch.Adapter` | Custom delivery targets | Behaviour |
| `Jido.Signal.Bus.Middleware` | Signal processing pipeline | Behaviour |
| `Jido.Signal.Serializer` | Custom serialization | Behaviour |

## Quick Reference

### Signal Creation

```elixir
# Basic signal
signal = Jido.Signal.new(%{
  type: "user.created",
  source: "user_service",
  data: %{user_id: 123}
})

# Custom signal type with validation
defmodule MyApp.UserSignal do
  use Jido.Signal,
    type: "user.created",
    schema: [
      user_id: [type: :integer, required: true],
      email: [type: :string, required: true]
    ]
end

{:ok, signal} = MyApp.UserSignal.new(%{
  source: "user_service",
  data: %{user_id: 123, email: "user@example.com"}
})
```

### Bus Operations

```elixir
# Start a bus
{Jido.Signal.Bus, name: :my_bus}

# Subscribe to signals
{:ok, sub_id} = Bus.subscribe(:my_bus, "user.*", 
  dispatch: {:pid, target: self()}
)

# Publish a signal
Bus.publish(:my_bus, signal)

# Replay historical signals
Bus.replay(:my_bus, "user.*", 
  since: DateTime.add(DateTime.utc_now(), -3600, :second),
  dispatch: {:pid, target: self()}
)

# Unsubscribe
Bus.unsubscribe(:my_bus, sub_id)
```

### Pattern Matching

```elixir
# Exact match
"user.created"

# Single-level wildcard (one segment)
"user.*"        # Matches: "user.created", "user.updated"

# Multi-level wildcard (any segments)
"user.**"       # Matches: "user.created", "user.profile.updated"
```

### Dispatch Configurations

```elixir
# Process delivery
{:pid, target: self()}
{:named, name: MyHandler}

# External delivery
{:http, url: "https://api.example.com/webhook"}
{:webhook, url: "https://api.example.com", secret: "key"}
{:pubsub, topic: "events"}

# Logging
{:logger, level: :info}
{:console, format: :pretty}

# Multiple targets
[
  {:logger, level: :info},
  {:pid, target: handler_pid},
  {:http, url: "https://api.example.com"}
]
```

### Persistent Subscriptions

```elixir
# Create persistent subscription
{:ok, sub_id} = Bus.subscribe(:my_bus, "critical.*", [
  persistent?: true,
  subscriber_id: "handler_1",
  dispatch: {:pid, target: self()}
])

# Handle signals with acknowledgment
def handle_info({:signal, signal, delivery_info}, state) do
  case process_signal(signal) do
    :ok ->
      Bus.ack(:my_bus, delivery_info.subscription_id, delivery_info.message_id)
      {:noreply, state}
    {:error, _reason} ->
      # Don't ack - signal will be redelivered
      {:noreply, state}
  end
end

# Reconnect with replay
Bus.reconnect(:my_bus, "handler_1", [
  dispatch: {:pid, target: self()},
  replay_missed: true
])
```

### Journal Usage

```elixir
# Record causality
Journal.record(:my_bus, child_signal.id, parent_signal.id)

# Find relationships
{:ok, parent} = Journal.get_cause(:my_bus, signal.id)
{:ok, children} = Journal.get_effects(:my_bus, signal.id)

# Trace full chain
{:ok, chain} = Journal.trace_chain(:my_bus, signal.id)
```

### Middleware

```elixir
# Built-in logging middleware
{Jido.Signal.Bus, [
  name: :my_bus,
  middleware: [Jido.Signal.Bus.Middleware.Logger]
]}

# Custom middleware
defmodule MyMiddleware do
  use Jido.Signal.Bus.Middleware

  @impl true
  def before_publish(signal, _metadata, _state) do
    # Process signal before routing
    {:cont, signal}
  end
end

{Jido.Signal.Bus, [
  name: :my_bus,
  middleware: [MyMiddleware, Jido.Signal.Bus.Middleware.Logger]
]}
```

### Custom Dispatch Adapter

```elixir
defmodule MyAdapter do
  @behaviour Jido.Signal.Dispatch.Adapter

  @impl true
  def validate_opts(opts) do
    # Validate configuration
    {:ok, opts}
  end

  @impl true
  def deliver(signal, opts) do
    # Deliver signal
    {:ok, %{status: :delivered}}
  end
end

# Use custom adapter
Bus.subscribe(:my_bus, "events.*", 
  dispatch: {MyAdapter, custom_option: "value"}
)
```

## Common Patterns

### Event-Driven Architecture

```elixir
# Domain events
Bus.subscribe(:my_bus, "user.**", dispatch: {:pid, target: user_handler})
Bus.subscribe(:my_bus, "order.**", dispatch: {:pid, target: order_handler})
Bus.subscribe(:my_bus, "payment.**", dispatch: {:pid, target: payment_handler})

# Cross-cutting concerns
Bus.subscribe(:my_bus, "**", [
  dispatch: {:logger, level: :debug},
  priority: 1  # Low priority
])
```

### Integration Patterns

```elixir
# Webhook notifications
Bus.subscribe(:my_bus, "critical.**", 
  dispatch: {:webhook, url: "https://alerts.example.com", secret: "key"}
)

# Multi-node distribution
Bus.subscribe(:my_bus, "user.**", 
  dispatch: {:pubsub, topic: "user_events"}
)

# External API calls
Bus.subscribe(:my_bus, "order.completed", 
  dispatch: {:http, 
    url: "https://fulfillment.example.com/webhook",
    headers: %{"Authorization" => "Bearer #{token}"}
  }
)
```

### Error Handling

```elixir
# Retry configuration
Bus.subscribe(:my_bus, "payment.**", dispatch: {:http,
  url: "https://payment-processor.example.com",
  retry_policy: %{
    max_retries: 3,
    backoff: :exponential,
    base_delay: 1000
  }
})

# Dead letter handling
Bus.subscribe(:my_bus, "critical.**", dispatch: [
  {:http, url: "https://primary.example.com"},
  {:logger, level: :error, on_failure: true}
])
```

## Return Values

### Success Responses

```elixir
# Signal creation
{:ok, %Jido.Signal{}} = Jido.Signal.new(attrs)

# Subscription
{:ok, subscription_id} = Bus.subscribe(bus, pattern, opts)

# Publishing
:ok = Bus.publish(bus, signal)

# Journal queries
{:ok, parent_signal} = Journal.get_cause(bus, signal_id)
{:ok, [child_signal]} = Journal.get_effects(bus, signal_id)
```

### Error Responses

```elixir
# Validation errors
{:error, %{field: ["is required"]}} = Jido.Signal.new(invalid_attrs)

# Bus errors
{:error, :not_found} = Bus.unsubscribe(bus, invalid_id)
{:error, :bus_not_found} = Bus.publish(:invalid_bus, signal)

# Journal errors
{:error, :not_found} = Journal.get_cause(bus, nonexistent_id)
```

For detailed function signatures, options, and examples, refer to the [complete HexDocs documentation](https://hexdocs.pm/jido_signal/).
