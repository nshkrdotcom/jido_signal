# Advanced Guide: Journaling and Causality Tracking

The Jido.Signal Journal provides powerful capabilities for tracking signal causality, building audit trails, and debugging complex distributed workflows. This guide covers advanced techniques for leveraging the journal system to maintain comprehensive event histories and understand complex signal relationships.

## Understanding the Journal System

The `Jido.Signal.Journal` maintains a directed graph of signals, tracking both temporal and causal relationships. It provides:

- **Signal Storage** - Persistent storage of all signals with metadata
- **Causality Tracking** - Parent-child relationships between signals
- **Conversation Grouping** - Signals organized by subject/conversation
- **Temporal Ordering** - Chronological ordering of events
- **Query Interface** - Flexible filtering and search capabilities

## Creating and Managing Journals

### Basic Journal Setup

```elixir
# Create a new journal with default in-memory adapter
journal = Jido.Signal.Journal.new()

# Create with ETS adapter for better performance
{:ok, ets_pid} = Jido.Signal.Journal.Adapters.ETS.start_link("my_journal_")
journal = Jido.Signal.Journal.new(Jido.Signal.Journal.Adapters.ETS)
```

### Recording Signals with Causality

The core function `Journal.record/3` links signals via causality:

```elixir
# Create initial signal (no cause)
trigger_signal = Jido.Signal.new!(%{
  type: "user.login.attempted",
  source: "auth_service",
  subject: "user:123",
  data: %{user_id: 123, timestamp: DateTime.utc_now()}
})

{:ok, journal} = Jido.Signal.Journal.record(journal, trigger_signal)

# Create dependent signal caused by the first
auth_signal = Jido.Signal.new!(%{
  type: "user.authentication.success",
  source: "auth_service", 
  subject: "user:123",
  data: %{user_id: 123, session_id: "abc123"}
})

{:ok, journal} = Jido.Signal.Journal.record(journal, auth_signal, trigger_signal.id)

# Create another dependent signal
profile_signal = Jido.Signal.new!(%{
  type: "user.profile.loaded",
  source: "profile_service",
  subject: "user:123", 
  data: %{user_id: 123, profile_data: %{name: "John", email: "john@example.com"}}
})

{:ok, journal} = Jido.Signal.Journal.record(journal, profile_signal, auth_signal.id)
```

## Tracing Signal Relationships

### Getting Direct Relationships

```elixir
# Get the immediate cause of a signal
cause_signal = Jido.Signal.Journal.get_cause(journal, auth_signal.id)
# Returns: trigger_signal

# Get all immediate effects of a signal
effects = Jido.Signal.Journal.get_effects(journal, auth_signal.id)
# Returns: [profile_signal]
```

### Tracing Complete Causal Chains

```elixir
# Trace forward from root cause to all effects
forward_chain = Jido.Signal.Journal.trace_chain(journal, trigger_signal.id, :forward)
# Returns: [trigger_signal, auth_signal, profile_signal]

# Trace backward from effect to root cause
backward_chain = Jido.Signal.Journal.trace_chain(journal, profile_signal.id, :backward)
# Returns: [profile_signal, auth_signal, trigger_signal]
```

## Building Comprehensive Audit Trails

### Multi-Step Workflow Tracking

