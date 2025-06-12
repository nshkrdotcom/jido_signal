# Distributed Clusters Use Case: Multi-Region E-Commerce Platform

Let me analyze how Jido Signal would work in a distributed cluster scenario and evaluate its suitability.

## Use Case: Global E-Commerce Platform

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Global E-Commerce Architecture                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Region: US-East           Region: EU-West           Region: APAC           │
│  ┌─────────────────┐      ┌─────────────────┐      ┌─────────────────┐     │
│  │   Node Cluster  │      │   Node Cluster  │      │   Node Cluster  │     │
│  │                 │      │                 │      │                 │     │
│  │  ┌───────────┐  │      │  ┌───────────┐  │      │  ┌───────────┐  │     │
│  │  │Orders Bus │  │◄────►│  │Orders Bus │  │◄────►│  │Orders Bus │  │     │
│  │  └───────────┘  │      │  └───────────┘  │      │  └───────────┘  │     │
│  │  ┌───────────┐  │      │  ┌───────────┐  │      │  ┌───────────┐  │     │
│  │  │Inventory  │  │◄────►│  │Inventory  │  │◄────►│  │Inventory  │  │     │
│  │  │    Bus    │  │      │  │    Bus    │  │      │  │    Bus    │  │     │
│  │  └───────────┘  │      │  └───────────┘  │      │  └───────────┘  │     │
│  │  ┌───────────┐  │      │  ┌───────────┐  │      │  ┌───────────┐  │     │
│  │  │Payments   │  │◄────►│  │Payments   │  │◄────►│  │Payments   │  │     │
│  │  │    Bus    │  │      │  │    Bus    │  │      │  │    Bus    │  │     │
│  │  └───────────┘  │      │  └───────────┘  │      │  └───────────┘  │     │
│  └─────────────────┘      └─────────────────┘      └─────────────────┘     │
│                                                                             │
│              ▲                        ▲                        ▲            │
│              │                        │                        │            │
│              ▼                        ▼                        ▼            │
│  ┌─────────────────┐      ┌─────────────────┐      ┌─────────────────┐     │
│  │Global Event Log │      │Global Event Log │      │Global Event Log │     │
│  │  (Replicated)   │◄────►│  (Replicated)   │◄────►│  (Replicated)   │     │
│  └─────────────────┘      └─────────────────┘      └─────────────────┘     │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Analysis: Current Framework Capabilities

### ✅ **Strengths for Distributed Systems**

#### 1. **Already Distributed-Ready Components**
```elixir
# Jido Signal has strong distributed foundations
defmodule DistributedCapabilities do
  def current_strengths do
    [
      # CloudEvents compliance enables cross-system communication
      :cloudevents_standard,
      
      # HTTP dispatch adapter for cross-region communication
      :http_dispatch,
      
      # Webhook adapter for bidirectional cluster communication
      :webhook_integration,
      
      # PubSub adapter can work with distributed PubSub systems
      :distributed_pubsub,
      
      # Journal system can track cross-cluster causality
      :causality_tracking,
      
      # UUID7 IDs are globally unique and time-ordered
      :global_unique_ids,
      
      # Middleware pipeline supports cross-cutting concerns
      :middleware_hooks,
      
      # Serialization system supports multiple formats
      :pluggable_serialization
    ]
  end
end
```

#### 2. **Natural Fit for Event Sourcing Across Clusters**
```elixir
# Cross-region event replication works well
defmodule CrossRegionEventSourcing do
  def replicate_critical_events do
    # Events that need global consistency
    Router.new([
      {"order.placed", [
        # Local processing
        {:named, target: {:name, :local_order_processor}},
        
        # Cross-region replication
        {:http, url: "https://eu-cluster.company.com/events/replicate"},
        {:http, url: "https://apac-cluster.company.com/events/replicate"},
        
        # Global event store
        {:webhook, url: "https://global-eventstore.company.com/ingest"}
      ]},
      
      {"inventory.reserved", [
        # Update local inventory
        {:named, target: {:name, :local_inventory}},
        
        # Notify other regions
        {:http, url: "https://eu-cluster.company.com/inventory/sync"},
        {:http, url: "https://apac-cluster.company.com/inventory/sync"}
      ]}
    ])
  end
end
```

### ❌ **Current Limitations for Distributed Clusters**

#### 1. **Single-Node Bus Architecture**
```elixir
# Current limitation: Bus is a single GenServer
defmodule CurrentLimitation do
  # ❌ This doesn't scale across nodes in a cluster
  def current_bus_architecture do
    %{
      bus_process: :single_genserver,        # Single point of failure
      state_location: :local_memory,         # Not shared across nodes
      subscription_storage: :local_process,  # Node-specific
      signal_log: :local_memory,            # Not replicated
      snapshots: :persistent_term_local     # Node-local storage
    }
  end
end
```

#### 2. **No Built-in Cluster Coordination**
```elixir
# Missing distributed coordination primitives
defmodule MissingCapabilities do
  def distributed_gaps do
    [
      :cluster_membership_management,
      :distributed_consensus,
      :leader_election,
      :partition_tolerance,
      :eventual_consistency_handling,
      :cross_node_subscription_sync,
      :distributed_signal_ordering,
      :cluster_wide_snapshots,
      :automatic_failover
    ]
  end
end
```

## Required Modifications for Distributed Clusters

### 1. **Distributed Bus Architecture**

