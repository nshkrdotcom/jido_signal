# Guide: Snapshots in Jido.Signal

Snapshots provide immutable, filtered, point-in-time views of your signal log. They capture a specific subset of signals at a given moment, making them invaluable for debugging, data export, state initialization, and historical analysis.

## Core Concepts

### What is a Snapshot?

A snapshot is an immutable copy of signals that match specific criteria at the time of creation. Unlike live subscriptions that stream ongoing signals, snapshots capture a static view of your signal history.

Key characteristics:

- **Immutable** - Once created, snapshots never change
- **Filtered** - Only signals matching your path pattern are included
- **Point-in-time** - Captures signals as they existed at creation time
- **Efficient** - Stored in `:persistent_term` for fast access with minimal memory overhead

### Snapshot Architecture

Snapshots use a two-tier architecture for efficiency:

```elixir
# Lightweight reference stored in bus state
%SnapshotRef{
  id: "snapshot-uuid",
  path: "user.created",
  created_at: ~U[2024-01-15 10:30:00Z]
}

# Full data stored in :persistent_term
%SnapshotData{
  id: "snapshot-uuid", 
  path: "user.created",
  signals: %{"signal-id" => %Signal{...}},
  created_at: ~U[2024-01-15 10:30:00Z]
}
```

This design keeps bus state lightweight while providing fast access to snapshot data.

## Common Use Cases

### Debugging and Troubleshooting

Create snapshots to investigate issues without affecting live traffic:

```elixir
# Capture all error signals for analysis
{:ok, error_snapshot} = Jido.Signal.Bus.snapshot_create(bus, "error.**")

# Read the snapshot to analyze error patterns
{:ok, snapshot_data} = Jido.Signal.Bus.snapshot_read(bus, error_snapshot.id)

# Analyze error distribution
error_types = 
  snapshot_data.signals
  |> Map.values()
  |> Enum.group_by(& &1.type)
  |> Map.new(fn {type, signals} -> {type, length(signals)} end)

IO.inspect(error_types, label: "Error distribution")
```

### Historical Data Export

Export specific signal types for external analysis or archival:

```elixir
# Create snapshot of user activity signals
{:ok, user_snapshot} = Jido.Signal.Bus.snapshot_create(bus, "user.**")

# Export to JSON for external processing
{:ok, snapshot_data} = Jido.Signal.Bus.snapshot_read(bus, user_snapshot.id)

export_data = %{
  snapshot_id: user_snapshot.id,
  created_at: user_snapshot.created_at,
  signal_count: map_size(snapshot_data.signals),
  signals: Map.values(snapshot_data.signals)
}

File.write!("user_activity_export.json", Jason.encode!(export_data, pretty: true))
```

### State Initialization

Use snapshots to bootstrap new services with historical context:

```elixir
# Create snapshot of current state signals
{:ok, state_snapshot} = Jido.Signal.Bus.snapshot_create(bus, "state.**")

# Initialize new service instance
defmodule MyService do
  def initialize_from_snapshot(bus, snapshot_id) do
    {:ok, snapshot_data} = Jido.Signal.Bus.snapshot_read(bus, snapshot_id)
    
    # Process signals to rebuild state
    initial_state = 
      snapshot_data.signals
      |> Map.values()
      |> Enum.sort_by(& &1.time)
      |> Enum.reduce(%{}, &apply_signal_to_state/2)
    
    {:ok, initial_state}
  end
  
  defp apply_signal_to_state(signal, state) do
    # Your state reconstruction logic
    case signal.type do
      "state.entity.created" -> Map.put(state, signal.data.entity_id, signal.data)
      "state.entity.updated" -> Map.update(state, signal.data.entity_id, signal.data, &Map.merge(&1, signal.data))
      _ -> state
    end
  end
end
```

## Snapshot Lifecycle

### Creating Snapshots

#### Basic Snapshot Creation

