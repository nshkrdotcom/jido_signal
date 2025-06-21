# Guide: Persistent Subscriptions

Persistent subscriptions provide "at-least-once" delivery guarantees for critical event processing. Unlike regular subscriptions that lose messages on client disconnection, persistent subscriptions maintain state and replay missed signals when clients reconnect.

## When to Use Persistent Subscriptions

Persistent subscriptions are ideal for:

- **Critical event processing** - Financial transactions, user state changes, audit logs
- **Unreliable network environments** - Mobile apps, IoT devices, microservices
- **Long-running processes** - Data pipelines, batch jobs, background workers
- **Guaranteed delivery requirements** - Compliance, regulatory, or business-critical flows

## How Persistent Subscriptions Work

When you create a persistent subscription, Jido.Signal:

1. **Creates a dedicated GenServer** - Each persistent subscription gets its own process
2. **Tracks message state** - Maintains checkpoints of acknowledged messages
3. **Handles flow control** - Limits in-flight messages to prevent overwhelming clients
4. **Provides replay capability** - Automatically replays missed messages on reconnection

## Creating Persistent Subscriptions

### Basic Persistent Subscription

```elixir
alias Jido.Signal.Bus

# Create a persistent subscription
{:ok, subscription_id} = Bus.subscribe(:my_bus, "payment.processed", [
  dispatch: {:pid, target: self()},
  persistent?: true,
  subscription_id: "payment_processor_1"  # Stable identifier for reconnection
])
```

### Advanced Configuration

```elixir
{:ok, subscription_id} = Bus.subscribe(:my_bus, "critical.**", [
  dispatch: {:pid, target: self()},
  persistent?: true,
  subscription_id: "critical_event_processor",
  max_in_flight: 100,    # Limit concurrent unacknowledged messages
  start_from: :origin,   # Start from beginning of log (:origin, :current, or timestamp)
  priority: 100          # Higher priority for critical events
])
```

**Persistent Subscription Options:**

- `persistent?: true` - Enables persistent mode (required)
- `subscription_id` - Stable identifier for reconnection (recommended)
- `max_in_flight` - Maximum unacknowledged messages (default: 1000)
- `start_from` - Where to start reading (`:origin`, `:current`, or timestamp)

## The Acknowledgment Flow

Persistent subscriptions require explicit acknowledgment to ensure messages are processed:

### Basic Acknowledgment Pattern

```elixir
defmodule PaymentProcessor do
  use GenServer
  alias Jido.Signal.Bus

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    # Subscribe to payment events
    {:ok, sub_id} = Bus.subscribe(:payment_bus, "payment.processed", [
      dispatch: {:pid, target: self()},
      persistent?: true,
      subscription_id: "payment_processor"
    ])
    
    {:ok, %{subscription_id: sub_id, processed_count: 0}}
  end

  def handle_info({:signal, signal}, state) do
    case process_payment(signal) do
      :ok ->
        # Acknowledge successful processing
        :ok = Bus.ack(:payment_bus, state.subscription_id, signal.id)
        {:noreply, %{state | processed_count: state.processed_count + 1}}
      
      {:error, reason} ->
        # Don't acknowledge - signal will be redelivered
        Logger.error("Payment processing failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  defp process_payment(signal) do
    # Your payment processing logic
    case signal.data do
      %{amount: amount, account_id: account_id} when amount > 0 ->
        # Process payment...
        :ok
      _ ->
        {:error, :invalid_payment_data}
    end
  end
end
```

### Batch Acknowledgment

For high-throughput scenarios, acknowledge multiple messages at once:

```elixir
defmodule BatchProcessor do
  use GenServer
  alias Jido.Signal.Bus

  def init(opts) do
    {:ok, sub_id} = Bus.subscribe(:batch_bus, "batch.item.**", [
      dispatch: {:pid, target: self()},
      persistent?: true,
      subscription_id: "batch_processor",
      max_in_flight: 500
    ])
    
    {:ok, %{
      subscription_id: sub_id,
      batch: [],
      batch_size: 100
    }}
  end

  def handle_info({:signal, signal}, state) do
    new_batch = [signal | state.batch]
    
    if length(new_batch) >= state.batch_size do
      case process_batch(new_batch) do
        :ok ->
          # Acknowledge entire batch
          signal_ids = Enum.map(new_batch, & &1.id)
          :ok = Bus.ack(:batch_bus, state.subscription_id, signal_ids)
          {:noreply, %{state | batch: []}}
        
        {:error, reason} ->
          Logger.error("Batch processing failed: #{inspect(reason)}")
          {:noreply, state}
      end
    else
      {:noreply, %{state | batch: new_batch}}
    end
  end

  defp process_batch(signals) do
    # Process entire batch atomically
    :ok
  end
end
```

