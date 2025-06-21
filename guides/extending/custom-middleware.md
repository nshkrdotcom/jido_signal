# Creating Custom Middleware

Middleware in Jido.Signal allows you to intercept and transform signals at various points in the bus lifecycle. This guide walks through implementing the `Jido.Signal.Bus.Middleware` behaviour with detailed examples and best practices.

## Understanding the Middleware Lifecycle

Middleware operates at four key interception points:

1. **Before Publish** - Transform or filter signals before they enter the bus
2. **After Publish** - React to successful publication events
3. **Before Dispatch** - Modify signals or control delivery to individual subscribers
4. **After Dispatch** - Handle delivery results and perform cleanup

Each callback receives contextual information and can influence the processing flow.

## Implementing the Middleware Behaviour

### Basic Structure

All middleware modules implement the `Jido.Signal.Bus.Middleware` behaviour:

```elixir
defmodule MyApp.CustomMiddleware do
  use Jido.Signal.Bus.Middleware
  
  @impl true
  def init(opts) do
    # Initialize middleware state
    {:ok, %{}}
  end
  
  # Override specific callbacks as needed
end
```

The `use Jido.Signal.Bus.Middleware` macro provides default implementations for all callbacks, so you only need to override the ones you need.

### State Management

Each middleware maintains its own state that persists across callback invocations:

```elixir
defmodule MyApp.StatefulMiddleware do
  use Jido.Signal.Bus.Middleware

  @impl true
  def init(opts) do
    initial_state = %{
      counter: 0,
      config: Map.new(opts)
    }
    {:ok, initial_state}
  end

  @impl true
  def before_publish(signals, _context, state) do
    new_state = %{state | counter: state.counter + length(signals)}
    {:cont, signals, new_state}
  end
end
```

## Lifecycle Callbacks in Detail

### `init/1` - Middleware Initialization

Called once when the middleware is added to the bus. Must return `{:ok, state}` or `{:error, reason}`.

```elixir
@impl true
def init(opts) do
  config = %{
    enabled: Keyword.get(opts, :enabled, true),
    log_level: Keyword.get(opts, :log_level, :info),
    threshold: Keyword.get(opts, :threshold, 100)
  }
  
  # Validate configuration
  if config.threshold < 0 do
    {:error, :invalid_threshold}
  else
    {:ok, config}
  end
end
```

### `before_publish/3` - Pre-Publication Processing

Transform signals or prevent publication entirely:

```elixir
@impl true
def before_publish(signals, context, state) do
  case validate_signals(signals) do
    :ok ->
      enriched_signals = Enum.map(signals, &enrich_signal/1)
      {:cont, enriched_signals, state}
      
    {:error, reason} ->
      {:halt, reason, state}
  end
end

defp enrich_signal(signal) do
  %{signal | 
    data: Map.put(signal.data || %{}, :enriched_at, DateTime.utc_now())
  }
end
```

### `after_publish/3` - Post-Publication Processing

React to successful publications (signals cannot be modified):

```elixir
@impl true
def after_publish(signals, context, state) do
  # Log successful publication
  Logger.info("Published #{length(signals)} signals to bus #{context.bus_name}")
  
  # Update metrics
  new_state = update_metrics(state, signals)
  {:cont, signals, new_state}
end
```

### `before_dispatch/4` - Pre-Dispatch Processing

Control signal delivery to individual subscribers:

```elixir
@impl true
def before_dispatch(signal, subscriber, context, state) do
  cond do
    should_skip?(signal, subscriber) ->
      {:skip, state}
      
    should_halt?(signal, subscriber) ->
      {:halt, :access_denied, state}
      
    true ->
      modified_signal = customize_for_subscriber(signal, subscriber)
      {:cont, modified_signal, state}
  end
end
```

### `after_dispatch/5` - Post-Dispatch Processing

Handle delivery results:

```elixir
@impl true
def after_dispatch(signal, subscriber, result, context, state) do
  case result do
    :ok ->
      log_success(signal, subscriber)
      
    {:error, reason} ->
      log_error(signal, subscriber, reason)
      handle_delivery_failure(signal, subscriber, reason)
  end
  
  {:cont, state}
end
```

## Complete Working Examples

### 1. Telemetry Integration Middleware

Emit `:telemetry` events for comprehensive observability:

```elixir
defmodule MyApp.TelemetryMiddleware do
  use Jido.Signal.Bus.Middleware
  
  @impl true
  def init(opts) do
    config = %{
      event_prefix: Keyword.get(opts, :event_prefix, [:my_app, :signal_bus]),
      include_metadata: Keyword.get(opts, :include_metadata, true)
    }
    {:ok, config}
  end

  @impl true
  def before_publish(signals, context, state) do
    :telemetry.execute(
      state.event_prefix ++ [:publish, :start],
      %{count: length(signals)},
      %{bus_name: context.bus_name, signal_types: extract_types(signals)}
    )
    
    {:cont, signals, state}
  end

  @impl true
  def after_publish(signals, context, state) do
    :telemetry.execute(
      state.event_prefix ++ [:publish, :stop],
      %{count: length(signals)},
      %{bus_name: context.bus_name}
    )
    
    {:cont, signals, state}
  end

  @impl true
  def before_dispatch(signal, subscriber, context, state) do
    start_time = System.monotonic_time()
    
    :telemetry.execute(
      state.event_prefix ++ [:dispatch, :start],
      %{},
      %{
        signal_id: signal.id,
        signal_type: signal.type,
        subscriber_path: subscriber.path,
        bus_name: context.bus_name
      }
    )
    
    # Store start time in signal metadata for duration calculation
    enhanced_signal = put_in(signal.metadata[:telemetry_start], start_time)
    {:cont, enhanced_signal, state}
  end

  @impl true
  def after_dispatch(signal, subscriber, result, context, state) do
    start_time = signal.metadata[:telemetry_start]
    duration = System.monotonic_time() - start_time
    
    measurements = %{duration: duration}
    metadata = %{
      signal_id: signal.id,
      signal_type: signal.type,
      subscriber_path: subscriber.path,
      bus_name: context.bus_name,
      result: result
    }
    
    event_name = case result do
      :ok -> [:dispatch, :success]
      {:error, _} -> [:dispatch, :error]
    end
    
    :telemetry.execute(state.event_prefix ++ event_name, measurements, metadata)
    
    {:cont, state}
  end

  defp extract_types(signals) do
    signals |> Enum.map(& &1.type) |> Enum.uniq()
  end
end
```

### 2. Authentication Middleware

Enforce access control based on signal content and subscriber identity:

```elixir
defmodule MyApp.AuthMiddleware do
  use Jido.Signal.Bus.Middleware
  
  @impl true
  def init(opts) do
    config = %{
      auth_service: Keyword.fetch!(opts, :auth_service),
      protected_paths: Keyword.get(opts, :protected_paths, []),
      default_policy: Keyword.get(opts, :default_policy, :allow)
    }
    {:ok, config}
  end

  @impl true
  def before_publish(signals, context, state) do
    case authenticate_publisher(context, state) do
      {:ok, user} ->
        # Add authentication info to signals
        authenticated_signals = Enum.map(signals, fn signal ->
          %{signal | metadata: Map.put(signal.metadata, :publisher, user)}
        end)
        {:cont, authenticated_signals, state}
        
      {:error, reason} ->
        {:halt, {:authentication_failed, reason}, state}
    end
  end

  @impl true
  def before_dispatch(signal, subscriber, context, state) do
    if requires_authorization?(subscriber.path, state.protected_paths) do
      case authorize_access(signal, subscriber, state) do
        :ok ->
          {:cont, signal, state}
          
        {:error, :access_denied} ->
          {:skip, state}
          
        {:error, reason} ->
          {:halt, {:authorization_failed, reason}, state}
      end
    else
      {:cont, signal, state}
    end
  end

  defp authenticate_publisher(context, state) do
    # Extract authentication token from context metadata
    token = get_in(context.metadata, [:auth, :token])
    
    if token do
      state.auth_service.verify_token(token)
    else
      case state.default_policy do
        :allow -> {:ok, :anonymous}
        :deny -> {:error, :missing_token}
      end
    end
  end

  defp requires_authorization?(path, protected_paths) do
    Enum.any?(protected_paths, fn pattern ->
      match_path?(path, pattern)
    end)
  end

  defp authorize_access(signal, subscriber, state) do
    user = signal.metadata[:publisher]
    resource = %{
      signal_type: signal.type,
      subscriber_path: subscriber.path,
      data: signal.data
    }
    
    state.auth_service.authorize(user, :dispatch, resource)
  end

  defp match_path?(path, pattern) do
    # Simple wildcard matching - implement more sophisticated patterns as needed
    regex = pattern
    |> String.replace("*", "[^.]*")
    |> String.replace("**", ".*")
    |> then(&Regex.compile!/1)
    
    Regex.match?(regex, path)
  end
end
```