```elixir
# Create snapshot of specific signal type
{:ok, snapshot_ref} = Jido.Signal.Bus.snapshot_create(bus, "user.created")

# Create snapshot of all signals  
{:ok, all_signals} = Jido.Signal.Bus.snapshot_create(bus, "**")

# Create snapshot with wildcard patterns
{:ok, user_events} = Jido.Signal.Bus.snapshot_create(bus, "user.*")
{:ok, payment_events} = Jido.Signal.Bus.snapshot_create(bus, "payment.**")
```

#### Advanced Snapshot Options

```elixir
# Create snapshot with custom ID for easy reference
{:ok, snapshot_ref} = 
  Jido.Signal.Bus.snapshot_create(bus, "order.completed", id: "daily-orders-#{Date.utc_today()}")

# Create snapshot with timestamp filtering (when supported)
start_timestamp = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.to_unix(:millisecond)
{:ok, recent_snapshot} = 
  Jido.Signal.Bus.snapshot_create(bus, "**", start_timestamp: start_timestamp)

# Create snapshot with correlation ID filtering  
{:ok, correlated_snapshot} = 
  Jido.Signal.Bus.snapshot_create(bus, "**", correlation_id: "batch-123")

# Limit snapshot size
{:ok, limited_snapshot} = 
  Jido.Signal.Bus.snapshot_create(bus, "**", batch_size: 500)
```

### Listing Snapshots

```elixir
# Get all snapshots (sorted by creation time, newest first)
snapshots = Jido.Signal.Bus.snapshot_list(bus)

# Display snapshot summary
Enum.each(snapshots, fn snapshot ->
  IO.puts("Snapshot: #{snapshot.id}")
  IO.puts("  Path: #{snapshot.path}")
  IO.puts("  Created: #{snapshot.created_at}")
end)

# Find snapshots by pattern
user_snapshots = Enum.filter(snapshots, fn s -> String.contains?(s.path, "user") end)
```

### Reading Snapshot Data

```elixir
# Read complete snapshot data
{:ok, snapshot_data} = Jido.Signal.Bus.snapshot_read(bus, snapshot_id)

IO.puts("Snapshot contains #{map_size(snapshot_data.signals)} signals")

# Process signals from snapshot
snapshot_data.signals
|> Map.values()
|> Enum.each(fn signal ->
  IO.puts("Signal: #{signal.type} at #{signal.time}")
end)

# Handle missing snapshots
case Jido.Signal.Bus.snapshot_read(bus, "non-existent-id") do
  {:ok, data} -> process_snapshot(data)
  {:error, :not_found} -> IO.puts("Snapshot not found")
end
```

### Deleting Snapshots

```elixir
# Delete a specific snapshot
:ok = Jido.Signal.Bus.snapshot_delete(bus, snapshot_id)

# Clean up old snapshots (using internal API)
cutoff_time = DateTime.utc_now() |> DateTime.add(-24, :hour)

# This would be done through direct state manipulation in a maintenance task
cleanup_filter = fn snapshot_ref -> 
  DateTime.compare(snapshot_ref.created_at, cutoff_time) == :lt 
end

# Note: Cleanup with filters requires access to internal state
```

## Filtering and Querying

### Path Pattern Matching

Snapshots use the same path patterns as subscriptions:

```elixir
# Exact match
{:ok, exact} = Jido.Signal.Bus.snapshot_create(bus, "user.created")

# Single-level wildcard
{:ok, user_events} = Jido.Signal.Bus.snapshot_create(bus, "user.*")
# Matches: "user.created", "user.updated", "user.deleted"

# Multi-level wildcard  
{:ok, all_user} = Jido.Signal.Bus.snapshot_create(bus, "user.**")
# Matches: "user.created", "user.profile.updated", "user.settings.changed"

# All signals
{:ok, everything} = Jido.Signal.Bus.snapshot_create(bus, "**")
```

### Post-Creation Filtering

Filter snapshot data after creation for complex queries:

```elixir
{:ok, snapshot_data} = Jido.Signal.Bus.snapshot_read(bus, snapshot_id)

# Filter by signal properties
recent_signals = 
  snapshot_data.signals
  |> Map.values()
  |> Enum.filter(fn signal ->
    DateTime.compare(signal.time, one_hour_ago) == :gt
  end)

# Filter by data content
high_value_orders = 
  snapshot_data.signals
  |> Map.values()
  |> Enum.filter(fn signal ->
    signal.type == "order.created" and 
    Map.get(signal.data, :amount, 0) > 1000
  end)

# Group signals for analysis
signals_by_source = 
  snapshot_data.signals
  |> Map.values()
  |> Enum.group_by(& &1.source)
```