```elixir
defmodule Jido.Signal.DistributedBus do
  @moduledoc """
  Distributed version of Signal Bus that coordinates across cluster nodes.
  
  Features:
  - Distributed state via :riak_core or :partisan
  - Cross-node subscription synchronization
  - Cluster-wide signal ordering
  - Partition tolerance with eventual consistency
  """
  
  use GenServer
  
  # Distributed state structure
  defstruct [
    :cluster_id,
    :node_id,
    :ring,                    # Consistent hashing ring
    :local_bus,               # Local Jido.Signal.Bus
    :peer_connections,        # Connections to other nodes
    :replication_factor,      # How many nodes replicate each signal
    :consistency_level        # :strong, :eventual, :weak
  ]
  
  def start_link(opts) do
    cluster_id = Keyword.fetch!(opts, :cluster_id)
    node_id = Keyword.get(opts, :node_id, Node.self())
    
    GenServer.start_link(__MODULE__, {cluster_id, node_id, opts}, 
                        name: via_tuple(cluster_id))
  end
  
  def init({cluster_id, node_id, opts}) do
    # Initialize local bus
    {:ok, local_bus} = Jido.Signal.Bus.start_link(
      name: :"local_bus_#{node_id}",
      middleware: distributed_middleware()
    )
    
    # Join cluster
    :ok = join_cluster(cluster_id, node_id)
    
    state = %__MODULE__{
      cluster_id: cluster_id,
      node_id: node_id,
      local_bus: local_bus,
      replication_factor: Keyword.get(opts, :replication_factor, 3),
      consistency_level: Keyword.get(opts, :consistency_level, :eventual)
    }
    
    {:ok, state}
  end
  
  # Distributed signal publishing
  def publish(distributed_bus, signals, opts \\ []) do
    consistency = Keyword.get(opts, :consistency, :eventual)
    
    case consistency do
      :strong -> publish_strong_consistency(distributed_bus, signals)
      :eventual -> publish_eventual_consistency(distributed_bus, signals)
      :weak -> publish_weak_consistency(distributed_bus, signals)
    end
  end
  
  # Strong consistency: All replicas must acknowledge
  defp publish_strong_consistency(distributed_bus, signals) do
    GenServer.call(distributed_bus, {:publish_strong, signals})
  end
  
  # Eventual consistency: Publish locally, replicate async
  defp publish_eventual_consistency(distributed_bus, signals) do
    GenServer.call(distributed_bus, {:publish_eventual, signals})
  end
  
  # Weak consistency: Fire and forget
  defp publish_weak_consistency(distributed_bus, signals) do
    GenServer.cast(distributed_bus, {:publish_weak, signals})
  end
  
  # GenServer callbacks for distributed coordination
  def handle_call({:publish_strong, signals}, from, state) do
    # 1. Determine replica nodes using consistent hashing
    replica_nodes = determine_replica_nodes(signals, state)
    
    # 2. Send to all replicas and wait for quorum
    tasks = Enum.map(replica_nodes, fn node ->
      Task.async(fn ->
        :rpc.call(node, Jido.Signal.Bus, :publish, [state.local_bus, signals])
      end)
    end)
    
    # 3. Wait for quorum (majority) of replicas
    quorum_size = div(length(replica_nodes), 2) + 1
    
    case wait_for_quorum(tasks, quorum_size) do
      {:ok, _results} ->
        {:reply, {:ok, :replicated}, state}
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end
  
  def handle_call({:publish_eventual, signals}, _from, state) do
    # 1. Publish locally immediately
    {:ok, _} = Jido.Signal.Bus.publish(state.local_bus, signals)
    
    # 2. Async replication to other nodes
    replica_nodes = determine_replica_nodes(signals, state)
    
    Enum.each(replica_nodes, fn node ->
      if node != Node.self() do
        Task.start(fn ->
          :rpc.cast(node, __MODULE__, :replicate_signals, [signals, state.cluster_id])
        end)
      end
    end)
    
    {:reply, {:ok, :published_locally}, state}
  end
  
  def handle_cast({:publish_weak, signals}, state) do
    # Fire and forget - no guarantees
    spawn(fn ->
      Jido.Signal.Bus.publish(state.local_bus, signals)
    end)
    
    {:noreply, state}
  end
  
  # Handle incoming replicated signals
  def handle_cast({:replicate_signals, signals, source_node}, state) do
    # Add replication metadata
    replicated_signals = Enum.map(signals, fn signal ->
      %{signal | 
        data: Map.put(signal.data, :__replication__, %{
          source_node: source_node,
          replicated_at: DateTime.utc_now()
        })
      }
    end)
    
    # Publish to local bus
    Jido.Signal.Bus.publish(state.local_bus, replicated_signals)
    
    {:noreply, state}
  end
  
  # Distributed subscription management
  def subscribe(distributed_bus, path, opts) do
    replicate_subscription = Keyword.get(opts, :replicate, true)
    
    case GenServer.call(distributed_bus, {:subscribe, path, opts}) do
      {:ok, subscription_id} when replicate_subscription ->
        # Replicate subscription to other nodes
        replicate_subscription_to_cluster(distributed_bus, subscription_id, path, opts)
        {:ok, subscription_id}
      
      result ->
        result
    end
  end
  
  # Private helpers
  defp distributed_middleware do
    [
      {DistributedLogger, []},
      {ClusterCoordinator, []},
      {ReplicationMiddleware, []}
    ]
  end
  
  defp determine_replica_nodes(signals, state) do
    # Use consistent hashing to determine which nodes should store these signals
    primary_signal = List.first(signals)
    hash_key = "#{primary_signal.type}:#{primary_signal.subject || primary_signal.id}"
    
    ConsistentHashing.get_nodes(state.ring, hash_key, state.replication_factor)
  end
  
  defp wait_for_quorum(tasks, quorum_size) do
    # Wait for majority of replicas to respond
    # Implementation would handle timeouts and failures
    results = Task.yield_many(tasks, 5000)
    
    successful = Enum.count(results, fn {_task, result} -> 
      match?({:ok, _}, result)
    end)
    
    if successful >= quorum_size do
      {:ok, results}
    else
      {:error, :quorum_not_reached}
    end
  end
  
  defp join_cluster(cluster_id, node_id) do
    # Join the distributed cluster
    # Implementation would use :riak_core, :partisan, or similar
    :ok
  end
  
  defp replicate_subscription_to_cluster(distributed_bus, subscription_id, path, opts) do
    # Replicate subscription to other cluster nodes
    # So signals matching this path get routed to all interested nodes
    Task.start(fn ->
      cluster_nodes = get_cluster_nodes(distributed_bus)
      
      Enum.each(cluster_nodes, fn node ->
        if node != Node.self() do
          :rpc.cast(node, __MODULE__, :add_remote_subscription, 
                   [subscription_id, path, opts, Node.self()])
        end
      end)
    end)
  end
  
  defp get_cluster_nodes(_distributed_bus) do
    # Get list of active cluster nodes
    # Implementation depends on cluster management library
    [Node.self() | Node.list()]
  end
end
```

### 2. **Distributed Journal with Causal Consistency**

