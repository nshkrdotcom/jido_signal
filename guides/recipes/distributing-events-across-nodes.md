# Recipe: Distributing Events Across Nodes

This guide demonstrates how to build a production-ready distributed event system using Jido.Signal's `:pubsub` dispatch adapter with Phoenix.PubSub. You'll learn to set up cluster-wide signal broadcasting, handle network partitions, and optimize performance for multi-node deployments.

## Overview

Distributed event systems enable multiple nodes in your Elixir cluster to share events seamlessly. This is essential for:

- Horizontally scaled applications that need consistent state
- Multi-region deployments with event synchronization
- Fault-tolerant systems that survive node failures
- Real-time applications requiring cluster-wide updates

## Setting Up Phoenix.PubSub

First, configure Phoenix.PubSub in your application. Add it to your `mix.exs` dependencies:

```elixir
def deps do
  [
    {:jido_signal, "~> 1.0"},
    {:phoenix_pubsub, "~> 2.1"},
    {:libcluster, "~> 3.3"}  # For automatic clustering
  ]
end
```

Configure PubSub in your application's supervision tree:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Phoenix PubSub for distributed messaging
      {Phoenix.PubSub, name: MyApp.PubSub},
      
      # Signal bus with distributed dispatch
      {Jido.Signal.Bus, name: :distributed_bus, 
        middleware: [
          {Jido.Signal.Bus.Middleware.Logger, level: :info}
        ]
      },
      
      # Auto-clustering (production setup)
      {Cluster.Supervisor, [topologies(), [name: MyApp.ClusterSupervisor]]},
      
      # Your other application processes
      MyApp.EventHandler,
      MyApp.OrderProcessor
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Clustering topologies
  defp topologies do
    [
      k8s: [
        strategy: Cluster.Strategy.Kubernetes,
        config: [
          mode: :dns,
          kubernetes_node_basename: "myapp",
          kubernetes_selector: "app=myapp",
          kubernetes_namespace: "production",
          polling_interval: 10_000
        ]
      ],
      
      # For local development
      epmd: [
        strategy: Cluster.Strategy.Epmd,
        config: [
          hosts: [:"node1@localhost", :"node2@localhost", :"node3@localhost"]
        ]
      ]
    ]
  end
end
```

## Basic Distributed Signal Setup

Create signal subscribers that can receive events from any node in the cluster:

```elixir
defmodule MyApp.EventHandler do
  use GenServer
  alias Jido.Signal.Bus

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    # Subscribe to distributed user events
    {:ok, _sub_id} = Bus.subscribe(:distributed_bus, "user.*", 
      dispatch: [
        # Local processing
        {:pid, target: self()},
        
        # Cluster-wide distribution
        {:pubsub, target: MyApp.PubSub, topic: "user_events"}
      ]
    )

    # Subscribe to PubSub messages from other nodes
    Phoenix.PubSub.subscribe(MyApp.PubSub, "user_events")
    
    {:ok, %{processed_signals: 0}}
  end

  # Handle signals from local bus
  def handle_info({:signal, signal}, state) do
    process_signal(signal, :local)
    {:noreply, %{state | processed_signals: state.processed_signals + 1}}
  end

  # Handle signals distributed via PubSub
  def handle_info(%Jido.Signal{} = signal, state) do
    process_signal(signal, :distributed)
    {:noreply, %{state | processed_signals: state.processed_signals + 1}}
  end

  defp process_signal(signal, source) do
    Logger.info("Processing #{signal.type} from #{source} (node: #{Node.self()})", 
      signal_id: signal.id,
      signal_type: signal.type,
      source: source
    )
    
    # Your business logic here
  end