## Working Examples

### Complete Monitoring Dashboard

```elixir
defmodule MonitoringDashboard do
  def create_daily_snapshots(bus) do
    today = Date.utc_today()
    
    snapshots = %{
      errors: create_snapshot(bus, "error.**", "errors-#{today}"),
      user_activity: create_snapshot(bus, "user.**", "users-#{today}"),
      orders: create_snapshot(bus, "order.**", "orders-#{today}"),
      system_events: create_snapshot(bus, "system.**", "system-#{today}")
    }
    
    generate_report(bus, snapshots)
  end
  
  defp create_snapshot(bus, path, id) do
    case Jido.Signal.Bus.snapshot_create(bus, path, id: id) do
      {:ok, snapshot_ref} -> snapshot_ref
      {:error, reason} -> 
        Logger.error("Failed to create snapshot #{id}: #{inspect(reason)}")
        nil
    end
  end
  
  defp generate_report(bus, snapshots) do
    Enum.reduce(snapshots, %{}, fn {type, snapshot_ref}, acc ->
      if snapshot_ref do
        {:ok, data} = Jido.Signal.Bus.snapshot_read(bus, snapshot_ref.id)
        
        stats = %{
          signal_count: map_size(data.signals),
          time_range: calculate_time_range(data.signals),
          top_sources: get_top_sources(data.signals, 5)
        }
        
        Map.put(acc, type, stats)
      else
        acc
      end
    end)
  end
  
  defp calculate_time_range(signals) when map_size(signals) == 0, do: nil
  defp calculate_time_range(signals) do
    times = 
      signals
      |> Map.values()
      |> Enum.map(& &1.time)
      |> Enum.sort(DateTime)
    
    %{earliest: List.first(times), latest: List.last(times)}
  end
  
  defp get_top_sources(signals, limit) do
    signals
    |> Map.values()
    |> Enum.group_by(& &1.source)
    |> Enum.map(fn {source, signals} -> {source, length(signals)} end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.take(limit)
  end
end

# Usage
report = MonitoringDashboard.create_daily_snapshots(bus)
IO.inspect(report, label: "Daily Signal Report")
```

### Snapshot-Based Testing

```elixir
defmodule IntegrationTest do
  def setup_test_scenario(bus) do
    # Create test signals
    test_signals = [
      %{type: "user.created", data: %{user_id: 1, email: "test1@example.com"}},
      %{type: "user.created", data: %{user_id: 2, email: "test2@example.com"}},
      %{type: "order.created", data: %{order_id: 1, user_id: 1, amount: 100}},
      %{type: "order.completed", data: %{order_id: 1, status: "completed"}}
    ]
    
    # Publish test signals
    Enum.each(test_signals, fn signal_data ->
      {:ok, signal} = Jido.Signal.new(Map.put(signal_data, :source, "test"))
      Jido.Signal.Bus.publish(bus, signal)
    end)
    
    # Create snapshots for different test scenarios
    {:ok, user_snapshot} = Jido.Signal.Bus.snapshot_create(bus, "user.**", id: "test-users")
    {:ok, order_snapshot} = Jido.Signal.Bus.snapshot_create(bus, "order.**", id: "test-orders")
    {:ok, all_snapshot} = Jido.Signal.Bus.snapshot_create(bus, "**", id: "test-all")
    
    %{
      users: user_snapshot.id,
      orders: order_snapshot.id,
      all: all_snapshot.id
    }
  end
  
  def verify_user_creation_flow(bus, snapshot_ids) do
    {:ok, user_data} = Jido.Signal.Bus.snapshot_read(bus, snapshot_ids.users)
    
    user_signals = Map.values(user_data.signals)
    assert length(user_signals) == 2
    
    user_ids = Enum.map(user_signals, & &1.data.user_id)
    assert Enum.sort(user_ids) == [1, 2]
  end
  
  def verify_order_completion_flow(bus, snapshot_ids) do
    {:ok, order_data} = Jido.Signal.Bus.snapshot_read(bus, snapshot_ids.orders)
    
    order_signals = 
      order_data.signals
      |> Map.values()
      |> Enum.sort_by(& &1.time)
    
    assert length(order_signals) == 2
    assert List.first(order_signals).type == "order.created"
    assert List.last(order_signals).type == "order.completed"
  end
end
```