## Handling Disconnections

When clients disconnect, persistent subscriptions preserve their state and allow seamless reconnection:

### Reconnection Pattern

```elixir
defmodule ResilientProcessor do
  use GenServer
  alias Jido.Signal.Bus

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    bus_name = Keyword.fetch!(opts, :bus_name)
    subscription_id = Keyword.get(opts, :subscription_id, "resilient_processor")
    
    state = %{
      bus_name: bus_name,
      subscription_id: subscription_id,
      connected?: false
    }
    
    # Attempt initial connection
    connect(state)
  end

  # Handle connection success
  def handle_info({:connect_result, :ok}, state) do
    Logger.info("Successfully connected to #{state.bus_name}")
    {:noreply, %{state | connected?: true}}
  end

  # Handle connection failure
  def handle_info({:connect_result, {:error, reason}}, state) do
    Logger.error("Failed to connect: #{inspect(reason)}")
    # Retry after delay
    Process.send_after(self(), :retry_connect, 5_000)
    {:noreply, state}
  end

  # Retry connection
  def handle_info(:retry_connect, state) do
    connect(state)
  end

  # Handle signals when connected
  def handle_info({:signal, signal}, %{connected?: true} = state) do
    case process_signal(signal) do
      :ok ->
        :ok = Bus.ack(state.bus_name, state.subscription_id, signal.id)
        {:noreply, state}
      
      {:error, reason} ->
        Logger.error("Signal processing failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # Ignore signals when disconnected
  def handle_info({:signal, _signal}, %{connected?: false} = state) do
    {:noreply, state}
  end

  defp connect(state) do
    task = Task.async(fn ->
      try do
        # Try to reconnect to existing subscription
        case Bus.reconnect(state.bus_name, state.subscription_id, self()) do
          {:ok, _checkpoint} ->
            Logger.info("Reconnected to existing subscription")
            :ok
          
          {:error, :subscription_not_found} ->
            # Create new subscription if none exists
            case Bus.subscribe(state.bus_name, "events.**", [
              dispatch: {:pid, target: self()},
              persistent?: true,
              subscription_id: state.subscription_id
            ]) do
              {:ok, _sub_id} ->
                Logger.info("Created new persistent subscription")
                :ok
              
              {:error, reason} ->
                {:error, reason}
            end
          
          {:error, reason} ->
            {:error, reason}
        end
      rescue
        e -> {:error, e}
      end
    end)
    
    # Send result to self
    Task.await(task)
    |> then(&send(self(), {:connect_result, &1}))
    
    {:noreply, state}
  end

  defp process_signal(signal) do
    # Your signal processing logic
    Logger.info("Processing signal: #{signal.type}")
    :ok
  end
end
```

## Replay Functionality

Persistent subscriptions can replay missed signals when reconnecting:

### Automatic Replay on Reconnection

```elixir
# Reconnect automatically replays missed signals
{:ok, checkpoint} = Bus.reconnect(:my_bus, "processor_1", self())

# The checkpoint tells you the timestamp of the last processed signal
Logger.info("Reconnected at checkpoint: #{checkpoint}")
```

### Manual Replay for Recovery

```elixir
defmodule RecoveryProcessor do
  use GenServer
  alias Jido.Signal.Bus

  def recover_from_timestamp(bus_name, subscription_id, from_timestamp) do
    # Replay all missed signals since timestamp
    {:ok, missed_signals} = Bus.replay(bus_name, "**", [
      since: from_timestamp,
      dispatch: {:pid, target: self()}
    ])
    
    Logger.info("Replaying #{length(missed_signals)} missed signals")
    
    # Process each missed signal
    Enum.each(missed_signals, fn entry ->
      case process_signal(entry.signal) do
        :ok ->
          Bus.ack(bus_name, subscription_id, entry.signal.id)
        
        {:error, reason} ->
          Logger.error("Recovery failed for signal #{entry.signal.id}: #{inspect(reason)}")
      end
    end)
  end

  defp process_signal(signal) do
    # Your recovery processing logic
    :ok
  end
end
```

## Complete Working Example

Here's a complete example of a persistent subscription system:

```elixir
defmodule OrderProcessor do
  @moduledoc """
  A resilient order processing system using persistent subscriptions.
  """
  use GenServer
  require Logger
  alias Jido.Signal.Bus

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # Server Implementation

  def init(opts) do
    bus_name = Keyword.get(opts, :bus_name, :order_bus)
    subscription_id = Keyword.get(opts, :subscription_id, "order_processor")
    
    state = %{
      bus_name: bus_name,
      subscription_id: subscription_id,
      orders_processed: 0,
      errors: 0,
      last_processed_at: nil
    }
    
    # Subscribe to order events
    {:ok, _sub_id} = Bus.subscribe(bus_name, "order.**", [
      dispatch: {:pid, target: self()},
      persistent?: true,
      subscription_id: subscription_id,
      max_in_flight: 50
    ])
    
    Logger.info("OrderProcessor started with subscription: #{subscription_id}")
    {:ok, state}
  end

  def handle_call(:get_stats, _from, state) do
    stats = %{
      orders_processed: state.orders_processed,
      errors: state.errors,
      last_processed_at: state.last_processed_at
    }
    {:reply, stats, state}
  end

  def handle_info({:signal, signal}, state) do
    Logger.debug("Processing order signal: #{signal.type}")
    
    case process_order_signal(signal) do
      :ok ->
        # Acknowledge successful processing
        :ok = Bus.ack(state.bus_name, state.subscription_id, signal.id)
        
        new_state = %{state | 
          orders_processed: state.orders_processed + 1,
          last_processed_at: DateTime.utc_now()
        }
        
        {:noreply, new_state}
      
      {:error, reason} ->
        Logger.error("Order processing failed: #{inspect(reason)}")
        
        # Don't acknowledge - signal will be redelivered
        new_state = %{state | errors: state.errors + 1}
        {:noreply, new_state}
    end
  end

  defp process_order_signal(signal) do
    case signal.type do
      "order.created" ->
        process_order_created(signal.data)
      
      "order.updated" ->
        process_order_updated(signal.data)
      
      "order.cancelled" ->
        process_order_cancelled(signal.data)
      
      _ ->
        Logger.warning("Unknown order signal type: #{signal.type}")
        :ok
    end
  end

  defp process_order_created(data) do
    # Validate order data
    with {:ok, order_id} <- validate_order_id(data),
         {:ok, customer_id} <- validate_customer_id(data),
         {:ok, items} <- validate_items(data) do
      
      # Process the order
      Logger.info("Creating order #{order_id} for customer #{customer_id}")
      
      # Simulate order processing
      Process.sleep(100)
      
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp process_order_updated(data) do
    # Update order processing logic
    Logger.info("Updating order #{data[:order_id]}")
    :ok
  end

  defp process_order_cancelled(data) do
    # Cancel order processing logic
    Logger.info("Cancelling order #{data[:order_id]}")
    :ok
  end

  # Validation helpers
  defp validate_order_id(%{order_id: order_id}) when is_binary(order_id), do: {:ok, order_id}
  defp validate_order_id(_), do: {:error, :missing_order_id}

  defp validate_customer_id(%{customer_id: customer_id}) when is_binary(customer_id), do: {:ok, customer_id}
  defp validate_customer_id(_), do: {:error, :missing_customer_id}

  defp validate_items(%{items: items}) when is_list(items) and length(items) > 0, do: {:ok, items}
  defp validate_items(_), do: {:error, :invalid_items}
end

# Usage example
defmodule OrderProcessingDemo do
  alias Jido.Signal.{Bus, Signal}
  
  def run_demo do
    # Start the bus
    {:ok, bus_pid} = Bus.start_link(name: :order_bus)
    
    # Start the order processor
    {:ok, _processor_pid} = OrderProcessor.start_link(bus_name: :order_bus)
    
    # Publish some test orders
    orders = [
      %{
        type: "order.created",
        source: "order_service",
        data: %{
          order_id: "order_123",
          customer_id: "customer_456",
          items: [%{sku: "ITEM001", quantity: 2}]
        }
      },
      %{
        type: "order.updated",
        source: "order_service", 
        data: %{order_id: "order_123", status: "processing"}
      }
    ]
    
    # Publish orders
    Enum.each(orders, fn order_data ->
      {:ok, signal} = Signal.new(order_data)
      {:ok, _recorded} = Bus.publish(:order_bus, signal)
    end)
    
    # Wait for processing
    Process.sleep(1000)
    
    # Check stats
    stats = OrderProcessor.get_stats()
    IO.inspect(stats, label: "Processing Stats")
  end
end
```

## Error Handling Patterns

### Retry with Exponential Backoff