end
```

## Publishing Distributed Events

Create events that automatically distribute across your cluster:

```elixir
defmodule MyApp.UserService do
  alias Jido.Signal.Bus
  alias Jido.Signal

  def create_user(user_params) do
    # Create user in database
    {:ok, user} = create_user_record(user_params)
    
    # Create signal with cluster-wide distribution
    {:ok, signal} = Signal.new(%{
      type: "user.created",
      source: "/users/service",
      data: %{
        user_id: user.id,
        email: user.email,
        created_at: user.inserted_at,
        node: Node.self()
      },
      jido_dispatch: [
        # Log locally for debugging
        {:logger, level: :info},
        
        # Distribute across cluster
        {:pubsub, target: MyApp.PubSub, topic: "user_events"}
      ]
    })
    
    # Publish to signal bus
    Bus.publish(:distributed_bus, [signal])
    
    {:ok, user}
  end

  def update_user(user_id, changes) do
    {:ok, user} = update_user_record(user_id, changes)
    
    {:ok, signal} = Signal.new(%{
      type: "user.updated",
      source: "/users/service",
      data: %{
        user_id: user.id,
        changes: changes,
        updated_at: user.updated_at,
        node: Node.self()
      }
    })
    
    # Use bus subscription dispatch instead of signal-level dispatch
    Bus.publish(:distributed_bus, [signal])
    
    {:ok, user}
  end

  defp create_user_record(params), do: {:ok, %{id: "user_123", email: "user@example.com", inserted_at: DateTime.utc_now()}}
  defp update_user_record(id, changes), do: {:ok, %{id: id, updated_at: DateTime.utc_now()}}
end
```

## Handling Node Failures and Network Partitions

Implement robust error handling for distributed scenarios:

```elixir
defmodule MyApp.DistributedEventHandler do
  use GenServer
  require Logger
  
  alias Jido.Signal.Bus
  alias Phoenix.PubSub

  @reconnect_interval 5_000
  @health_check_interval 30_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    # Monitor cluster membership
    :net_kernel.monitor_nodes(true)
    
    # Set up subscriptions with error handling
    setup_subscriptions()
    
    # Start health check timer
    schedule_health_check()
    
    {:ok, %{
      subscriptions: [],
      connected_nodes: [Node.self() | Node.list()],
      partition_detected: false,
      last_health_check: DateTime.utc_now()
    }}
  end

  # Handle node up/down events
  def handle_info({:nodeup, node}, state) do
    Logger.info("Node connected: #{node}")
    
    # Reconfigure subscriptions if needed
    setup_subscriptions()
    
    new_nodes = [node | state.connected_nodes] |> Enum.uniq()
    {:noreply, %{state | connected_nodes: new_nodes, partition_detected: false}}
  end

  def handle_info({:nodedown, node}, state) do
    Logger.warn("Node disconnected: #{node}")
    
    remaining_nodes = Enum.reject(state.connected_nodes, &(&1 == node))
    
    # Detect potential network partition
    partition_detected = length(remaining_nodes) < length(state.connected_nodes) / 2
    
    if partition_detected do
      Logger.error("Network partition detected! Connected nodes: #{inspect(remaining_nodes)}")
      handle_partition()
    end
    
    {:noreply, %{state | connected_nodes: remaining_nodes, partition_detected: partition_detected}}
  end

  # Health check for PubSub connectivity
  def handle_info(:health_check, state) do
    case health_check_pubsub() do
      :ok ->
        schedule_health_check()
        {:noreply, %{state | last_health_check: DateTime.utc_now()}}
        
      {:error, reason} ->
        Logger.error("PubSub health check failed: #{inspect(reason)}")
        
        # Attempt to reconnect
        Process.send_after(self(), :reconnect_pubsub, @reconnect_interval)
        schedule_health_check()
        
        {:noreply, state}
    end
  end

  def handle_info(:reconnect_pubsub, state) do
    Logger.info("Attempting to reconnect to PubSub...")
    setup_subscriptions()
    {:noreply, state}
  end

  # Handle distributed signals with deduplication
  def handle_info(%Jido.Signal{} = signal, state) do
    if should_process_signal?(signal) do
      process_signal_safely(signal)
    end
    
    {:noreply, state}
  end

  defp setup_subscriptions do
    try do
      # Subscribe to critical events
      PubSub.subscribe(MyApp.PubSub, "critical_events")
      PubSub.subscribe(MyApp.PubSub, "user_events")
      PubSub.subscribe(MyApp.PubSub, "order_events")
      
      # Subscribe via signal bus with distributed dispatch
      Bus.subscribe(:distributed_bus, "critical.**", 
        dispatch: {:pubsub, target: MyApp.PubSub, topic: "critical_events"}
      )
      
      Logger.info("Distributed subscriptions established")
    rescue
      error ->
        Logger.error("Failed to setup subscriptions: #{inspect(error)}")
        Process.send_after(self(), :reconnect_pubsub, @reconnect_interval)
    end
  end

  defp health_check_pubsub do
    # Send a ping message to verify PubSub connectivity
    test_message = %{ping: :health_check, node: Node.self(), timestamp: DateTime.utc_now()}
    
    case PubSub.broadcast(MyApp.PubSub, "health_check", test_message) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_partition do
    # During a partition, switch to local-only mode
    Logger.warn("Switching to partition-tolerant mode")
    
    # You might implement strategies like:
    # 1. Queue events for replay when partition heals
    # 2. Switch to local-only processing
    # 3. Activate conflict resolution mechanisms
  end

  defp should_process_signal?(signal) do
    # Implement deduplication logic
    # This could check a cache, database, or use signal.id
    not already_processed?(signal.id)
  end

  defp already_processed?(signal_id) do
    # Check if we've already processed this signal
    # Implementation depends on your caching strategy
    false
  end

  defp process_signal_safely(signal) do
    try do
      # Your signal processing logic here
      Logger.info("Processing distributed signal: #{signal.type}")
    rescue
      error ->
        Logger.error("Failed to process signal #{signal.id}: #{inspect(error)}")
        # Could implement retry logic or dead letter queue
    end
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval)
  end