## Storage and Memory Considerations

### Memory Usage

Snapshots are stored in `:persistent_term` for efficiency, but this comes with considerations:

```elixir
# Monitor snapshot memory usage
defmodule SnapshotMonitor do
  def check_memory_usage(bus) do
    snapshots = Jido.Signal.Bus.snapshot_list(bus)
    
    total_memory = 
      Enum.reduce(snapshots, 0, fn snapshot, acc ->
        {:ok, data} = Jido.Signal.Bus.snapshot_read(bus, snapshot.id)
        snapshot_size = :erts_debug.size(data) * :erlang.system_info(:wordsize)
        acc + snapshot_size
      end)
    
    %{
      snapshot_count: length(snapshots),
      total_memory_bytes: total_memory,
      total_memory_mb: total_memory / (1024 * 1024),
      average_size_bytes: if(length(snapshots) > 0, do: total_memory / length(snapshots), else: 0)
    }
  end
  
  def cleanup_old_snapshots(bus, max_age_hours \\ 24) do
    cutoff_time = DateTime.utc_now() |> DateTime.add(-max_age_hours, :hour)
    snapshots = Jido.Signal.Bus.snapshot_list(bus)
    
    old_snapshots = 
      Enum.filter(snapshots, fn snapshot ->
        DateTime.compare(snapshot.created_at, cutoff_time) == :lt
      end)
    
    Enum.each(old_snapshots, fn snapshot ->
      Jido.Signal.Bus.snapshot_delete(bus, snapshot.id)
    end)
    
    length(old_snapshots)
  end
end
```

### Best Practices for Storage

```elixir
defmodule SnapshotBestPractices do
  # Limit snapshot size to prevent memory issues
  def create_bounded_snapshot(bus, path, max_signals \\ 1000) do
    Jido.Signal.Bus.snapshot_create(bus, path, batch_size: max_signals)
  end
  
  # Use descriptive IDs for important snapshots
  def create_named_snapshot(bus, path, purpose) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic)
    id = "#{purpose}-#{timestamp}"
    Jido.Signal.Bus.snapshot_create(bus, path, id: id)
  end
  
  # Implement snapshot rotation
  def rotate_snapshots(bus, prefix, max_count \\ 10) do
    snapshots = 
      Jido.Signal.Bus.snapshot_list(bus)
      |> Enum.filter(fn s -> String.starts_with?(s.id, prefix) end)
      |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
    
    # Keep only the most recent snapshots
    snapshots
    |> Enum.drop(max_count)
    |> Enum.each(fn snapshot ->
      Jido.Signal.Bus.snapshot_delete(bus, snapshot.id)
    end)
    
    length(snapshots) - max_count
  end
end
```

## Integration with Replay Functionality

### Using Snapshots for Targeted Replay