```elixir
defmodule Jido.Signal.DistributedJournal do
  @moduledoc """
  Distributed journal that maintains causal consistency across cluster nodes.
  
  Uses vector clocks and causal ordering to ensure proper event sequencing
  even in the presence of network partitions.
  """
  
  use GenServer
  
  defstruct [
    :cluster_id,
    :node_id,
    :vector_clock,
    :local_journal,
    :peer_journals,
    :consistency_level
  ]
  
  def start_link(opts) do
    cluster_id = Keyword.fetch!(opts, :cluster_id)
    node_id = Keyword.get(opts, :node_id, Node.self())
    
    GenServer.start_link(__MODULE__, {cluster_id, node_id, opts})
  end
  
  def init({cluster_id, node_id, opts}) do
    # Initialize local journal
    local_journal = Jido.Signal.Journal.new(
      Keyword.get(opts, :adapter, Jido.Signal.Journal.Adapters.ETS)
    )
    
    state = %__MODULE__{
      cluster_id: cluster_id,
      node_id: node_id,
      vector_clock: VectorClock.new(node_id),
      local_journal: local_journal,
      peer_journals: %{},
      consistency_level: Keyword.get(opts, :consistency, :causal)
    }
    
    {:ok, state}
  end
  
  def record(distributed_journal, signal, cause_id \\ nil, opts \\ []) do
    consistency = Keyword.get(opts, :consistency, :causal)
    
    case consistency do
      :causal -> record_causal_consistency(distributed_journal, signal, cause_id)
      :strong -> record_strong_consistency(distributed_journal, signal, cause_id)
      :eventual -> record_eventual_consistency(distributed_journal, signal, cause_id)
    end
  end
  
  # Causal consistency: Respect causal ordering
  defp record_causal_consistency(distributed_journal, signal, cause_id) do
    GenServer.call(distributed_journal, {:record_causal, signal, cause_id})
  end
  
  def handle_call({:record_causal, signal, cause_id}, _from, state) do
    # 1. Increment vector clock
    new_vector_clock = VectorClock.increment(state.vector_clock, state.node_id)
    
    # 2. Add vector clock to signal metadata
    enhanced_signal = %{signal |
      data: Map.put(signal.data, :__vector_clock__, new_vector_clock)
    }
    
    # 3. Check causal dependencies
    case validate_causal_dependencies(enhanced_signal, cause_id, state) do
      :ok ->
        # 4. Record locally
        {:ok, updated_journal} = Jido.Signal.Journal.record(
          state.local_journal, enhanced_signal, cause_id
        )
        
        # 5. Replicate to peers with causal ordering
        replicate_with_causal_order(enhanced_signal, cause_id, state)
        
        new_state = %{state | 
          vector_clock: new_vector_clock,
          local_journal: updated_journal
        }
        
        {:reply, {:ok, enhanced_signal}, new_state}
      
      {:error, :causal_dependency_missing} ->
        # Wait for missing dependencies
        {:reply, {:error, :waiting_for_dependencies}, state}
    end
  end
  
  # Distributed causality tracking
  def get_causal_chain(distributed_journal, signal_id) do
    GenServer.call(distributed_journal, {:get_causal_chain, signal_id})
  end
  
  def handle_call({:get_causal_chain, signal_id}, _from, state) do
    # 1. Get local chain
    local_chain = Jido.Signal.Journal.trace_chain(
      state.local_journal, signal_id, :backward
    )
    
    # 2. Query peer nodes for missing causal links
    distributed_chain = merge_distributed_causal_chains(
      local_chain, signal_id, state
    )
    
    {:reply, {:ok, distributed_chain}, state}
  end
  
  # Handle incoming replicated signals
  def handle_cast({:replicate_signal, signal, cause_id, source_node}, state) do
    # Check if we can apply this signal (causal dependencies satisfied)
    case can_apply_signal?(signal, cause_id, state) do
      true ->
        # Apply immediately
        {:ok, updated_journal} = Jido.Signal.Journal.record(
          state.local_journal, signal, cause_id
        )
        
        # Update vector clock
        signal_vector_clock = signal.data[:__vector_clock__]
        new_vector_clock = VectorClock.merge(state.vector_clock, signal_vector_clock)
        
        new_state = %{state |
          local_journal: updated_journal,
          vector_clock: new_vector_clock
        }
        
        {:noreply, new_state}
      
      false ->
        # Buffer for later application
        buffer_signal_for_ordering(signal, cause_id, source_node, state)
        {:noreply, state}
    end
  end
  
  # Private helpers
  defp validate_causal_dependencies(signal, cause_id, state) do
    case cause_id do
      nil -> :ok
      id ->
        case Jido.Signal.Journal.get_signal(state.local_journal, id) do
          {:ok, _cause_signal} -> :ok
          {:error, :not_found} ->
            # Check if we're waiting for this dependency from peers
            check_peer_nodes_for_dependency(id, state)
        end
    end
  end
  
  defp replicate_with_causal_order(signal, cause_id, state) do
    cluster_nodes = get_cluster_nodes()
    
    Enum.each(cluster_nodes, fn node ->
      if node != Node.self() do
        :rpc.cast(node, __MODULE__, :replicate_signal, 
                 [signal, cause_id, Node.self()])
      end
    end)
  end
  
  defp can_apply_signal?(signal, cause_id, state) do
    case cause_id do
      nil -> true
      id ->
        # Check if cause exists locally
        case Jido.Signal.Journal.get_signal(state.local_journal, id) do
          {:ok, _} -> true
          {:error, :not_found} -> false
        end
    end
  end
  
  defp merge_distributed_causal_chains(local_chain, signal_id, state) do
    # Query other nodes for causal chain segments
    cluster_nodes = get_cluster_nodes()
    
    peer_chains = Enum.map(cluster_nodes, fn node ->
      if node != Node.self() do
        case :rpc.call(node, __MODULE__, :get_local_causal_chain, [signal_id]) do
          {:ok, chain} -> chain
          _ -> []
        end
      else
        []
      end
    end)
    
    # Merge chains while preserving causal ordering
    merge_causal_chains([local_chain | peer_chains])
  end
  
  defp merge_causal_chains(chains) do
    # Merge multiple causal chains using vector clock ordering
    chains
    |> List.flatten()
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(fn signal ->
      vector_clock = signal.data[:__vector_clock__]
      VectorClock.to_comparable(vector_clock)
    end)
  end
  
  defp get_cluster_nodes do
    [Node.self() | Node.list()]
  end
end
```

