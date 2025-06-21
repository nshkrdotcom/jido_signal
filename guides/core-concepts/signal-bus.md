# Guide: The Signal Bus

The Signal Bus is the heart of Jido.Signal's pub/sub system. It's a `GenServer`-based hub that manages subscriptions, routes signals, and maintains a comprehensive signal log for replay capabilities.

## Bus Architecture

The bus operates as a centralized message broker that:

- Maintains active subscriptions and their routing rules
- Logs every signal for replay and audit purposes
- Handles both synchronous and asynchronous signal delivery
- Provides middleware integration points
- Supports persistent subscriptions with acknowledgment

## Managing Subscriptions

### Basic Subscription

```elixir
alias Jido.Signal.Bus

# Subscribe to specific signal types
Bus.subscribe(:my_bus, "user.created", dispatch: {:pid, target: self()})

# Subscribe with wildcards
Bus.subscribe(:my_bus, "user.*", dispatch: {:pid, target: self()})
Bus.subscribe(:my_bus, "payment.**", dispatch: {:pid, target: self()})
```

### Subscription Options

```elixir
Bus.subscribe(:my_bus, "user.*", [
  dispatch: {:pid, target: self()},
  priority: 100,                    # Higher priority handlers run first
  persistent?: true,                # Enable persistent delivery
  filter: fn signal ->              # Optional signal filtering
    signal.data.active == true
  end
])
```

### Unsubscribing

```elixir
# Get subscription ID when subscribing
{:ok, sub_id} = Bus.subscribe(:my_bus, "user.*", dispatch: {:pid, target: self()})

# Unsubscribe using the ID
Bus.unsubscribe(:my_bus, sub_id)
```

## Publishing Signals

### Basic Publishing

```elixir
signal = Jido.Signal.new(%{
  type: "user.created",
  source: "user_service",
  data: %{user_id: 123}
})

Bus.publish(:my_bus, signal)
```

### Publishing Options

```elixir
# Publish with metadata
Bus.publish(:my_bus, signal, %{priority: :high, async: true})

# Publish multiple signals
signals = [signal1, signal2, signal3]
Bus.publish_batch(:my_bus, signals)
```

## The Internal Signal Log

The bus maintains a comprehensive log of every signal that passes through it:

### Log Structure

```elixir
%{
  signal: %Jido.Signal{},           # The original signal
  timestamp: ~U[2024-01-01 12:00:00Z], # When it was logged
  metadata: %{},                    # Additional context
  cause_id: "parent-signal-id"      # Causality tracking
}
```

### Querying the Log

```elixir
# Get recent signals
{:ok, entries} = Bus.get_log(:my_bus, limit: 10)

# Get signals by path pattern
{:ok, entries} = Bus.get_log(:my_bus, path: "user.*", limit: 50)

# Get signals since a timestamp
since = DateTime.add(DateTime.utc_now(), -3600, :second)
{:ok, entries} = Bus.get_log(:my_bus, since: since)
```

## Replaying History

The replay system allows you to retrieve and reprocess signals from the log:

### Basic Replay

```elixir
# Replay all signals matching a pattern
Bus.replay(:my_bus, "user.*", 
  since: DateTime.add(DateTime.utc_now(), -1800, :second),
  dispatch: {:pid, target: self()}
)
```

### Advanced Replay Options

```elixir
Bus.replay(:my_bus, "payment.**", [
  since: ~U[2024-01-01 00:00:00Z],
  until: ~U[2024-01-01 23:59:59Z],
  limit: 1000,
  dispatch: {:pid, target: replay_handler_pid},
  filter: fn entry ->
    entry.signal.data.amount > 1000
  end
])
```

### Replay to Multiple Destinations

```elixir
Bus.replay(:my_bus, "user.*", [
  since: DateTime.add(DateTime.utc_now(), -3600, :second),
  dispatch: [
    {:pid, target: processor1_pid},
    {:webhook, url: "https://api.example.com/webhook"},
    {:logger, level: :info}
  ]
])
```

## Persistent Subscriptions

Persistent subscriptions ensure "at-least-once" delivery even if the subscriber temporarily disconnects:

### Creating Persistent Subscriptions

```elixir
{:ok, sub_id} = Bus.subscribe(:my_bus, "critical.alerts", [
  dispatch: {:pid, target: self()},
  persistent?: true,
  subscriber_id: "alert_processor_1"  # Stable identifier
])
```

### Acknowledgment Flow

```elixir
defmodule AlertProcessor do
  use GenServer

  def handle_info({:signal, signal, delivery_info}, state) do
    case process_alert(signal) do
      :ok ->
        # Acknowledge successful processing
        Bus.ack(:my_bus, delivery_info.subscription_id, delivery_info.message_id)
        {:noreply, state}
      
      {:error, reason} ->
        # Don't acknowledge - signal will be redelivered
        Logger.error("Failed to process alert: #{inspect(reason)}")
        {:noreply, state}
    end
  end
  
  defp process_alert(signal) do
    # Your processing logic here
    :ok
  end
end
```

### Handling Reconnections

```elixir
# Reconnect and replay missed signals
Bus.reconnect(:my_bus, "alert_processor_1", [
  dispatch: {:pid, target: self()},
  replay_missed: true
])
```

## Bus Configuration

### Starting with Custom Options

```elixir
{Jido.Signal.Bus, [
  name: :my_bus,
  log_retention: :timer.hours(24),    # Keep logs for 24 hours
  max_log_size: 100_000,              # Maximum log entries
  middleware: [MyApp.AuditMiddleware], # Custom middleware
  serializer: Jido.Signal.Serialization.JsonSerializer
]}
```

### Runtime Configuration

```elixir
# Update bus configuration
Bus.configure(:my_bus, log_retention: :timer.hours(48))

# Get current configuration
config = Bus.get_config(:my_bus)
```

## Monitoring and Introspection

### Bus Status

```elixir
status = Bus.status(:my_bus)
# Returns:
# %{
#   active_subscriptions: 15,
#   log_size: 1250,
#   uptime: 3600,
#   last_signal: ~U[2024-01-01 12:30:00Z]
# }
```

### Subscription Listing

```elixir
subscriptions = Bus.list_subscriptions(:my_bus)
# Returns list of active subscriptions with their patterns and options
```

## Error Handling

### Delivery Failures

```elixir
# Configure delivery retry behavior
Bus.subscribe(:my_bus, "user.*", [
  dispatch: {:http, url: "https://api.example.com/webhook"},
  retry_policy: %{
    max_retries: 3,
    backoff: :exponential,
    base_delay: 1000
  }
])
```

### Dead Letter Handling

```elixir
# Signals that fail delivery can be routed to a dead letter queue
Bus.subscribe(:my_bus, "user.*", [
  dispatch: {:pid, target: self()},
  dead_letter: {:logger, level: :error}
])
```

## Performance Considerations

### Batch Operations

For high-throughput scenarios, use batch operations:

```elixir
# Batch publish multiple signals
signals = Enum.map(1..1000, fn i ->
  Jido.Signal.new(%{
    type: "batch.item",
    source: "batch_processor",
    data: %{item_id: i}
  })
end)

Bus.publish_batch(:my_bus, signals)
```

### Asynchronous Processing

```elixir
# Publish without blocking
Bus.publish_async(:my_bus, signal)

# Subscribe with async dispatch
Bus.subscribe(:my_bus, "user.*", [
  dispatch: {:pid, target: self(), async: true}
])
```

The Signal Bus provides a robust foundation for building scalable, observable event-driven systems with comprehensive replay and persistence capabilities.