end
```

## Message Ordering Considerations

Handle message ordering in distributed environments:

```elixir
defmodule MyApp.OrderedEventProcessor do
  use GenServer
  
  # Use vector clocks or sequence numbers for ordering
  def handle_info(%Jido.Signal{} = signal, state) do
    case ensure_ordering(signal, state) do
      {:process, updated_state} ->
        process_signal(signal)
        {:noreply, updated_state}
        
      {:queue, updated_state} ->
        # Signal arrived out of order, queue it
        {:noreply, updated_state}
    end
  end

  defp ensure_ordering(signal, state) do
    sequence_number = get_sequence_number(signal)
    expected_sequence = state.next_expected_sequence
    
    cond do
      sequence_number == expected_sequence ->
        # Signal is in order, process it and any queued signals
        new_state = %{state | next_expected_sequence: expected_sequence + 1}
        new_state = process_queued_signals(new_state)
        {:process, new_state}
        
      sequence_number > expected_sequence ->
        # Signal arrived early, queue it
        queued_signals = Map.put(state.queued_signals, sequence_number, signal)
        {:queue, %{state | queued_signals: queued_signals}}
        
      true ->
        # Duplicate or very old signal, ignore
        Logger.warn("Ignoring out-of-order signal: #{signal.id}")
        {:queue, state}
    end
  end

  defp get_sequence_number(signal) do
    # Extract sequence number from signal metadata
    signal.data[:sequence_number] || 0
  end

  defp process_queued_signals(state) do
    # Process any queued signals that are now in order
    Enum.reduce_while(Stream.iterate(state.next_expected_sequence, &(&1 + 1)), state, fn seq, acc ->
      case Map.get(acc.queued_signals, seq) do
        nil -> {:halt, acc}
        signal ->
          process_signal(signal)
          new_queued = Map.delete(acc.queued_signals, seq)
          {:cont, %{acc | next_expected_sequence: seq + 1, queued_signals: new_queued}}
      end
    end)
  end
end
```

## Complete Multi-Node Example

Here's a complete working example for a multi-node order processing system:

```elixir
# config/runtime.exs
import Config

if config_env() == :prod do
  config :myapp, :clustering,
    strategy: :kubernetes,
    kubernetes_selector: "app=myapp",
    kubernetes_namespace: System.get_env("KUBERNETES_NAMESPACE", "default")
end

# lib/myapp/orders/order_service.ex
defmodule MyApp.Orders.OrderService do
  alias Jido.Signal.Bus
  alias Jido.Signal

  def create_order(order_params) do
    # Create order with optimistic locking
    {:ok, order} = create_order_with_lock(order_params)
    
    # Publish creation event
    {:ok, signal} = Signal.new(%{
      type: "order.created",
      source: "/orders/service/#{Node.self()}",
      data: %{
        order_id: order.id,
        customer_id: order.customer_id,
        total: order.total,
        items: order.items,
        created_at: order.inserted_at,
        sequence_number: order.sequence_number,
        processing_node: Node.self()
      }
    })
    
    Bus.publish(:distributed_bus, [signal])
    
    {:ok, order}
  end

  def update_order_status(order_id, new_status) do
    {:ok, order} = update_status_with_lock(order_id, new_status)
    
    {:ok, signal} = Signal.new(%{
      type: "order.status_changed",
      source: "/orders/service/#{Node.self()}",
      data: %{
        order_id: order.id,
        old_status: order.previous_status,
        new_status: order.status,
        updated_at: order.updated_at,
        sequence_number: order.sequence_number,
        processing_node: Node.self()
      }
    })
    
    Bus.publish(:distributed_bus, [signal])
    
    {:ok, order}
  end

  defp create_order_with_lock(params) do
    # Implement optimistic locking for distributed consistency
    {:ok, %{id: "order_123", sequence_number: generate_sequence_number()}}
  end

  defp update_status_with_lock(order_id, status) do
    # Implement with version checking
    {:ok, %{id: order_id, status: status, sequence_number: generate_sequence_number()}}
  end

  defp generate_sequence_number do
    # Use a distributed sequence generator
    # Could be based on timestamps, node ID, and local counter
    :erlang.system_time(:microsecond)
  end