### 3. **Cluster-Aware Router with Distributed Routing**

```elixir
defmodule Jido.Signal.DistributedRouter do
  @moduledoc """
  Distributed router that coordinates signal routing across cluster nodes.
  
  Features:
  - Consistent hashing for signal distribution
  - Cross-node subscription awareness
  - Load balancing across cluster
  - Partition tolerance
  """
  
  use GenServer
  
  defstruct [
    :cluster_id,
    :node_id,
    :local_router,
    :distributed_routes,
    :hash_ring,
    :subscription_registry
  ]
  
  def start_link(opts) do
    cluster_id = Keyword.fetch!(opts, :cluster_id)
    node_id = Keyword.get(opts, :node_id, Node.self())
    
    GenServer.start_link(__MODULE__, {cluster_id, node_id, opts})
  end
  
  def init({cluster_id, node_id, opts}) do
    # Initialize local router
    {:ok, local_router} = Jido.Signal.Router.new(
      Keyword.get(opts, :routes, [])
    )
    
    # Initialize distributed routing components
    hash_ring = ConsistentHashing.new()
    subscription_registry = DistributedRegistry.new(cluster_id)
    
    state = %__MODULE__{
      cluster_id: cluster_id,
      node_id: node_id,
      local_router: local_router,
      distributed_routes: %{},
      hash_ring: hash_ring,
      subscription_registry: subscription_registry
    }
    
    # Join cluster routing
    :ok = join_routing_cluster(cluster_id, node_id)
    
    {:ok, state}
  end
  
  # Distributed routing with load balancing
  def route(distributed_router, signal, opts \\ []) do
    distribution_strategy = Keyword.get(opts, :strategy, :consistent_hash)
    
    GenServer.call(distributed_router, {:route_distributed, signal, distribution_strategy})
  end
  
  def handle_call({:route_distributed, signal, strategy}, _from, state) do
    case strategy do
      :consistent_hash ->
        route_with_consistent_hashing(signal, state)
      
      :broadcast ->
        route_with_broadcast(signal, state)
      
      :local_first ->
        route_with_local_preference(signal, state)
      
      :load_balanced ->
        route_with_load_balancing(signal, state)
    end
  end
  
  # Consistent hashing strategy
  defp route_with_consistent_hashing(signal, state) do
    # Determine target nodes based on signal characteristics
    hash_key = generate_routing_hash(signal)
    target_nodes = ConsistentHashing.get_nodes(state.hash_ring, hash_key, 3)
    
    # Route to local router if this node is a target
    local_targets = if Node.self() in target_nodes do
      case Jido.Signal.Router.route(state.local_router, signal) do
        {:ok, targets} -> targets
        {:error, _} -> []
      end
    else
      []
    end
    
    # Route to remote nodes
    remote_results = Enum.flat_map(target_nodes, fn node ->
      if node != Node.self() do
        case :rpc.call(node, Jido.Signal.Router, :route, [signal]) do
          {:ok, targets} -> 
            # Add node information to targets
            Enum.map(targets, fn target -> {node, target} end)
          {:error, _} -> 
            []
        end
      else
        []
      end
    end)
    
    all_targets = local_targets ++ remote_results
    {:reply, {:ok, all_targets}, state}
  end
  
  # Broadcast strategy - route to all nodes
  defp route_with_broadcast(signal, state) do
    cluster_nodes = get_cluster_nodes()
    
    all_results = Enum.flat_map(cluster_nodes, fn node ->
      router = if node == Node.self() do
        state.local_router
      else
        # Remote call to node's router
        case :rpc.call(node, __MODULE__, :get_local_routes, [signal]) do
          {:ok, targets} -> targets
          {:error, _} -> []
        end
      end
      
      case router do
        %Jido.Signal.Router{} ->
          case Jido.Signal.Router.route(router, signal) do
            {:ok, targets} -> Enum.map(targets, fn t -> {node, t} end)
            {:error, _} -> []
          end
        targets when is_list(targets) ->
          Enum.map(targets, fn t -> {node, t} end)
        _ ->
          []
      end
    end)
    
    {:reply, {:ok, all_results}, state}
  end
  
  # Load balanced routing
  defp route_with_load_balancing(signal, state) do
    # Get all nodes that can handle this signal type
    capable_nodes = find_capable_nodes(signal, state)
    
    # Select node based on load
    selected_node = select_least_loaded_node(capable_nodes)
    
    if selected_node == Node.self() do
      # Route locally
      case Jido.Signal.Router.route(state.local_router, signal) do
        {:ok, targets} -> {:reply, {:ok, targets}, state}
        error -> {:reply, error, state}
      end
    else
      # Route to remote node
      case :rpc.call(selected_node, Jido.Signal.Router, :route, [signal]) do
        {:ok, targets} -> 
          remote_targets = Enum.map(targets, fn t -> {selected_node, t} end)
          {:reply, {:ok, remote_targets}, state}
        error -> 
          {:reply, error, state}
      end
    end
  end
  
  # Distributed subscription management
  def add_distributed_route(distributed_router, route_spec, nodes \\ :all) do
    GenServer.call(distributed_router, {:add_distributed_route, route_spec, nodes})
  end
  
  def handle_call({:add_distributed_route, route_spec, nodes}, _from, state) do
    target_nodes = case nodes do
      :all -> get_cluster_nodes()
      :local -> [Node.self()]
      node_list when is_list(node_list) -> node_list
    end
    
    # Add route to specified nodes
    results = Enum.map(target_nodes, fn node ->
      if node == Node.self() do
        # Add to local router
        case Jido.Signal.Router.add(state.local_router, route_spec) do
          {:ok, updated_router} ->
            new_state = %{state | local_router: updated_router}
            {node, :ok, new_state}
          error ->
            {node, error, state}
        end
      else
        # Add to remote router
        result = :rpc.call(node, Jido.Signal.Router, :add, [route_spec])
        {node, result, state}
      end
    end)
    
    # Update state with successful local additions
    final_state = Enum.reduce(results, state, fn
      {node, :ok, new_state}, _acc when node == Node.self() -> new_state
      {_node, _result, _new_state}, acc -> acc
    end)
    
    {:reply, {:ok, results}, final_state}
  end
  
  # Private helpers
  defp generate_routing_hash(signal) do
    # Create hash key for consistent routing
    key_parts = [
      signal.type,
      signal.subject || "",
      signal.source
    ]
    
    :crypto.hash(:sha256, Enum.join(key_parts, ":"))
    |> Base.encode16()
  end
  
  defp find_capable_nodes(signal, state) do
    # Find nodes that have routes matching this signal
    cluster_nodes = get_cluster_nodes()
    
    Enum.filter(cluster_nodes, fn node ->
      if node == Node.self() do
        case Jido.Signal.Router.route(state.local_router, signal) do
          {:ok, targets} when length(targets) > 0 -> true
          _ -> false
        end
      else
        case :rpc.call(node, __MODULE__, :can_route?, [signal]) do
          {:ok, true} -> true
          _ -> false
        end
      end
    end)
  end
  
  defp select_least_loaded_node(nodes) do
    # Simple load balancing - could be enhanced with actual metrics
    Enum.random(nodes)
  end

  defp get_cluster_nodes do
    [Node.self() | Node.list()]
  end
  
  defp join_routing_cluster(cluster_id, node_id) do
    # Register this node in the distributed routing cluster
    # Implementation would depend on cluster management system
    :ok
  end
  
  # Public API for remote calls
  def can_route?(signal) do
    # Check if local router can handle this signal
    case Jido.Signal.Router.route(signal) do
      {:ok, targets} when length(targets) > 0 -> {:ok, true}
      _ -> {:ok, false}
    end
  end
  
  def get_local_routes(signal) do
    # Get local routing targets for remote calls
    Jido.Signal.Router.route(signal)
  end
end
```