```elixir
defmodule OrderWorkflow do
  alias Jido.Signal.Journal
  
  def process_order(journal, order_data) do
    # Step 1: Order creation
    order_created = Jido.Signal.new!(%{
      type: "order.created",
      source: "order_service",
      subject: "order:#{order_data.id}",
      data: order_data
    })
    
    {:ok, journal} = Journal.record(journal, order_created)
    
    # Step 2: Inventory check (caused by order creation)
    inventory_checked = Jido.Signal.new!(%{
      type: "inventory.checked",
      source: "inventory_service", 
      subject: "order:#{order_data.id}",
      data: %{
        order_id: order_data.id,
        items_available: true,
        reserved_quantities: order_data.items
      }
    })
    
    {:ok, journal} = Journal.record(journal, inventory_checked, order_created.id)
    
    # Step 3: Payment processing (caused by inventory check)
    payment_processed = Jido.Signal.new!(%{
      type: "payment.processed",
      source: "payment_service",
      subject: "order:#{order_data.id}",
      data: %{
        order_id: order_data.id,
        amount: order_data.total,
        status: "completed",
        transaction_id: "txn_123"
      }
    })
    
    {:ok, journal} = Journal.record(journal, payment_processed, inventory_checked.id)
    
    # Step 4: Fulfillment initiated (caused by payment)
    fulfillment_started = Jido.Signal.new!(%{
      type: "fulfillment.started", 
      source: "fulfillment_service",
      subject: "order:#{order_data.id}",
      data: %{
        order_id: order_data.id,
        warehouse: "west_coast",
        estimated_ship_date: DateTime.add(DateTime.utc_now(), 1, :day)
      }
    })
    
    {:ok, journal} = Journal.record(journal, fulfillment_started, payment_processed.id)
    
    {journal, order_created.id}
  end
  
  def get_order_audit_trail(journal, order_signal_id) do
    # Get the complete forward chain from order creation
    Journal.trace_chain(journal, order_signal_id, :forward)
    |> Enum.map(fn signal ->
      %{
        step: signal.type,
        timestamp: signal.time,
        service: signal.source,
        data: signal.data,
        caused_by: Journal.get_cause(journal, signal.id)
      }
    end)
  end
end

# Usage
{journal, order_id} = OrderWorkflow.process_order(journal, %{
  id: "order_123",
  customer_id: "cust_456", 
  items: [%{sku: "ITEM001", quantity: 2}],
  total: 99.99
})

# Get complete audit trail
audit_trail = OrderWorkflow.get_order_audit_trail(journal, order_id)
```

### Conversation-Based Grouping

Signals with the same `subject` are automatically grouped into conversations:

```elixir
# All signals for a specific conversation
user_session_signals = Journal.get_conversation(journal, "user:123")

# Signals are returned in chronological order
user_session_signals
|> Enum.each(fn signal ->
  IO.puts("#{signal.time}: #{signal.type} - #{inspect(signal.data)}")
end)
```

## Complex Signal Relationship Patterns

### Branching Workflows

```elixir
defmodule BranchingWorkflow do
  alias Jido.Signal.Journal
  
  def handle_user_registration(journal, user_data) do
    # Root signal
    user_registered = Jido.Signal.new!(%{
      type: "user.registered",
      source: "user_service",
      subject: "user:#{user_data.id}",
      data: user_data
    })
    
    {:ok, journal} = Journal.record(journal, user_registered)
    
    # Branch 1: Email verification
    email_sent = Jido.Signal.new!(%{
      type: "email.verification.sent",
      source: "email_service",
      subject: "user:#{user_data.id}",
      data: %{user_id: user_data.id, email: user_data.email}
    })
    
    {:ok, journal} = Journal.record(journal, email_sent, user_registered.id)
    
    # Branch 2: Welcome notification
    welcome_sent = Jido.Signal.new!(%{
      type: "notification.welcome.sent",
      source: "notification_service", 
      subject: "user:#{user_data.id}",
      data: %{user_id: user_data.id, channel: "push"}
    })
    
    {:ok, journal} = Journal.record(journal, welcome_sent, user_registered.id)
    
    # Branch 3: Analytics tracking
    analytics_tracked = Jido.Signal.new!(%{
      type: "analytics.user.registered",
      source: "analytics_service",
      subject: "user:#{user_data.id}",
      data: %{user_id: user_data.id, source: user_data.registration_source}
    })
    
    {:ok, journal} = Journal.record(journal, analytics_tracked, user_registered.id)
    
    {journal, user_registered.id}
  end
  
  def analyze_registration_workflow(journal, root_signal_id) do
    # Get all effects to see branching
    effects = Journal.get_effects(journal, root_signal_id)
    
    %{
      root_event: root_signal_id,
      total_branches: length(effects),
      branches: Enum.map(effects, fn effect ->
        %{
          type: effect.type,
          service: effect.source,
          downstream_effects: length(Journal.get_effects(journal, effect.id))
        }
      end)
    }
  end
end
```

### Merging Workflows