```elixir
defmodule RetryProcessor do
  use GenServer
  alias Jido.Signal.Bus

  def init(opts) do
    {:ok, sub_id} = Bus.subscribe(:retry_bus, "events.**", [
      dispatch: {:pid, target: self()},
      persistent?: true,
      subscription_id: "retry_processor"
    ])
    
    {:ok, %{subscription_id: sub_id, retry_attempts: %{}}}
  end

  def handle_info({:signal, signal}, state) do
    case process_with_retry(signal, state) do
      :ok ->
        :ok = Bus.ack(:retry_bus, state.subscription_id, signal.id)
        new_state = %{state | retry_attempts: Map.delete(state.retry_attempts, signal.id)}
        {:noreply, new_state}
      
      {:retry, attempt} ->
        # Schedule retry with exponential backoff
        delay = :math.pow(2, attempt) * 1000 |> round()
        Process.send_after(self(), {:retry, signal}, delay)
        
        new_state = %{state | retry_attempts: Map.put(state.retry_attempts, signal.id, attempt)}
        {:noreply, new_state}
      
      {:error, reason} ->
        Logger.error("Permanent failure for signal #{signal.id}: #{inspect(reason)}")
        # Acknowledge to prevent infinite retries
        :ok = Bus.ack(:retry_bus, state.subscription_id, signal.id)
        {:noreply, state}
    end
  end

  def handle_info({:retry, signal}, state) do
    # Retry processing
    send(self(), {:signal, signal})
    {:noreply, state}
  end

  defp process_with_retry(signal, state) do
    attempt = Map.get(state.retry_attempts, signal.id, 0)
    
    case process_signal(signal) do
      :ok -> :ok
      {:error, :temporary} when attempt < 3 -> {:retry, attempt + 1}
      {:error, :temporary} -> {:error, :max_retries_exceeded}
      {:error, reason} -> {:error, reason}
    end
  end

  defp process_signal(signal) do
    # Your processing logic that might fail
    if :rand.uniform() > 0.3 do
      :ok
    else
      {:error, :temporary}
    end
  end
end
```

### Dead Letter Queue Pattern

```elixir
defmodule DeadLetterProcessor do
  use GenServer
  alias Jido.Signal.Bus

  def init(opts) do
    # Subscribe to main events
    {:ok, main_sub} = Bus.subscribe(:main_bus, "events.**", [
      dispatch: {:pid, target: self()},
      persistent?: true,
      subscription_id: "main_processor"
    ])
    
    # Subscribe to dead letter queue
    {:ok, dlq_sub} = Bus.subscribe(:dlq_bus, "dlq.**", [
      dispatch: {:pid, target: self()},
      persistent?: true,
      subscription_id: "dlq_processor"
    ])
    
    {:ok, %{
      main_subscription: main_sub,
      dlq_subscription: dlq_sub,
      failed_attempts: %{}
    }}
  end

  def handle_info({:signal, signal}, state) do
    case signal.type do
      "dlq." <> _ ->
        # Handle dead letter queue messages
        handle_dlq_signal(signal, state)
      
      _ ->
        # Handle main signals
        handle_main_signal(signal, state)
    end
  end

  defp handle_main_signal(signal, state) do
    case process_signal(signal) do
      :ok ->
        :ok = Bus.ack(:main_bus, state.main_subscription, signal.id)
        {:noreply, state}
      
      {:error, reason} ->
        attempts = Map.get(state.failed_attempts, signal.id, 0) + 1
        
        if attempts >= 3 do
          # Send to dead letter queue
          dlq_signal = %{signal | type: "dlq.#{signal.type}"}
          {:ok, _} = Bus.publish(:dlq_bus, dlq_signal)
          
          # Acknowledge original signal
          :ok = Bus.ack(:main_bus, state.main_subscription, signal.id)
          
          new_state = %{state | failed_attempts: Map.delete(state.failed_attempts, signal.id)}
          {:noreply, new_state}
        else
          # Track failure and don't acknowledge
          new_state = %{state | failed_attempts: Map.put(state.failed_attempts, signal.id, attempts)}
          {:noreply, new_state}
        end
    end
  end

  defp handle_dlq_signal(signal, state) do
    # Handle dead letter queue processing
    Logger.error("Processing dead letter: #{signal.type}")
    
    # Acknowledge DLQ signal
    :ok = Bus.ack(:dlq_bus, state.dlq_subscription, signal.id)
    {:noreply, state}
  end

  defp process_signal(signal) do
    # Your processing logic
    :ok
  end
end
```