### 4. **Cross-Cluster Communication Layer**

```elixir
defmodule Jido.Signal.ClusterBridge do
  @moduledoc """
  Handles communication between different clusters/regions.
  
  Provides:
  - Cross-region signal replication
  - Conflict resolution
  - Network partition handling
  - Circuit breaker patterns
  """
  
  use GenServer
  
  defstruct [
    :cluster_id,
    :region,
    :peer_clusters,
    :replication_policies,
    :conflict_resolver,
    :circuit_breakers
  ]
  
  def start_link(opts) do
    cluster_id = Keyword.fetch!(opts, :cluster_id)
    region = Keyword.fetch!(opts, :region)
    
    GenServer.start_link(__MODULE__, {cluster_id, region, opts})
  end
  
  def init({cluster_id, region, opts}) do
    peer_clusters = Keyword.get(opts, :peer_clusters, [])
    
    state = %__MODULE__{
      cluster_id: cluster_id,
      region: region,
      peer_clusters: peer_clusters,
      replication_policies: %{},
      conflict_resolver: Keyword.get(opts, :conflict_resolver, :timestamp_wins),
      circuit_breakers: init_circuit_breakers(peer_clusters)
    }
    
    # Start health monitoring of peer clusters
    :timer.send_interval(30_000, self(), :health_check)
    
    {:ok, state}
  end
  
  # Cross-cluster signal replication
  def replicate_to_clusters(bridge, signal, clusters \\ :all, opts \\ []) do
    consistency = Keyword.get(opts, :consistency, :eventual)
    timeout = Keyword.get(opts, :timeout, 5000)
    
    GenServer.call(bridge, {:replicate_signal, signal, clusters, consistency, timeout})
  end
  
  def handle_call({:replicate_signal, signal, clusters, consistency, timeout}, _from, state) do
    target_clusters = case clusters do
      :all -> Map.keys(state.peer_clusters)
      cluster_list -> cluster_list
    end
    
    case consistency do
      :strong ->
        replicate_with_strong_consistency(signal, target_clusters, timeout, state)
      :eventual ->
        replicate_with_eventual_consistency(signal, target_clusters, state)
      :weak ->
        replicate_with_weak_consistency(signal, target_clusters, state)
    end
  end
  
  # Strong consistency replication
  defp replicate_with_strong_consistency(signal, target_clusters, timeout, state) do
    # Send to all clusters and wait for acknowledgment
    tasks = Enum.map(target_clusters, fn cluster_id ->
      cluster_config = state.peer_clusters[cluster_id]
      
      Task.async(fn ->
        case get_circuit_breaker_status(cluster_id, state) do
          :open ->
            {:error, :circuit_breaker_open}
          
          _status ->
            send_to_cluster(signal, cluster_config, timeout)
        end
      end)
    end)
    
    # Wait for all to complete
    results = Task.yield_many(tasks, timeout)
    
    successes = Enum.count(results, fn {_task, result} ->
      match?({:ok, {:ok, _}}, result)
    end)
    
    if successes == length(target_clusters) do
      {:reply, {:ok, :replicated_to_all}, state}
    else
      {:reply, {:error, :partial_replication}, state}
    end
  end
  
  # Eventual consistency replication
  defp replicate_with_eventual_consistency(signal, target_clusters, state) do
    # Send async to all clusters
    Enum.each(target_clusters, fn cluster_id ->
      cluster_config = state.peer_clusters[cluster_id]
      
      case get_circuit_breaker_status(cluster_id, state) do
        :open ->
          # Store for later retry
          buffer_for_retry(signal, cluster_id, state)
        
        _status ->
          Task.start(fn ->
            case send_to_cluster(signal, cluster_config, 10_000) do
              {:ok, _} ->
                record_successful_replication(cluster_id, state)
              {:error, reason} ->
                handle_replication_failure(signal, cluster_id, reason, state)
            end
          end)
      end
    end)
    
    {:reply, {:ok, :replication_initiated}, state}
  end
  
  # Weak consistency replication
  defp replicate_with_weak_consistency(signal, target_clusters, state) do
    # Fire and forget
    Enum.each(target_clusters, fn cluster_id ->
      cluster_config = state.peer_clusters[cluster_id]
      
      spawn(fn ->
        send_to_cluster(signal, cluster_config, 5000)
      end)
    end)
    
    {:reply, {:ok, :replication_fired}, state}
  end
  
  # Handle incoming cross-cluster signals
  def handle_cast({:receive_cross_cluster_signal, signal, source_cluster}, state) do
    # Check for conflicts with local signals
    case detect_conflict(signal, state) do
      {:conflict, local_signal} ->
        resolved_signal = resolve_conflict(signal, local_signal, state)
        apply_resolved_signal(resolved_signal, state)
      
      :no_conflict ->
        apply_cross_cluster_signal(signal, source_cluster, state)
    end
    
    {:noreply, state}
  end
  
  # Health monitoring
  def handle_info(:health_check, state) do
    # Check health of all peer clusters
    Enum.each(state.peer_clusters, fn {cluster_id, config} ->
      Task.start(fn ->
        health_status = check_cluster_health(config)
        GenServer.cast(self(), {:health_update, cluster_id, health_status})
      end)
    end)
    
    {:noreply, state}
  end
  
  def handle_cast({:health_update, cluster_id, health_status}, state) do
    # Update circuit breaker based on health
    new_circuit_breakers = update_circuit_breaker(
      state.circuit_breakers, cluster_id, health_status
    )
    
    new_state = %{state | circuit_breakers: new_circuit_breakers}
    {:noreply, new_state}
  end
  
  # Private helpers
  defp send_to_cluster(signal, cluster_config, timeout) do
    # Send signal to remote cluster via HTTP/gRPC/etc
    case cluster_config.protocol do
      :http ->
        send_via_http(signal, cluster_config, timeout)
      :grpc ->
        send_via_grpc(signal, cluster_config, timeout)
      :amqp ->
        send_via_amqp(signal, cluster_config, timeout)
    end
  end
  
  defp send_via_http(signal, config, timeout) do
    url = "#{config.endpoint}/api/v1/signals/replicate"
    headers = [
      {"Content-Type", "application/json"},
      {"Authorization", "Bearer #{config.auth_token}"},
      {"X-Source-Cluster", config.source_cluster_id}
    ]
    
    body = Jason.encode!(%{
      signal: signal,
      replication_metadata: %{
        source_cluster: config.source_cluster_id,
        replicated_at: DateTime.utc_now()
      }
    })
    
    case HTTPoison.post(url, body, headers, [recv_timeout: timeout]) do
      {:ok, %{status_code: status}} when status in 200..299 ->
        {:ok, :delivered}
      {:ok, %{status_code: status}} ->
        {:error, {:http_error, status}}
      {:error, reason} ->
        {:error, reason}
    end
  end
  
  defp detect_conflict(incoming_signal, state) do
    # Check if there's a local signal with same ID but different content
    case get_local_signal(incoming_signal.id) do
      {:ok, local_signal} ->
        if signals_conflict?(incoming_signal, local_signal) do
          {:conflict, local_signal}
        else
          :no_conflict
        end
      
      {:error, :not_found} ->
        :no_conflict
    end
  end
  
  defp resolve_conflict(remote_signal, local_signal, state) do
    case state.conflict_resolver do
      :timestamp_wins ->
        if remote_signal.time > local_signal.time do
          remote_signal
        else
          local_signal
        end
      
      :vector_clock_wins ->
        remote_vc = remote_signal.data[:__vector_clock__]
        local_vc = local_signal.data[:__vector_clock__]
        
        case VectorClock.compare(remote_vc, local_vc) do
          :greater -> remote_signal
          :less -> local_signal
          :concurrent -> merge_concurrent_signals(remote_signal, local_signal)
        end
      
      :custom_resolver when is_function(state.conflict_resolver) ->
        state.conflict_resolver.(remote_signal, local_signal)
    end
  end
  
  defp init_circuit_breakers(peer_clusters) do
    Map.new(peer_clusters, fn {cluster_id, _config} ->
      {cluster_id, %{
        status: :closed,
        failure_count: 0,
        last_failure: nil,
        threshold: 5,
        timeout: 60_000
      }}
    end)
  end
  
  defp get_circuit_breaker_status(cluster_id, state) do
    breaker = state.circuit_breakers[cluster_id]
    
    case breaker.status do
      :open ->
        # Check if timeout has passed
        if DateTime.diff(DateTime.utc_now(), breaker.last_failure, :millisecond) > breaker.timeout do
          :half_open
        else
          :open
        end
      
      status ->
        status
    end
  end
end
```