```elixir
defmodule SnapshotReplay do
  def replay_from_snapshot(bus, snapshot_id, subscription_path) do
    # Read the snapshot
    {:ok, snapshot_data} = Jido.Signal.Bus.snapshot_read(bus, snapshot_id)
    
    # Extract signals in chronological order
    ordered_signals = 
      snapshot_data.signals
      |> Map.values()
      |> Enum.sort_by(& &1.time)
    
    # Create a temporary subscription for replay
    {:ok, sub_id} = Jido.Signal.Bus.subscribe(bus, subscription_path, self())
    
    # Replay signals by re-publishing them
    Enum.each(ordered_signals, fn signal ->
      # Create a new signal with updated timestamp to avoid conflicts
      {:ok, replay_signal} = 
        Jido.Signal.new(%{
          type: signal.type,
          source: "replay:#{signal.source}",
          data: signal.data,
          metadata: Map.put(signal.metadata || %{}, "replayed_from", snapshot_id)
        })
      
      Jido.Signal.Bus.publish(bus, replay_signal)
    end)
    
    # Cleanup
    :ok = Jido.Signal.Bus.unsubscribe(bus, sub_id)
    
    {:ok, length(ordered_signals)}
  end
  
  def create_replay_checkpoint(bus, checkpoint_name) do
    # Create a comprehensive snapshot for replay purposes
    {:ok, snapshot_ref} = 
      Jido.Signal.Bus.snapshot_create(bus, "**", id: "checkpoint-#{checkpoint_name}")
    
    # Store checkpoint metadata
    checkpoint_info = %{
      snapshot_id: snapshot_ref.id,
      name: checkpoint_name,
      created_at: snapshot_ref.created_at,
      description: "Replay checkpoint: #{checkpoint_name}"
    }
    
    # You might want to persist this info externally
    File.write!(
      "checkpoints/#{checkpoint_name}.json", 
      Jason.encode!(checkpoint_info, pretty: true)
    )
    
    {:ok, checkpoint_info}
  end
end
```

## Best Practices

### Snapshot Management

1. **Use Descriptive IDs**: Include purpose and timestamp in snapshot IDs
   ```elixir
   id = "daily-report-#{Date.utc_today()}"
   id = "debug-session-#{System.system_time(:second)}"
   ```

2. **Implement Retention Policies**: Don't let snapshots accumulate indefinitely
   ```elixir
   # Daily cleanup job
   def cleanup_old_snapshots(bus) do
     SnapshotMonitor.cleanup_old_snapshots(bus, 48) # Keep 48 hours
   end
   ```

3. **Monitor Memory Usage**: Track snapshot storage consumption
   ```elixir
   # Regular memory checks
   memory_stats = SnapshotMonitor.check_memory_usage(bus)
   if memory_stats.total_memory_mb > 100 do
     Logger.warn("Snapshot memory usage high: #{memory_stats.total_memory_mb}MB")
   end
   ```

### Performance Optimization

1. **Limit Snapshot Size**: Use batch_size to prevent memory issues
   ```elixir
   {:ok, snapshot} = Jido.Signal.Bus.snapshot_create(bus, "**", batch_size: 1000)
   ```

2. **Use Specific Patterns**: Avoid wildcards when possible
   ```elixir
   # Better
   {:ok, snapshot} = Jido.Signal.Bus.snapshot_create(bus, "user.created")
   
   # Less efficient  
   {:ok, snapshot} = Jido.Signal.Bus.snapshot_create(bus, "**")
   ```

3. **Process Snapshots Efficiently**: Stream through large datasets
   ```elixir
   {:ok, snapshot_data} = Jido.Signal.Bus.snapshot_read(bus, snapshot_id)
   
   # Process in chunks to avoid memory spikes
   snapshot_data.signals
   |> Map.values()
   |> Stream.chunk_every(100)
   |> Enum.each(&process_signal_batch/1)
   ```

### Error Handling

```elixir
defmodule SafeSnapshotOperations do
  def safe_create_snapshot(bus, path, opts \\ []) do
    case Jido.Signal.Bus.snapshot_create(bus, path, opts) do
      {:ok, snapshot_ref} -> 
        Logger.info("Created snapshot: #{snapshot_ref.id}")
        {:ok, snapshot_ref}
      {:error, reason} -> 
        Logger.error("Failed to create snapshot: #{inspect(reason)}")
        {:error, reason}
    end
  end
  
  def safe_read_snapshot(bus, snapshot_id) do
    case Jido.Signal.Bus.snapshot_read(bus, snapshot_id) do
      {:ok, data} -> {:ok, data}
      {:error, :not_found} -> 
        Logger.warn("Snapshot not found: #{snapshot_id}")
        {:error, :not_found}
      {:error, reason} -> 
        Logger.error("Failed to read snapshot: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
```

Snapshots are a powerful tool for managing and analyzing your signal data. They provide the foundation for debugging, monitoring, testing, and replay scenarios while maintaining system performance and reliability.