## Best Practices

### 1. Use Stable Subscription IDs

```elixir
# Good: Stable, meaningful identifier
subscription_id = "#{node()}_order_processor_v1"

# Bad: Random identifier that changes on restart
subscription_id = "proc_#{:rand.uniform(10000)}"
```

### 2. Implement Proper Flow Control

```elixir
# Configure max_in_flight based on your processing capacity
Bus.subscribe(:my_bus, "events.**", [
  persistent?: true,
  max_in_flight: 100,  # Adjust based on memory and processing speed
  subscription_id: "processor_1"
])
```

### 3. Handle Acknowledgment Errors

```elixir
def handle_info({:signal, signal}, state) do
  case process_signal(signal) do
    :ok ->
      case Bus.ack(state.bus_name, state.subscription_id, signal.id) do
        :ok -> 
          {:noreply, state}
        
        {:error, reason} ->
          Logger.error("Acknowledgment failed: #{inspect(reason)}")
          # Consider what to do with failed acks
          {:noreply, state}
      end
    
    {:error, reason} ->
      Logger.error("Processing failed: #{inspect(reason)}")
      {:noreply, state}
  end
end
```

### 4. Monitor Subscription Health

```elixir
defmodule SubscriptionHealthMonitor do
  use GenServer
  alias Jido.Signal.Bus

  def init(opts) do
    # Start periodic health checks
    :timer.send_interval(30_000, :health_check)
    {:ok, opts}
  end

  def handle_info(:health_check, state) do
    # Check subscription status
    case Bus.status(state.bus_name) do
      %{active_subscriptions: count} when count > 0 ->
        Logger.debug("Subscription healthy: #{count} active")
      
      _ ->
        Logger.warning("No active subscriptions detected")
        # Attempt reconnection
        attempt_reconnection(state)
    end
    
    {:noreply, state}
  end

  defp attempt_reconnection(state) do
    case Bus.reconnect(state.bus_name, state.subscription_id, self()) do
      {:ok, _checkpoint} ->
        Logger.info("Reconnection successful")
      
      {:error, reason} ->
        Logger.error("Reconnection failed: #{inspect(reason)}")
    end
  end
end
```

## Common Pitfalls

### 1. Forgetting to Acknowledge
```elixir
# Wrong: Processing without acknowledgment
def handle_info({:signal, signal}, state) do
  process_signal(signal)  # No acknowledgment!
  {:noreply, state}
end

# Correct: Always acknowledge successful processing
def handle_info({:signal, signal}, state) do
  case process_signal(signal) do
    :ok ->
      :ok = Bus.ack(:my_bus, state.subscription_id, signal.id)
      {:noreply, state}
    
    {:error, _reason} ->
      # Don't acknowledge failures
      {:noreply, state}
  end
end
```

### 2. Acknowledging Too Early
```elixir
# Wrong: Acknowledging before processing
def handle_info({:signal, signal}, state) do
  :ok = Bus.ack(:my_bus, state.subscription_id, signal.id)  # Too early!
  process_signal(signal)  # Could still fail
  {:noreply, state}
end

# Correct: Acknowledge after successful processing
def handle_info({:signal, signal}, state) do
  case process_signal(signal) do
    :ok ->
      :ok = Bus.ack(:my_bus, state.subscription_id, signal.id)
      {:noreply, state}
    
    {:error, _reason} ->
      {:noreply, state}
  end
end
```

### 3. Not Handling Reconnection Properly
```elixir
# Wrong: Not handling reconnection errors
def reconnect(bus_name, subscription_id) do
  Bus.reconnect(bus_name, subscription_id, self())  # What if this fails?
end

# Correct: Handle reconnection errors with retry logic
def reconnect(bus_name, subscription_id, retry_count \\ 0) do
  case Bus.reconnect(bus_name, subscription_id, self()) do
    {:ok, checkpoint} ->
      Logger.info("Reconnected successfully at #{checkpoint}")
      :ok
    
    {:error, reason} when retry_count < 3 ->
      Logger.warning("Reconnection failed, retrying: #{inspect(reason)}")
      :timer.sleep(1000 * (retry_count + 1))
      reconnect(bus_name, subscription_id, retry_count + 1)
    
    {:error, reason} ->
      Logger.error("Reconnection failed permanently: #{inspect(reason)}")
      {:error, reason}
  end
end
```

Persistent subscriptions provide robust, reliable event processing with guaranteed delivery. By following these patterns and best practices, you can build resilient systems that handle failures gracefully and never lose critical events.