```elixir
defmodule MergingWorkflow do
  alias Jido.Signal.Journal
  
  def handle_order_completion(journal, payment_signal_id, shipping_signal_id) do
    # Get both prerequisite signals
    payment_signal = Journal.query(journal, []) 
                    |> Enum.find(&(&1.id == payment_signal_id))
    shipping_signal = Journal.query(journal, [])
                     |> Enum.find(&(&1.id == shipping_signal_id))
    
    # Extract order ID from either signal
    order_id = payment_signal.data.order_id
    
    # Create completion signal that depends on both
    order_completed = Jido.Signal.new!(%{
      type: "order.completed",
      source: "order_service",
      subject: "order:#{order_id}",
      data: %{
        order_id: order_id,
        payment_confirmed: true,
        shipped: true,
        completed_at: DateTime.utc_now()
      },
      metadata: %{
        merged_from: [payment_signal_id, shipping_signal_id]
      }
    })
    
    # Note: Current Journal API supports single cause_id
    # For multiple causes, use metadata to track additional dependencies
    {:ok, journal} = Journal.record(journal, order_completed, payment_signal_id)
    
    {journal, order_completed.id}
  end
end
```

## Advanced Querying and Analysis

### Filtering by Criteria

```elixir
# Find all error signals in the last hour
recent_errors = Journal.query(journal, [
  type: "error.*",
  after: DateTime.add(DateTime.utc_now(), -1, :hour)
])

# Find all signals from a specific service
auth_service_signals = Journal.query(journal, [
  source: "auth_service"
])

# Find signals in a time range
daily_signals = Journal.query(journal, [
  after: DateTime.add(DateTime.utc_now(), -1, :day),
  before: DateTime.utc_now()
])
```

### Building Custom Analysis Functions

```elixir
defmodule JournalAnalytics do
  alias Jido.Signal.Journal
  
  def signal_frequency_by_type(journal) do
    Journal.query(journal, [])
    |> Enum.group_by(& &1.type)
    |> Enum.map(fn {type, signals} -> {type, length(signals)} end)
    |> Enum.sort_by(fn {_type, count} -> count end, :desc)
  end
  
  def average_processing_time(journal, workflow_type) do
    Journal.query(journal, type: workflow_type)
    |> Enum.map(fn root_signal ->
      chain = Journal.trace_chain(journal, root_signal.id, :forward)
      if length(chain) > 1 do
        first_time = parse_time(hd(chain).time)
        last_time = parse_time(List.last(chain).time)
        DateTime.diff(last_time, first_time, :millisecond)
      else
        0
      end
    end)
    |> Enum.reject(&(&1 == 0))
    |> case do
      [] -> 0
      times -> Enum.sum(times) / length(times)
    end
  end
  
  def find_orphaned_signals(journal) do
    all_signals = Journal.query(journal, [])
    
    Enum.filter(all_signals, fn signal ->
      cause = Journal.get_cause(journal, signal.id)
      effects = Journal.get_effects(journal, signal.id)
      
      # Signal with no cause and no effects (isolated)
      is_nil(cause) and Enum.empty?(effects)
    end)
  end
  
  def detect_long_chains(journal, threshold \\ 10) do
    Journal.query(journal, [])
    |> Enum.filter(fn signal ->
      # Check if this signal starts a long chain
      chain = Journal.trace_chain(journal, signal.id, :forward)
      length(chain) >= threshold
    end)
    |> Enum.map(fn signal ->
      chain_length = length(Journal.trace_chain(journal, signal.id, :forward))
      {signal.id, signal.type, chain_length}
    end)
  end
  
  defp parse_time(time_string) when is_binary(time_string) do
    {:ok, datetime, _} = DateTime.from_iso8601(time_string)
    datetime
  end
  
  defp parse_time(%DateTime{} = datetime), do: datetime
end
```

## Debugging Techniques

### Tracing Signal Flows