end

# lib/myapp/orders/inventory_service.ex
defmodule MyApp.Orders.InventoryService do
  use GenServer
  require Logger
  
  alias Jido.Signal.Bus

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    # Subscribe to order events across the cluster
    {:ok, _sub_id} = Bus.subscribe(:distributed_bus, "order.*", 
      dispatch: [
        {:pid, target: self()},
        {:pubsub, target: MyApp.PubSub, topic: "inventory_updates"}
      ]
    )
    
    # Subscribe to distributed inventory updates
    Phoenix.PubSub.subscribe(MyApp.PubSub, "inventory_updates")
    
    {:ok, %{reserved_inventory: %{}, processed_orders: MapSet.new()}}
  end

  def handle_info({:signal, %{type: "order.created"} = signal}, state) do
    handle_order_created(signal, state)
  end

  def handle_info({:signal, %{type: "order.cancelled"} = signal}, state) do
    handle_order_cancelled(signal, state)
  end

  def handle_info(%Jido.Signal{type: "inventory.reserved"} = signal, state) do
    # Handle inventory reservation from other nodes
    Logger.info("Inventory reserved on node #{signal.data.processing_node}: #{signal.data.order_id}")
    {:noreply, state}
  end

  defp handle_order_created(signal, state) do
    order_id = signal.data.order_id
    
    # Prevent duplicate processing
    if MapSet.member?(state.processed_orders, order_id) do
      {:noreply, state}
    else
      case reserve_inventory(signal.data.items) do
        {:ok, reservation} ->
          # Publish inventory reservation event
          {:ok, inventory_signal} = Jido.Signal.new(%{
            type: "inventory.reserved",
            source: "/inventory/service/#{Node.self()}",
            data: %{
              order_id: order_id,
              reservation_id: reservation.id,
              items: reservation.items,
              reserved_at: DateTime.utc_now(),
              processing_node: Node.self()
            },
            jido_cause: signal.id
          })
          
          Bus.publish(:distributed_bus, [inventory_signal])
          
          new_state = %{
            state | 
            reserved_inventory: Map.put(state.reserved_inventory, order_id, reservation),
            processed_orders: MapSet.put(state.processed_orders, order_id)
          }
          
          {:noreply, new_state}
          
        {:error, :insufficient_inventory} ->
          # Publish inventory shortage event
          {:ok, shortage_signal} = Jido.Signal.new(%{
            type: "inventory.insufficient",
            source: "/inventory/service/#{Node.self()}",
            data: %{
              order_id: order_id,
              requested_items: signal.data.items,
              processing_node: Node.self()
            },
            jido_cause: signal.id
          })
          
          Bus.publish(:distributed_bus, [shortage_signal])
          
          {:noreply, %{state | processed_orders: MapSet.put(state.processed_orders, order_id)}}
      end
    end
  end

  defp handle_order_cancelled(signal, state) do
    order_id = signal.data.order_id
    
    case Map.get(state.reserved_inventory, order_id) do
      nil -> 
        {:noreply, state}
        
      reservation ->
        release_inventory(reservation)
        
        {:ok, release_signal} = Jido.Signal.new(%{
          type: "inventory.released",
          source: "/inventory/service/#{Node.self()}",
          data: %{
            order_id: order_id,
            reservation_id: reservation.id,
            items: reservation.items,
            released_at: DateTime.utc_now(),
            processing_node: Node.self()
          },
          jido_cause: signal.id
        })
        
        Bus.publish(:distributed_bus, [release_signal])
        
        new_state = %{
          state | 
          reserved_inventory: Map.delete(state.reserved_inventory, order_id)
        }
        
        {:noreply, new_state}
    end
  end

  defp reserve_inventory(items) do
    # Implement distributed inventory reservation
    {:ok, %{id: "reservation_123", items: items}}
  end

  defp release_inventory(reservation) do
    Logger.info("Released inventory reservation: #{reservation.id}")
    :ok
  end