## 5. **Complete Integration Example**

```elixir
defmodule GlobalECommerceCluster do
  @moduledoc """
  Complete example of distributed e-commerce platform using Jido Signal.
  """
  
  def start_cluster(region, opts \\ []) do
    cluster_id = "ecommerce-#{region}"
    
    # 1. Start distributed bus
    {:ok, distributed_bus} = Jido.Signal.DistributedBus.start_link([
      cluster_id: cluster_id,
      replication_factor: 3,
      consistency_level: :eventual
    ])
    
    # 2. Start distributed journal
    {:ok, distributed_journal} = Jido.Signal.DistributedJournal.start_link([
      cluster_id: cluster_id,
      consistency: :causal
    ])
    
    # 3. Start distributed router
    {:ok, distributed_router} = Jido.Signal.DistributedRouter.start_link([
      cluster_id: cluster_id,
      routes: global_routes()
    ])
    
    # 4. Start cluster bridge for cross-region communication
    {:ok, cluster_bridge} = Jido.Signal.ClusterBridge.start_link([
      cluster_id: cluster_id,
      region: region,
      peer_clusters: peer_cluster_config(region)
    ])
    
    # 5. Setup global event flows
    setup_global_event_flows(distributed_bus, distributed_router, cluster_bridge)
    
    {:ok, %{
      cluster_id: cluster_id,
      distributed_bus: distributed_bus,
      distributed_journal: distributed_journal,
      distributed_router: distributed_router,
      cluster_bridge: cluster_bridge
    }}
  end
  
  defp global_routes do
    [
      # Critical events - strong consistency across regions
      {"order.placed", [
        {:named, target: {:name, :order_processor}},
        {:cross_cluster, consistency: :strong, regions: [:us_east, :eu_west, :apac]}
      ], 100},
      
      # Inventory updates - eventual consistency is ok
      {"inventory.updated", [
        {:named, target: {:name, :inventory_manager}},
        {:cross_cluster, consistency: :eventual, regions: :all}
      ], 90},
      
      # User events - regional with selective replication
      {"user.registered", [
        {:named, target: {:name, :user_service}},
        {:cross_cluster, 
         consistency: :eventual, 
         regions: :all,
         filter: fn signal -> signal.data.premium_user end}
      ], 80},
      
      # Analytics events - local processing with global aggregation
      {"analytics.**", [
        {:named, target: {:name, :local_analytics}},
        {:cross_cluster, 
         consistency: :weak, 
         regions: [:analytics_hub],
         aggregation: :daily}
      ], 70},
      
      # Error events - immediate global notification
      {"error.critical", [
        {:named, target: {:name, :error_handler}},
        {:cross_cluster, consistency: :strong, regions: :all, priority: :critical}
      ], 95}
    ]
  end
  
  defp setup_global_event_flows(distributed_bus, distributed_router, cluster_bridge) do
    # Cross-region order processing
    setup_order_processing_flow(distributed_bus, cluster_bridge)
    
    # Global inventory synchronization
    setup_inventory_sync_flow(distributed_bus, cluster_bridge)
    
    # Customer journey tracking across regions
    setup_customer_journey_tracking(distributed_bus, distributed_router)
    
    # Global fraud detection
    setup_fraud_detection_flow(distributed_bus, cluster_bridge)
  end
  
  defp setup_order_processing_flow(distributed_bus, cluster_bridge) do
    # When order is placed in any region
    Jido.Signal.DistributedBus.subscribe(distributed_bus, "order.placed",
      dispatch: {:function, {__MODULE__, :handle_global_order_placed, [cluster_bridge]}},
      persistent?: true,
      replicate: true
    )
    
    # Payment processing coordination
    Jido.Signal.DistributedBus.subscribe(distributed_bus, "payment.authorized",
      dispatch: {:function, {__MODULE__, :handle_payment_authorized, [cluster_bridge]}},
      persistent?: true
    )
    
    # Fulfillment coordination
    Jido.Signal.DistributedBus.subscribe(distributed_bus, "fulfillment.requested",
      dispatch: {:function, {__MODULE__, :handle_fulfillment_requested, [cluster_bridge]}},
      persistent?: true
    )
  end
  
  def handle_global_order_placed(signal, cluster_bridge) do
    order_data = signal.data
    
    # Determine optimal fulfillment region
    fulfillment_region = determine_fulfillment_region(order_data)
    
    # Replicate order to fulfillment region if different
    if fulfillment_region != get_current_region() do
      Jido.Signal.ClusterBridge.replicate_to_clusters(
        cluster_bridge, 
        %{signal | 
          type: "order.fulfillment_requested",
          data: Map.put(order_data, :fulfillment_region, fulfillment_region)
        },
        [fulfillment_region],
        consistency: :strong
      )
    end
    
    # Trigger inventory check globally
    inventory_check_signal = Jido.Signal.new!(%{
      type: "inventory.check_requested",
      source: "/order-processor/#{get_current_region()}",
      subject: order_data.order_id,
      data: %{
        order_id: order_data.order_id,
        items: order_data.items,
        fulfillment_region: fulfillment_region
      }
    })
    
    Jido.Signal.ClusterBridge.replicate_to_clusters(
      cluster_bridge,
      inventory_check_signal,
      :all,
      consistency: :eventual
    )
  end
  
  defp setup_inventory_sync_flow(distributed_bus, cluster_bridge) do
    # Real-time inventory updates
    Jido.Signal.DistributedBus.subscribe(distributed_bus, "inventory.updated",
      dispatch: {:function, {__MODULE__, :handle_inventory_update, [cluster_bridge]}},
      persistent?: true
    )
    
    # Inventory level warnings
    Jido.Signal.DistributedBus.subscribe(distributed_bus, "inventory.low_stock",
      dispatch: {:function, {__MODULE__, :handle_low_stock_alert, [cluster_bridge]}},
      persistent?: true
    )
  end
  
  def handle_inventory_update(signal, cluster_bridge) do
    # Replicate inventory changes to all regions
    Jido.Signal.ClusterBridge.replicate_to_clusters(
      cluster_bridge,
      signal,
      :all,
      consistency: :eventual
    )
    
    # Check if this creates low stock condition
    if signal.data.quantity < signal.data.reorder_threshold do
      low_stock_signal = Jido.Signal.new!(%{
        type: "inventory.low_stock",
        source: "/inventory-manager/#{get_current_region()}",
        subject: signal.data.sku,
        data: %{
          sku: signal.data.sku,
          current_quantity: signal.data.quantity,
          reorder_threshold: signal.data.reorder_threshold,
          suggested_reorder: signal.data.suggested_reorder_quantity
        }
      })
      
      # Send to procurement region
      Jido.Signal.ClusterBridge.replicate_to_clusters(
        cluster_bridge,
        low_stock_signal,
        [:procurement_hub],
        consistency: :strong
      )
    end
  end
  
  defp setup_customer_journey_tracking(distributed_bus, distributed_router) do
    # Track customer interactions across all touchpoints
    customer_events = [
      "user.registered", "user.login", "user.logout",
      "product.viewed", "cart.item_added", "cart.item_removed",
      "order.placed", "payment.completed", "order.shipped",
      "support.ticket_created", "review.submitted"
    ]
    
    Enum.each(customer_events, fn event_type ->
      Jido.Signal.DistributedBus.subscribe(distributed_bus, event_type,
        dispatch: {:function, {__MODULE__, :track_customer_journey, [event_type]}},
        persistent?: true,
        replicate: false  # Keep journey tracking local for performance
      )
    end)
  end
  
  def track_customer_journey(signal, event_type) do
    customer_id = signal.data.customer_id || signal.data.user_id
    
    if customer_id do
      # Update customer journey in local analytics
      journey_signal = Jido.Signal.new!(%{
        type: "analytics.customer_journey_event",
        source: "/journey-tracker/#{get_current_region()}",
        subject: customer_id,
        data: %{
          customer_id: customer_id,
          event_type: event_type,
          region: get_current_region(),
          timestamp: DateTime.utc_now(),
          session_id: signal.data.session_id,
          event_data: signal.data
        }
      })
      
      # Send to local analytics bus
      Jido.Signal.Bus.publish(get_local_analytics_bus(), [journey_signal])
    end
  end
  
  defp setup_fraud_detection_flow(distributed_bus, cluster_bridge) do
    # Monitor suspicious activities across all regions
    fraud_signals = [
      "payment.failed", "login.suspicious", "order.high_value",
      "user.velocity_high", "payment.method_unusual"
    ]
    
    Enum.each(fraud_signals, fn signal_type ->
      Jido.Signal.DistributedBus.subscribe(distributed_bus, signal_type,
        dispatch: {:function, {__MODULE__, :analyze_fraud_risk, [cluster_bridge]}},
        persistent?: true
      )
    end)
  end
  
  def analyze_fraud_risk(signal, cluster_bridge) do
    # Calculate fraud risk score
    risk_score = calculate_fraud_risk(signal)
    
    if risk_score > 0.8 do
      # High risk - immediate global alert
      fraud_alert = Jido.Signal.new!(%{
        type: "fraud.high_risk_detected",
        source: "/fraud-detector/#{get_current_region()}",
        data: %{
          risk_score: risk_score,
          original_signal: signal.id,
          customer_id: signal.data.customer_id,
          detected_region: get_current_region(),
          risk_factors: extract_risk_factors(signal)
        }
      })
      
      # Replicate to all regions immediately
      Jido.Signal.ClusterBridge.replicate_to_clusters(
        cluster_bridge,
        fraud_alert,
        :all,
        consistency: :strong
      )
    end
  end
  
  # Helper functions
  defp peer_cluster_config(region) do
    case region do
      :us_east -> %{
        eu_west: %{
          endpoint: "https://eu-cluster.ecommerce.com",
          protocol: :http,
          auth_token: System.get_env("EU_CLUSTER_TOKEN")
        },
        apac: %{
          endpoint: "https://apac-cluster.ecommerce.com", 
          protocol: :http,
          auth_token: System.get_env("APAC_CLUSTER_TOKEN")
        }
      }
      
      :eu_west -> %{
        us_east: %{
          endpoint: "https://us-cluster.ecommerce.com",
          protocol: :http,
          auth_token: System.get_env("US_CLUSTER_TOKEN")
        },
        apac: %{
          endpoint: "https://apac-cluster.ecommerce.com",
          protocol: :http, 
          auth_token: System.get_env("APAC_CLUSTER_TOKEN")
        }
      }
      
      :apac -> %{
        us_east: %{
          endpoint: "https://us-cluster.ecommerce.com",
          protocol: :http,
          auth_token: System.get_env("US_CLUSTER_TOKEN")
        },
        eu_west: %{
          endpoint: "https://eu-cluster.ecommerce.com",
          protocol: :http,
          auth_token: System.get_env("EU_CLUSTER_TOKEN")
        }
      }
    end
  end
  
  defp determine_fulfillment_region(order_data) do
    # Logic to determine optimal fulfillment region
    # Based on shipping address, inventory levels, etc.
    shipping_country = order_data.shipping_address.country
    
    case shipping_country do
      country when country in ["US", "CA", "MX"] -> :us_east
      country when country in ["GB", "DE", "FR", "IT", "ES"] -> :eu_west  
      country when country in ["JP", "AU", "SG", "IN"] -> :apac
      _ -> :us_east  # Default fallback
    end
  end
  
  defp get_current_region do
    # Determine current region from environment or config
    case System.get_env("CLUSTER_REGION") do
      "us-east" -> :us_east
      "eu-west" -> :eu_west
      "apac" -> :apac
      _ -> :us_east
    end
  end
  
  defp calculate_fraud_risk(signal) do
    # Simplified fraud risk calculation
    # Real implementation would use ML models, historical data, etc.
    base_risk = 0.1
    
    risk_factors = [
      high_value_transaction?(signal),
      unusual_location?(signal),
      velocity_anomaly?(signal),
      payment_method_risk?(signal)
    ]
    
    risk_multiplier = Enum.count(risk_factors, & &1) * 0.2
    min(base_risk + risk_multiplier, 1.0)
  end
  
  defp extract_risk_factors(signal) do
    # Extract factors that contributed to high risk score
    %{
      high_value: high_value_transaction?(signal),
      unusual_location: unusual_location?(signal),
      velocity_anomaly: velocity_anomaly?(signal),
      payment_risk: payment_method_risk?(signal)
    }
  end
  
  # Placeholder risk factor functions
  defp high_value_transaction?(signal), do: signal.data[:amount] && signal.data.amount > 1000
  defp unusual_location?(signal), do: signal.data[:location] && signal.data.location != signal.data[:usual_location]
  defp velocity_anomaly?(signal), do: signal.data[:transaction_count] && signal.data.transaction_count > 10
  defp payment_method_risk?(signal), do: signal.data[:payment_method] == "new_card"
  
  defp get_local_analytics_bus do
    # Return reference to local analytics bus
    :analytics_bus
  end
end
```