### 3. Content Filtering and Transformation

Filter and transform signal content based on configurable rules:

```elixir
defmodule MyApp.ContentFilterMiddleware do
  use Jido.Signal.Bus.Middleware

  @impl true
  def init(opts) do
    config = %{
      filters: compile_filters(Keyword.get(opts, :filters, [])),
      transformations: compile_transformations(Keyword.get(opts, :transformations, [])),
      strict_mode: Keyword.get(opts, :strict_mode, false)
    }
    {:ok, config}
  end

  @impl true
  def before_publish(signals, _context, state) do
    case filter_and_transform_signals(signals, state) do
      {:ok, processed_signals} ->
        {:cont, processed_signals, state}
        
      {:error, reason} when state.strict_mode ->
        {:halt, reason, state}
        
      {:error, _reason} ->
        # Non-strict mode: filter out invalid signals
        valid_signals = Enum.filter(signals, &valid_signal?(&1, state))
        {:cont, valid_signals, state}
    end
  end

  @impl true
  def before_dispatch(signal, subscriber, context, state) do
    # Apply subscriber-specific transformations
    case transform_for_subscriber(signal, subscriber, state) do
      {:ok, transformed_signal} ->
        {:cont, transformed_signal, state}
        
      {:error, :filtered} ->
        {:skip, state}
        
      {:error, reason} ->
        {:halt, reason, state}
    end
  end

  defp filter_and_transform_signals(signals, state) do
    try do
      processed = Enum.map(signals, fn signal ->
        signal
        |> apply_filters(state.filters)
        |> apply_transformations(state.transformations)
      end)
      
      {:ok, processed}
    rescue
      error -> {:error, {:processing_failed, error}}
    end
  end

  defp apply_filters(signal, filters) do
    Enum.reduce(filters, signal, fn filter, acc_signal ->
      filter.(acc_signal)
    end)
  end

  defp apply_transformations(signal, transformations) do
    Enum.reduce(transformations, signal, fn transform, acc_signal ->
      transform.(acc_signal)
    end)
  end

  defp transform_for_subscriber(signal, subscriber, state) do
    # Example: filter sensitive data based on subscriber permissions
    subscriber_level = get_subscriber_clearance(subscriber)
    
    filtered_data = filter_sensitive_fields(signal.data, subscriber_level)
    transformed_signal = %{signal | data: filtered_data}
    
    {:ok, transformed_signal}
  end

  defp compile_filters(filter_specs) do
    Enum.map(filter_specs, &compile_filter/1)
  end

  defp compile_transformations(transform_specs) do
    Enum.map(transform_specs, &compile_transformation/1)
  end

  defp compile_filter({:remove_field, field}) do
    fn signal ->
      %{signal | data: Map.delete(signal.data || %{}, field)}
    end
  end

  defp compile_filter({:require_field, field}) do
    fn signal ->
      if Map.has_key?(signal.data || %{}, field) do
        signal
      else
        raise "Required field #{field} missing"
      end
    end
  end

  defp compile_transformation({:add_timestamp, field}) do
    fn signal ->
      data = Map.put(signal.data || %{}, field, DateTime.utc_now())
      %{signal | data: data}
    end
  end

  defp compile_transformation({:hash_field, field}) do
    fn signal ->
      case Map.get(signal.data || %{}, field) do
        nil -> signal
        value ->
          hashed = :crypto.hash(:sha256, to_string(value)) |> Base.encode16()
          data = Map.put(signal.data, field, hashed)
          %{signal | data: data}
      end
    end
  end

  defp get_subscriber_clearance(subscriber) do
    # Extract clearance level from subscriber metadata or path
    case String.split(subscriber.path, ".") do
      ["admin" | _] -> :admin
      ["internal" | _] -> :internal
      _ -> :public
    end
  end

  defp filter_sensitive_fields(data, :admin), do: data
  defp filter_sensitive_fields(data, :internal) do
    Map.drop(data, [:ssn, :credit_card])
  end
  defp filter_sensitive_fields(data, :public) do
    Map.drop(data, [:ssn, :credit_card, :internal_id, :email])
  end

  defp valid_signal?(signal, state) do
    try do
      apply_filters(signal, state.filters)
      true
    rescue
      _ -> false
    end
  end
end
```