end
```

## Monitoring and Debugging

Set up comprehensive monitoring for your distributed signals:

```elixir
defmodule MyApp.DistributedMonitor do
  use GenServer
  require Logger

  @telemetry_events [
    [:jido_signal, :bus, :publish],
    [:jido_signal, :dispatch, :deliver],
    [:phoenix, :pubsub, :broadcast]
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    # Attach telemetry handlers
    Enum.each(@telemetry_events, &attach_telemetry_handler/1)
    
    # Start metrics collection
    schedule_metrics_collection()
    
    {:ok, %{
      signal_counts: %{},
      node_health: %{},
      last_activity: %{}
    }}
  end

  def handle_info(:collect_metrics, state) do
    metrics = collect_cluster_metrics()
    Logger.info("Cluster metrics", metrics)
    
    schedule_metrics_collection()
    {:noreply, state}
  end

  defp attach_telemetry_handler(event) do
    :telemetry.attach(
      "distributed_monitor_#{Enum.join(event, "_")}",
      event,
      &handle_telemetry_event/4,
      nil
    )
  end

  defp handle_telemetry_event([:jido_signal, :bus, :publish], measurements, metadata, _config) do
    Logger.debug("Signal published", [
      signal_type: metadata.signal.type,
      node: Node.self(),
      duration: measurements.duration
    ])
  end

  defp handle_telemetry_event([:jido_signal, :dispatch, :deliver], measurements, metadata, _config) do
    Logger.debug("Signal dispatched", [
      adapter: metadata.adapter,
      success: measurements.success,
      duration: measurements.duration,
      node: Node.self()
    ])
  end

  defp handle_telemetry_event([:phoenix, :pubsub, :broadcast], measurements, metadata, _config) do
    Logger.debug("PubSub broadcast", [
      topic: metadata.topic,
      node: Node.self(),
      duration: measurements.duration
    ])
  end

  defp collect_cluster_metrics do
    %{
      connected_nodes: [Node.self() | Node.list()],
      node_count: length([Node.self() | Node.list()]),
      uptime: :erlang.statistics(:wall_clock) |> elem(0),
      memory_usage: :erlang.memory(:total),
      signal_bus_status: check_signal_bus_health(),
      pubsub_status: check_pubsub_health()
    }
  end

  defp check_signal_bus_health do
    case GenServer.whereis(:distributed_bus) do
      nil -> :down
      pid when is_pid(pid) -> :healthy
    end
  end

  defp check_pubsub_health do
    case GenServer.whereis(MyApp.PubSub) do
      nil -> :down
      pid when is_pid(pid) -> :healthy
    end
  end

  defp schedule_metrics_collection do
    Process.send_after(self(), :collect_metrics, 30_000)
  end
end
```

## Performance Optimization

Optimize your distributed signal system for high throughput:

```elixir
defmodule MyApp.OptimizedDistributor do
  use GenServer
  
  # Batch signals for more efficient distribution
  @batch_size 100
  @batch_timeout 1000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    {:ok, %{
      signal_batch: [],
      batch_timer: nil,
      connection_pool: setup_connection_pool()
    }}
  end

  def distribute_signal(signal) do
    GenServer.cast(__MODULE__, {:add_to_batch, signal})
  end

  def handle_cast({:add_to_batch, signal}, state) do
    new_batch = [signal | state.signal_batch]
    
    cond do
      length(new_batch) >= @batch_size ->
        # Batch is full, send immediately
        send_batch(new_batch, state.connection_pool)
        {:noreply, %{state | signal_batch: [], batch_timer: nil}}
        
      state.batch_timer == nil ->
        # Start batch timer
        timer = Process.send_after(self(), :flush_batch, @batch_timeout)
        {:noreply, %{state | signal_batch: new_batch, batch_timer: timer}}
        
      true ->
        # Add to existing batch
        {:noreply, %{state | signal_batch: new_batch}}
    end
  end

  def handle_info(:flush_batch, state) do
    if length(state.signal_batch) > 0 do
      send_batch(state.signal_batch, state.connection_pool)
    end
    
    {:noreply, %{state | signal_batch: [], batch_timer: nil}}
  end

  defp send_batch(signals, _pool) do
    # Distribute batch via PubSub
    Phoenix.PubSub.broadcast(MyApp.PubSub, "batch_signals", %{
      signals: signals,
      batch_id: generate_batch_id(),
      node: Node.self(),
      timestamp: DateTime.utc_now()
    })
  end

  defp setup_connection_pool do
    # Configure connection pooling for HTTP dispatches if needed
    %{pool_size: 10, timeout: 5000}
  end

  defp generate_batch_id do
    :crypto.strong_rand_bytes(16) |> Base.encode64()
  end
end
```

## Best Practices

### 1. Signal Design for Distribution

Design signals with distribution in mind:

```elixir
defmodule MyApp.Signals.UserEvent do
  use Jido.Signal,
    type: "user.event.v1",
    schema: [
      # Always include node information
      processing_node: [type: :string, required: true],
      
      # Include sequence numbers for ordering
      sequence_number: [type: :integer, required: true],
      
      # Add checksums for data integrity
      checksum: [type: :string, required: true],
      
      # Include timing information
      occurred_at: [type: :utc_datetime, required: true],
      
      # Business data
      user_id: [type: :string, required: true],
      event_type: [type: :string, required: true],
      event_data: [type: :map, required: true]
    ]

  def new(attrs) do
    attrs_with_defaults = attrs
    |> Map.put_new(:processing_node, to_string(Node.self()))
    |> Map.put_new(:sequence_number, generate_sequence_number())
    |> Map.put_new(:occurred_at, DateTime.utc_now())
    |> Map.put(:checksum, calculate_checksum(attrs))
    
    super(attrs_with_defaults)
  end

  defp generate_sequence_number do
    # Use a distributed sequence number generator
    :erlang.system_time(:microsecond)
  end

  defp calculate_checksum(data) do
    data
    |> :erlang.term_to_binary()
    |> :crypto.hash(:sha256)
    |> Base.encode64()
  end
end
```

### 2. Error Recovery Strategies

Implement comprehensive error recovery:

```elixir
defmodule MyApp.DistributedErrorHandler do
  use GenServer
  
  def handle_info({:signal_delivery_failed, signal, reason}, state) do
    case categorize_error(reason) do
      :transient ->
        # Retry with exponential backoff
        schedule_retry(signal, state.retry_count + 1)
        
      :permanent ->
        # Send to dead letter queue
        send_to_dead_letter_queue(signal, reason)
        
      :partition ->
        # Queue for replay when partition heals
        queue_for_partition_recovery(signal)
    end
    
    {:noreply, state}
  end

  defp categorize_error(:timeout), do: :transient
  defp categorize_error(:noproc), do: :transient  
  defp categorize_error(:pubsub_not_found), do: :partition
  defp categorize_error(_), do: :permanent
end
```

### 3. Configuration Management

Manage configuration across environments:

```elixir
# config/runtime.exs
import Config

# Production clustering configuration
if config_env() == :prod do
  config :myapp, :distributed_signals,
    pubsub_name: MyApp.PubSub,
    cluster_strategy: :kubernetes,
    batch_size: String.to_integer(System.get_env("SIGNAL_BATCH_SIZE", "100")),
    batch_timeout: String.to_integer(System.get_env("SIGNAL_BATCH_TIMEOUT", "1000")),
    retry_attempts: String.to_integer(System.get_env("SIGNAL_RETRY_ATTEMPTS", "3")),
    health_check_interval: String.to_integer(System.get_env("HEALTH_CHECK_INTERVAL", "30000"))
end

# Development configuration
if config_env() == :dev do
  config :myapp, :distributed_signals,
    pubsub_name: MyApp.PubSub,
    cluster_strategy: :epmd,
    batch_size: 10,
    batch_timeout: 5000,
    retry_attempts: 2,
    health_check_interval: 10000
end
```

This comprehensive guide provides everything you need to build production-ready distributed event systems with Jido.Signal. The combination of Phoenix.PubSub's battle-tested clustering with Jido.Signal's rich event modeling creates a powerful foundation for scalable, fault-tolerant applications.

Remember to test your distributed setup thoroughly, monitor performance metrics, and implement appropriate error handling for your specific use case. Start with a simple setup and gradually add complexity as your requirements grow.