## Assessment: Framework Suitability for Distributed Clusters

### ✅ **SUITABLE - With Modifications**

The Jido Signal framework has excellent foundational elements for distributed systems but requires **significant extensions** rather than a complete rewrite.

### **Required Modification Level: MODERATE TO SIGNIFICANT**

#### **What Works Well (Use As-Is)**
1. **Signal Structure** - CloudEvents compliance makes cross-cluster communication natural
2. **Routing Engine** - Trie-based routing scales well across nodes
3. **Dispatch System** - Adapter pattern easily extends to cluster communication
4. **Middleware Pipeline** - Perfect for adding distributed concerns
5. **Serialization** - Already supports multiple formats needed for network transport
6. **Journal Causality** - Foundation for distributed causality tracking

#### **What Needs Extension (Wrap/Integrate)**
1. **Bus Architecture** - Wrap with distributed coordination layer
2. **State Management** - Integrate with distributed state stores
3. **Subscription Management** - Add cluster-wide subscription registry
4. **Snapshot System** - Extend to support distributed snapshots

#### **What Needs Replacement (Modify)**
1. **Single GenServer Bus** → **Distributed Bus Cluster**
2. **Local Memory Storage** → **Distributed Storage with Replication**
3. **Node-Local Subscriptions** → **Cluster-Wide Subscription Sync**
4. **Simple Signal Ordering** → **Vector Clock/Lamport Timestamp Ordering**

### **Integration Strategy: LAYERED APPROACH**

```
┌─────────────────────────────────────────────────────────────┐
│                 Distributed Layer                           │
│  ┌─────────────────────────────────────────────────────┐   │
│  │            Jido Signal Core                         │   │
│  │  (Use as-is with minimal modifications)             │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

The framework is **well-suited** for distributed clusters with the right extensions. The core abstractions (signals, routing, dispatch) are solid foundations for building distributed event-driven systems.

**Recommendation: EXTEND rather than REPLACE** - The Jido Signal framework provides an excellent foundation that can be enhanced with distributed capabilities while preserving its clean abstractions and powerful routing engine.