### 4. Rate Limiting Middleware

Implement sophisticated rate limiting with multiple strategies:

```elixir
defmodule MyApp.RateLimitMiddleware do
  use Jido.Signal.Bus.Middleware

  @impl true
  def init(opts) do
    config = %{
      limits: parse_limits(Keyword.get(opts, :limits, [])),
      storage: Keyword.get(opts, :storage, :ets),
      cleanup_interval: Keyword.get(opts, :cleanup_interval, 60_000)
    }
    
    # Initialize storage
    storage_pid = init_storage(config.storage)
    schedule_cleanup(config.cleanup_interval)
    
    {:ok, Map.put(config, :storage_pid, storage_pid)}
  end

  @impl true
  def before_publish(signals, context, state) do
    publisher_key = extract_publisher_key(context)
    
    case check_rate_limit(publisher_key, length(signals), :publish, state) do
      :ok ->
        record_usage(publisher_key, length(signals), :publish, state)
        {:cont, signals, state}
        
      {:error, :rate_limited} ->
        {:halt, {:rate_limited, publisher_key}, state}
    end
  end

  @impl true
  def before_dispatch(signal, subscriber, context, state) do
    subscriber_key = extract_subscriber_key(subscriber)
    
    case check_rate_limit(subscriber_key, 1, :dispatch, state) do
      :ok ->
        record_usage(subscriber_key, 1, :dispatch, state)
        {:cont, signal, state}
        
      {:error, :rate_limited} ->
        {:skip, state}
    end
  end

  defp parse_limits(limit_specs) do
    Enum.map(limit_specs, fn
      {key, max_count, window_ms} ->
        %{
          key: key,
          max_count: max_count,
          window_ms: window_ms,
          strategy: :sliding_window
        }
        
      {key, max_count, window_ms, strategy} ->
        %{
          key: key,
          max_count: max_count,
          window_ms: window_ms,
          strategy: strategy
        }
    end)
  end

  defp init_storage(:ets) do
    table = :ets.new(:rate_limits, [:set, :public])
    {:ets, table}
  end

  defp init_storage({:redis, opts}) do
    {:ok, conn} = Redix.start_link(opts)
    {:redis, conn}
  end

  defp check_rate_limit(key, count, operation, state) do
    applicable_limits = get_applicable_limits(key, operation, state.limits)
    
    Enum.reduce_while(applicable_limits, :ok, fn limit, :ok ->
      case check_single_limit(key, count, limit, state) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp check_single_limit(key, count, limit, state) do
    limit_key = build_limit_key(key, limit)
    current_time = System.system_time(:millisecond)
    
    case limit.strategy do
      :sliding_window ->
        check_sliding_window(limit_key, count, current_time, limit, state)
        
      :fixed_window ->
        check_fixed_window(limit_key, count, current_time, limit, state)
        
      :token_bucket ->
        check_token_bucket(limit_key, count, current_time, limit, state)
    end
  end

  defp check_sliding_window(limit_key, count, current_time, limit, state) do
    window_start = current_time - limit.window_ms
    
    # Get recent usage within the sliding window
    recent_usage = get_usage_in_window(limit_key, window_start, current_time, state)
    
    if recent_usage + count <= limit.max_count do
      :ok
    else
      {:error, :rate_limited}
    end
  end

  defp check_fixed_window(limit_key, count, current_time, limit, state) do
    window_start = div(current_time, limit.window_ms) * limit.window_ms
    window_key = "#{limit_key}:#{window_start}"
    
    current_usage = get_window_usage(window_key, state)
    
    if current_usage + count <= limit.max_count do
      :ok
    else
      {:error, :rate_limited}
    end
  end

  defp check_token_bucket(limit_key, count, current_time, limit, state) do
    bucket = get_token_bucket(limit_key, limit, current_time, state)
    
    if bucket.tokens >= count do
      :ok
    else
      {:error, :rate_limited}
    end
  end

  defp record_usage(key, count, operation, state) do
    applicable_limits = get_applicable_limits(key, operation, state.limits)
    current_time = System.system_time(:millisecond)
    
    Enum.each(applicable_limits, fn limit ->
      limit_key = build_limit_key(key, limit)
      record_limit_usage(limit_key, count, current_time, limit, state)
    end)
  end

  defp get_applicable_limits(key, operation, limits) do
    Enum.filter(limits, fn limit ->
      match_key?(key, limit.key) and match_operation?(operation, limit)
    end)
  end

  defp match_key?(key, pattern) do
    # Support wildcard patterns for keys
    regex = pattern
    |> String.replace("*", "[^:]*")
    |> String.replace("**", ".*")
    |> then(&Regex.compile!/1)
    
    Regex.match?(regex, key)
  end

  defp match_operation?(operation, limit) do
    # Limits can specify operations they apply to
    operations = Map.get(limit, :operations, [:publish, :dispatch])
    operation in operations
  end

  defp extract_publisher_key(context) do
    # Extract publisher identity from context
    case get_in(context.metadata, [:auth, :user_id]) do
      nil -> "anonymous:#{context.bus_name}"
      user_id -> "user:#{user_id}"
    end
  end

  defp extract_subscriber_key(subscriber) do
    "subscriber:#{subscriber.path}"
  end

  defp build_limit_key(key, limit) do
    "#{key}:#{limit.strategy}:#{limit.max_count}:#{limit.window_ms}"
  end

  # Storage abstraction methods
  defp get_usage_in_window(limit_key, window_start, current_time, state) do
    case state.storage_pid do
      {:ets, table} ->
        get_ets_usage_in_window(table, limit_key, window_start, current_time)
        
      {:redis, conn} ->
        get_redis_usage_in_window(conn, limit_key, window_start, current_time)
    end
  end

  defp get_ets_usage_in_window(table, limit_key, window_start, current_time) do
    case :ets.lookup(table, limit_key) do
      [{^limit_key, timestamps}] ->
        # Count timestamps within the window
        Enum.count(timestamps, fn ts -> ts >= window_start and ts <= current_time end)
      [] ->
        0
    end
  end

  defp record_limit_usage(limit_key, count, current_time, limit, state) do
    case state.storage_pid do
      {:ets, table} ->
        record_ets_usage(table, limit_key, count, current_time, limit)
        
      {:redis, conn} ->
        record_redis_usage(conn, limit_key, count, current_time, limit)
    end
  end

  defp record_ets_usage(table, limit_key, count, current_time, limit) do
    timestamps = List.duplicate(current_time, count)
    
    case :ets.lookup(table, limit_key) do
      [{^limit_key, existing}] ->
        # Keep only recent timestamps and add new ones
        window_start = current_time - limit.window_ms
        recent = Enum.filter(existing, &(&1 >= window_start))
        updated = recent ++ timestamps
        :ets.insert(table, {limit_key, updated})
        
      [] ->
        :ets.insert(table, {limit_key, timestamps})
    end
  end

  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup_expired_limits, interval)
  end

  def handle_info(:cleanup_expired_limits, state) do
    cleanup_expired_entries(state)
    schedule_cleanup(state.cleanup_interval)
    {:noreply, state}
  end

  defp cleanup_expired_entries(state) do
    current_time = System.system_time(:millisecond)
    
    case state.storage_pid do
      {:ets, table} ->
        cleanup_ets_entries(table, current_time, state.limits)
        
      {:redis, conn} ->
        cleanup_redis_entries(conn, current_time)
    end
  end

  defp cleanup_ets_entries(table, current_time, limits) do
    max_window = Enum.max(Enum.map(limits, & &1.window_ms))
    cutoff = current_time - max_window
    
    :ets.foldl(fn {key, timestamps}, acc ->
      recent = Enum.filter(timestamps, &(&1 >= cutoff))
      if Enum.empty?(recent) do
        :ets.delete(table, key)
      else
        :ets.insert(table, {key, recent})
      end
      acc
    end, :ok, table)
  end
end
```