```elixir
defmodule JournalDebugger do
  alias Jido.Signal.Journal
  
  def debug_signal_flow(journal, signal_id) do
    case Journal.query(journal, []) |> Enum.find(&(&1.id == signal_id)) do
      nil ->
        IO.puts("Signal #{signal_id} not found")
        
      signal ->
        IO.puts("=== Signal Flow Debug ===")
        IO.puts("Root Signal: #{signal.type} (#{signal.id})")
        IO.puts("Time: #{signal.time}")
        IO.puts("Source: #{signal.source}")
        IO.puts("Data: #{inspect(signal.data)}")
        
        # Show cause chain
        IO.puts("\n--- Causal Chain (Backward) ---")
        backward_chain = Journal.trace_chain(journal, signal_id, :backward)
        
        backward_chain
        |> Enum.with_index()
        |> Enum.each(fn {s, index} ->
          indent = String.duplicate("  ", index)
          IO.puts("#{indent}#{index}: #{s.type} (#{s.source}) - #{s.time}")
        end)
        
        # Show effects chain  
        IO.puts("\n--- Effects Chain (Forward) ---")
        forward_chain = Journal.trace_chain(journal, signal_id, :forward)
        
        forward_chain
        |> Enum.with_index() 
        |> Enum.each(fn {s, index} ->
          indent = String.duplicate("  ", index)
          IO.puts("#{indent}#{index}: #{s.type} (#{s.source}) - #{s.time}")
        end)
        
        # Show conversation context
        if signal.subject do
          IO.puts("\n--- Conversation Context ---")
          conversation = Journal.get_conversation(journal, signal.subject)
          IO.puts("Total signals in conversation: #{length(conversation)}")
          
          conversation
          |> Enum.take(5)
          |> Enum.each(fn s ->
            marker = if s.id == signal_id, do: " <- TARGET", else: ""
            IO.puts("  #{s.type} (#{s.time})#{marker}")
          end)
        end
    end
  end
  
  def find_broken_chains(journal) do
    all_signals = Journal.query(journal, [])
    
    broken_chains = Enum.filter(all_signals, fn signal ->
      # Check if cause exists but points to non-existent signal
      case Journal.get_cause(journal, signal.id) do
        nil -> false
        cause -> 
          # Verify cause actually exists in journal
          Journal.query(journal, [])
          |> Enum.any?(&(&1.id == cause.id))
          |> Kernel.not()
      end
    end)
    
    if Enum.any?(broken_chains) do
      IO.puts("Found #{length(broken_chains)} signals with broken causal links:")
      Enum.each(broken_chains, fn signal ->
        IO.puts("  #{signal.type} (#{signal.id}) - broken cause reference")
      end)
    else
      IO.puts("No broken causal chains found")
    end
    
    broken_chains
  end
  
  def validate_temporal_consistency(journal) do
    inconsistent = Journal.query(journal, [])
    |> Enum.filter(fn signal ->
      case Journal.get_cause(journal, signal.id) do
        nil -> false
        cause ->
          signal_time = parse_time(signal.time)
          cause_time = parse_time(cause.time)
          DateTime.compare(signal_time, cause_time) == :lt
      end
    end)
    
    if Enum.any?(inconsistent) do
      IO.puts("Found #{length(inconsistent)} signals with temporal inconsistencies:")
      Enum.each(inconsistent, fn signal ->
        cause = Journal.get_cause(journal, signal.id)
        IO.puts("  #{signal.type} (#{signal.time}) caused by #{cause.type} (#{cause.time})")
      end)
    else
      IO.puts("All causal relationships are temporally consistent")
    end
    
    inconsistent
  end
  
  defp parse_time(time_string) when is_binary(time_string) do
    {:ok, datetime, _} = DateTime.from_iso8601(time_string)
    datetime
  end
  
  defp parse_time(%DateTime{} = datetime), do: datetime
end
```

### Performance Monitoring

```elixir
defmodule JournalPerformanceMonitor do
  alias Jido.Signal.Journal
  
  def analyze_journal_size(journal) do
    all_signals = Journal.query(journal, [])
    
    %{
      total_signals: length(all_signals),
      memory_usage: :erlang.process_info(self(), :memory),
      oldest_signal: all_signals |> Enum.min_by(& &1.time, fn -> nil end),
      newest_signal: all_signals |> Enum.max_by(& &1.time, fn -> nil end),
      avg_data_size: calculate_avg_data_size(all_signals)
    }
  end
  
  def benchmark_operations(journal, iterations \\ 1000) do
    test_signal = Jido.Signal.new!(%{
      type: "benchmark.test",
      source: "benchmark",
      data: %{test: true}
    })
    
    # Benchmark record operation
    {record_time, _} = :timer.tc(fn ->
      Enum.reduce(1..iterations, journal, fn _i, acc_journal ->
        signal = Jido.Signal.new!(%{
          type: "benchmark.test.#{:rand.uniform(1000)}",
          source: "benchmark",
          data: %{iteration: _i}
        })
        
        {:ok, new_journal} = Journal.record(acc_journal, signal)
        new_journal
      end)
    end)
    
    # Benchmark query operation
    {query_time, _} = :timer.tc(fn ->
      Enum.each(1..iterations, fn _i ->
        Journal.query(journal, source: "benchmark")
      end)
    end)
    
    %{
      record_time_ms: record_time / 1000,
      query_time_ms: query_time / 1000,
      records_per_second: iterations / (record_time / 1_000_000),
      queries_per_second: iterations / (query_time / 1_000_000)
    }
  end
  
  defp calculate_avg_data_size(signals) do
    if Enum.empty?(signals) do
      0
    else
      total_size = signals
      |> Enum.map(fn signal ->
        signal.data
        |> :erlang.term_to_binary()
        |> byte_size()
      end)
      |> Enum.sum()
      
      total_size / length(signals)
    end
  end
end
```

## Best Practices for Journal Management

### 1. Consistent Causality Modeling

```elixir
# Always model clear cause-effect relationships
defmodule WorkflowPatterns do
  # ✅ Good: Clear parent-child relationships
  def record_with_clear_causality(journal, parent_id, child_data) do
    child_signal = Jido.Signal.new!(child_data)
    Journal.record(journal, child_signal, parent_id)
  end
  
  # ❌ Avoid: Unclear or missing causality
  def record_without_causality(journal, signal_data) do
    signal = Jido.Signal.new!(signal_data)
    Journal.record(journal, signal) # Missing important causal context
  end
end
```

### 2. Meaningful Signal Types and Sources

```elixir
# ✅ Good: Hierarchical, descriptive types
"user.authentication.success"
"order.payment.processed" 
"inventory.item.reserved"

# ❌ Avoid: Generic or unclear types
"event"
"success"
"update"
```

### 3. Conversation Grouping Strategy

```elixir
# ✅ Good: Consistent subject naming
subject: "user:#{user_id}"
subject: "order:#{order_id}"
subject: "session:#{session_id}"

# ❌ Avoid: Inconsistent or missing subjects
subject: "user_123"  # Different format
subject: nil         # Missing grouping context
```

### 4. Performance Considerations

```elixir
# For high-volume applications, use ETS adapter
{:ok, ets_pid} = Jido.Signal.Journal.Adapters.ETS.start_link("production_journal_")
journal = Jido.Signal.Journal.new(Jido.Signal.Journal.Adapters.ETS)

# Implement journal rotation for long-running systems
defmodule JournalRotation do
  def rotate_journal(old_journal, cutoff_date) do
    # Archive old signals
    old_signals = Journal.query(old_journal, before: cutoff_date)
    archive_signals(old_signals)
    
    # Create new journal with recent signals only
    recent_signals = Journal.query(old_journal, after: cutoff_date)
    new_journal = Journal.new()
    
    Enum.reduce(recent_signals, new_journal, fn signal, acc ->
      cause_id = case Journal.get_cause(old_journal, signal.id) do
        nil -> nil
        cause -> if after_cutoff?(cause, cutoff_date), do: cause.id, else: nil
      end
      
      {:ok, updated_journal} = Journal.record(acc, signal, cause_id)
      updated_journal
    end)
  end
  
  defp after_cutoff?(signal, cutoff_date) do
    signal_time = parse_time(signal.time)
    DateTime.compare(signal_time, cutoff_date) == :gt
  end
  
  defp archive_signals(signals) do
    # Implement your archival strategy here
    # E.g., write to database, file system, etc.
  end
  
  defp parse_time(time_string) when is_binary(time_string) do
    {:ok, datetime, _} = DateTime.from_iso8601(time_string)
    datetime
  end
end
```

## Conclusion

The Jido.Signal Journal provides a robust foundation for tracking complex signal relationships and building comprehensive audit trails. By following the patterns and techniques outlined in this guide, you can:

- Build clear causal chains that make debugging easier
- Create comprehensive audit trails for compliance and analysis
- Debug complex distributed workflows effectively
- Monitor and optimize journal performance
- Maintain data consistency across your event-driven architecture

The journal system's flexibility allows it to adapt to various use cases while maintaining the integrity and traceability that are essential for reliable distributed systems.