## Configuration and Registration

### Bus Configuration

Add middleware to a bus during startup:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    middleware = [
      {MyApp.TelemetryMiddleware, event_prefix: [:my_app, :signal_bus]},
      {MyApp.AuthMiddleware, 
       auth_service: MyApp.AuthService,
       protected_paths: ["admin.*", "internal.**"]},
      {MyApp.RateLimitMiddleware,
       limits: [
         {"user:*", 100, 60_000},           # 100 signals per minute per user
         {"subscriber:*", 1000, 60_000}     # 1000 dispatches per minute per subscriber
       ]}
    ]

    children = [
      {Jido.Signal.Bus, name: :my_bus, middleware: middleware}
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### Runtime Middleware Management

```elixir
# Add middleware to running bus (if supported)
Bus.add_middleware(:my_bus, {MyApp.NewMiddleware, config: :value})

# Remove middleware
Bus.remove_middleware(:my_bus, MyApp.OldMiddleware)

# Get current middleware configuration
middleware_list = Bus.get_middleware(:my_bus)
```

## Testing Middleware

### Unit Testing Individual Middleware

```elixir
defmodule MyApp.TelemetryMiddlewareTest do
  use ExUnit.Case, async: true
  
  alias MyApp.TelemetryMiddleware
  alias Jido.Signal

  test "initializes with correct configuration" do
    opts = [event_prefix: [:test, :events]]
    assert {:ok, state} = TelemetryMiddleware.init(opts)
    assert state.event_prefix == [:test, :events]
  end

  test "emits telemetry events on publish" do
    {:ok, state} = TelemetryMiddleware.init([])
    
    # Attach telemetry handler
    events = [:my_app, :signal_bus, :publish, :start]
    :telemetry.attach("test-handler", events, &capture_event/4, self())
    
    signals = [Signal.new!(%{type: "test.signal", source: "test"})]
    context = %{bus_name: :test_bus, timestamp: DateTime.utc_now(), metadata: %{}}
    
    {:cont, _, _} = TelemetryMiddleware.before_publish(signals, context, state)
    
    assert_receive {:telemetry_event, ^events, %{count: 1}, metadata}
    assert metadata.bus_name == :test_bus
    
    :telemetry.detach("test-handler")
  end

  defp capture_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end
end
```

### Integration Testing with Bus

```elixir
defmodule MyApp.MiddlewareIntegrationTest do
  use ExUnit.Case, async: true
  
  alias Jido.Signal
  alias Jido.Signal.Bus
  alias MyApp.TestMiddleware

  test "middleware processes signals in order" do
    bus_name = :"test_bus_#{:erlang.unique_integer([:positive])}"
    
    middleware = [
      {TestMiddleware, test_pid: self(), id: :first},
      {TestMiddleware, test_pid: self(), id: :second}
    ]
    
    start_supervised!({Bus, name: bus_name, middleware: middleware})
    
    {:ok, _} = Bus.subscribe(bus_name, "test.*", dispatch: {:pid, target: self()})
    
    signal = Signal.new!(%{type: "test.signal", source: "test"})
    {:ok, _} = Bus.publish(bus_name, [signal])
    
    # Verify middleware execution order
    assert_receive {:middleware_call, :first, :before_publish}
    assert_receive {:middleware_call, :second, :before_publish}
    assert_receive {:middleware_call, :first, :after_publish}
    assert_receive {:middleware_call, :second, :after_publish}
    
    # Verify signal delivery
    assert_receive {:signal, %Signal{type: "test.signal"}}
  end
end
```

### Property-Based Testing

```elixir
defmodule MyApp.MiddlewarePropertyTest do
  use ExUnit.Case
  use PropCheck
  
  alias MyApp.ContentFilterMiddleware
  alias Jido.Signal

  property "content filter never corrupts valid signals" do
    forall {signal_data, filters} <- {signal_data_generator(), filter_generator()} do
      {:ok, state} = ContentFilterMiddleware.init(filters: filters)
      signal = Signal.new!(%{type: "test.signal", source: "test", data: signal_data})
      
      case ContentFilterMiddleware.before_publish([signal], test_context(), state) do
        {:cont, [filtered_signal], _} ->
          # Signal should remain valid after filtering
          is_valid_signal(filtered_signal)
          
        {:halt, _, _} ->
          # Halting is acceptable for invalid signals
          true
      end
    end
  end

  defp signal_data_generator do
    map(%{
      id: pos_integer(),
      name: utf8(),
      sensitive: bool()
    })
  end

  defp filter_generator do
    list(oneof([
      {:remove_field, :sensitive},
      {:require_field, :id},
      {:add_timestamp, :processed_at}
    ]))
  end

  defp is_valid_signal(%Signal{} = signal) do
    is_binary(signal.id) and is_binary(signal.type) and is_map(signal.data)
  end

  defp test_context do
    %{bus_name: :test, timestamp: DateTime.utc_now(), metadata: %{}}
  end
end
```

## Performance Considerations

### Minimize State Mutations

```elixir
# ❌ Expensive: Creates new maps frequently
def before_publish(signals, context, state) do
  new_state = %{state | 
    counter: state.counter + 1,
    last_publish: DateTime.utc_now(),
    history: [context.timestamp | state.history]
  }
  {:cont, signals, new_state}
end

# ✅ Better: Batch state updates
def before_publish(signals, context, state) do
  updates = [
    counter: state.counter + 1,
    last_publish: DateTime.utc_now(),
    history: [context.timestamp | Enum.take(state.history, 99)]
  ]
  new_state = struct(state, updates)
  {:cont, signals, new_state}
end
```

### Efficient Signal Processing

```elixir
# ❌ Inefficient: Multiple passes over signals
def before_publish(signals, context, state) do
  validated = Enum.filter(signals, &valid_signal?/1)
  enriched = Enum.map(validated, &enrich_signal/1)
  sorted = Enum.sort_by(enriched, & &1.metadata.priority)
  {:cont, sorted, state}
end

# ✅ Efficient: Single pass with Stream
def before_publish(signals, context, state) do
  processed = signals
  |> Stream.filter(&valid_signal?/1)
  |> Stream.map(&enrich_signal/1)
  |> Enum.sort_by(& &1.metadata.priority)
  
  {:cont, processed, state}
end
```

### Memory Management

```elixir
defmodule MyApp.MemoryEfficientMiddleware do
  use Jido.Signal.Bus.Middleware

  @impl true
  def init(opts) do
    max_history = Keyword.get(opts, :max_history, 1000)
    {:ok, %{history: :queue.new(), max_history: max_history}}
  end

  @impl true
  def after_publish(signals, context, state) do
    # Use queue for efficient FIFO operations
    history = Enum.reduce(signals, state.history, fn signal, acc ->
      trimmed = if :queue.len(acc) >= state.max_history do
        {_, rest} = :queue.out(acc)
        rest
      else
        acc
      end
      :queue.in({signal.id, context.timestamp}, trimmed)
    end)
    
    {:cont, signals, %{state | history: history}}
  end
end
```

## Best Practices

### 1. Error Handling

```elixir
@impl true
def before_publish(signals, context, state) do
  try do
    processed_signals = process_signals_safely(signals, state)
    {:cont, processed_signals, state}
  rescue
    error ->
      Logger.error("Middleware processing failed: #{inspect(error)}")
      
      case state.error_policy do
        :fail_fast -> {:halt, {:middleware_error, error}, state}
        :skip_invalid -> {:cont, filter_valid_signals(signals), state}
        :continue -> {:cont, signals, state}
      end
  end
end
```

### 2. Configuration Validation

```elixir
@impl true
def init(opts) do
  with {:ok, config} <- validate_config(opts),
       {:ok, resources} <- initialize_resources(config) do
    {:ok, Map.merge(config, resources)}
  else
    {:error, reason} -> {:error, {:invalid_config, reason}}
  end
end

defp validate_config(opts) do
  required = [:service_url, :timeout]
  case Enum.find(required, &(not Keyword.has_key?(opts, &1))) do
    nil -> {:ok, Map.new(opts)}
    missing -> {:error, {:missing_required, missing}}
  end
end
```

### 3. Observability

```elixir
@impl true
def before_dispatch(signal, subscriber, context, state) do
  Logger.metadata([
    signal_id: signal.id,
    signal_type: signal.type,
    subscriber: subscriber.path,
    bus: context.bus_name
  ])
  
  start_time = System.monotonic_time()
  
  case do_processing(signal, subscriber, state) do
    {:ok, processed_signal} ->
      duration = System.monotonic_time() - start_time
      Logger.debug("Processed signal in #{duration}μs")
      {:cont, processed_signal, state}
      
    {:error, reason} ->
      Logger.warning("Processing failed: #{inspect(reason)}")
      {:skip, state}
  end
end
```

### 4. Resource Management

```elixir
defmodule MyApp.ResourceManagedMiddleware do
  use Jido.Signal.Bus.Middleware
  use GenServer

  @impl true
  def init(opts) do
    # Start a GenServer to manage resources
    {:ok, pid} = GenServer.start_link(__MODULE__, opts)
    {:ok, %{manager: pid}}
  end

  @impl GenServer
  def init(opts) do
    # Initialize external resources (databases, HTTP clients, etc.)
    {:ok, client} = HTTPClient.start_link(opts)
    Process.monitor(client)
    {:ok, %{client: client}}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, client, reason}, %{client: client} = state) do
    Logger.error("HTTP client died: #{inspect(reason)}")
    # Restart client
    {:ok, new_client} = HTTPClient.start_link([])
    {:noreply, %{state | client: new_client}}
  end

  # Delegate middleware calls to GenServer
  @impl true
  def before_dispatch(signal, subscriber, context, %{manager: pid} = state) do
    case GenServer.call(pid, {:process, signal, subscriber}) do
      {:ok, processed_signal} -> {:cont, processed_signal, state}
      {:error, reason} -> {:halt, reason, state}
    end
  end
end
```

Custom middleware provides powerful extension points for Jido.Signal buses. By following these patterns and best practices, you can build robust, performant middleware that enhances your signal processing pipeline while maintaining system reliability and observability.
