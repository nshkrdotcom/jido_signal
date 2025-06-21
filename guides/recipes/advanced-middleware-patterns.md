# Recipe: Advanced Middleware Patterns

Middleware in Jido.Signal provides powerful hooks for intercepting, transforming, and controlling signal flow. This guide explores sophisticated middleware patterns for production scenarios, complete with real-world examples and best practices.

## Understanding Middleware Flow

Middleware operates in a pipeline pattern, wrapping signal processing with pre- and post-processing logic:

```elixir
# Middleware execution order
[Middleware1, Middleware2, Middleware3]
  ↓ pre-processing (1→2→3)
  Signal Processing
  ↑ post-processing (3→2→1)
```

Each middleware can:
- Transform the signal before processing
- Control whether processing continues
- Add metadata and context
- Handle errors and implement fallbacks
- Measure performance and emit metrics

## Rate Limiting Middleware

Protect your system from overload with sophisticated rate limiting using sliding windows:

```elixir
defmodule MyApp.RateLimitMiddleware do
  @behaviour Jido.Signal.Middleware
  
  def init(opts) do
    %{
      window_size: Keyword.get(opts, :window_size, 60),  # 60 seconds
      max_requests: Keyword.get(opts, :max_requests, 1000),
      key_func: Keyword.get(opts, :key_func, &default_key_func/1),
      storage: Keyword.get(opts, :storage, :ets)
    }
  end

  def call(signal, next, config) do
    key = config.key_func.(signal)
    
    case check_rate_limit(key, config) do
      :ok ->
        result = next.(signal)
        record_request(key, config)
        result
        
      {:error, :rate_limited} ->
        {:error, %{
          type: :rate_limited,
          message: "Rate limit exceeded for #{key}",
          retry_after: calculate_retry_after(key, config)
        }}
    end
  end

  defp check_rate_limit(key, config) do
    now = System.system_time(:second)
    window_start = now - config.window_size
    
    # Get requests in the current window
    requests = get_requests_in_window(key, window_start, now, config.storage)
    
    if length(requests) < config.max_requests do
      :ok
    else
      {:error, :rate_limited}
    end
  end

  defp record_request(key, config) do
    now = System.system_time(:second)
    
    case config.storage do
      :ets ->
        table_name = :"rate_limit_#{key}"
        :ets.insert_new(table_name, {now, :request}) || :ets.insert(table_name, {now, :request})
        
      :redis ->
        # Redis sliding window implementation
        Redix.command(:redis, ["ZADD", "rate_limit:#{key}", now, now])
        Redix.command(:redis, ["EXPIRE", "rate_limit:#{key}", config.window_size * 2])
    end
  end

  defp get_requests_in_window(key, window_start, window_end, :ets) do
    table_name = :"rate_limit_#{key}"
    
    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:public, :bag, :named_table])
        []
        
      _ ->
        :ets.select(table_name, [
          {{:"$1", :request}, [{:>=, :"$1", window_start}, {:"=<", :"$1", window_end}], [:"$1"]}
        ])
    end
  end

  defp get_requests_in_window(key, window_start, window_end, :redis) do
    case Redix.command(:redis, ["ZRANGEBYSCORE", "rate_limit:#{key}", window_start, window_end]) do
      {:ok, requests} -> requests
      _ -> []
    end
  end

  defp calculate_retry_after(key, config) do
    now = System.system_time(:second)
    window_start = now - config.window_size
    requests = get_requests_in_window(key, window_start, now, config.storage)
    
    case Enum.min(requests, fn -> now end) do
      oldest when oldest > 0 -> oldest + config.window_size - now
      _ -> config.window_size
    end
  end

  defp default_key_func(signal) do
    # Rate limit by source + signal type
    "#{signal.source}:#{signal.type}"
  end
end
```

### Usage with Advanced Configuration

```elixir
# Configure bus with rate limiting
{Jido.Signal.Bus, [
  name: :my_bus,
  middleware: [
    {MyApp.RateLimitMiddleware, [
      window_size: 300,     # 5 minute window
      max_requests: 5000,   # 5000 requests per window
      storage: :redis,      # Use Redis for distributed rate limiting
      key_func: fn signal ->
        # Rate limit per user
        get_in(signal.data, ["user_id"]) || "anonymous"
      end
    ]}
  ]
]}
```

## Circuit Breaker Middleware

Implement circuit breaker patterns for external service calls:

```elixir
defmodule MyApp.CircuitBreakerMiddleware do
  @behaviour Jido.Signal.Middleware
  use GenServer

  @failure_threshold 5
  @recovery_timeout 30_000  # 30 seconds
  @half_open_max_calls 3

  def init(opts) do
    circuit_name = Keyword.get(opts, :name, :default_circuit)
    failure_threshold = Keyword.get(opts, :failure_threshold, @failure_threshold)
    recovery_timeout = Keyword.get(opts, :recovery_timeout, @recovery_timeout)
    
    # Start circuit breaker state server
    {:ok, _pid} = GenServer.start_link(__MODULE__, %{
      state: :closed,
      failure_count: 0,
      failure_threshold: failure_threshold,
      recovery_timeout: recovery_timeout,
      last_failure_time: nil,
      half_open_calls: 0
    }, name: circuit_name)
    
    %{
      circuit_name: circuit_name,
      predicate: Keyword.get(opts, :predicate, &default_failure_predicate/1)
    }
  end

  def call(signal, next, config) do
    case get_circuit_state(config.circuit_name) do
      :open ->
        {:error, %{type: :circuit_open, message: "Circuit breaker is open"}}
        
      :half_open ->
        case increment_half_open_calls(config.circuit_name) do
          :ok ->
            execute_with_monitoring(signal, next, config)
            
          :too_many_calls ->
            {:error, %{type: :circuit_half_open_full, message: "Too many half-open calls"}}
        end
        
      :closed ->
        execute_with_monitoring(signal, next, config)
    end
  end

  defp execute_with_monitoring(signal, next, config) do
    start_time = System.monotonic_time(:millisecond)
    
    try do
      result = next.(signal)
      
      case result do
        {:ok, _} = success ->
          record_success(config.circuit_name)
          success
          
        {:error, error} ->
          if config.predicate.(error) do
            record_failure(config.circuit_name)
          end
          {:error, error}
      end
    rescue
      error ->
        record_failure(config.circuit_name)
        {:error, %{type: :exception, message: Exception.message(error)}}
    after
      duration = System.monotonic_time(:millisecond) - start_time
      :telemetry.execute([:circuit_breaker, :call], %{duration: duration}, %{
        circuit: config.circuit_name,
        signal_type: signal.type
      })
    end
  end

  # GenServer callbacks for circuit state management
  def handle_call(:get_state, _from, state) do
    current_state = determine_current_state(state)
    {:reply, current_state, %{state | state: current_state}}
  end

  def handle_call(:record_success, _from, state) do
    new_state = %{state | 
      state: :closed, 
      failure_count: 0, 
      half_open_calls: 0
    }
    {:reply, :ok, new_state}
  end

  def handle_call(:record_failure, _from, state) do
    new_failure_count = state.failure_count + 1
    
    new_state = if new_failure_count >= state.failure_threshold do
      %{state | 
        state: :open,
        failure_count: new_failure_count,
        last_failure_time: System.monotonic_time(:millisecond),
        half_open_calls: 0
      }
    else
      %{state | failure_count: new_failure_count}
    end
    
    {:reply, :ok, new_state}
  end

  def handle_call(:increment_half_open, _from, state) do
    if state.half_open_calls < @half_open_max_calls do
      {:reply, :ok, %{state | half_open_calls: state.half_open_calls + 1}}
    else
      {:reply, :too_many_calls, state}
    end
  end

  defp determine_current_state(state) do
    case state.state do
      :open ->
        if state.last_failure_time && 
           System.monotonic_time(:millisecond) - state.last_failure_time > state.recovery_timeout do
          :half_open
        else
          :open
        end
      other -> other
    end
  end

  defp get_circuit_state(circuit_name) do
    GenServer.call(circuit_name, :get_state)
  end

  defp record_success(circuit_name) do
    GenServer.call(circuit_name, :record_success)
  end

  defp record_failure(circuit_name) do
    GenServer.call(circuit_name, :record_failure)
  end

  defp increment_half_open_calls(circuit_name) do
    GenServer.call(circuit_name, :increment_half_open)
  end

  defp default_failure_predicate(error) do
    # Consider timeouts and service unavailable as failures
    case error do
      %{type: :timeout} -> true
      %{type: :service_unavailable} -> true
      %{type: :connection_failed} -> true
      _ -> false
    end
  end
end
```

## Message Enrichment Middleware

Enrich signals with additional context and data:

```elixir
defmodule MyApp.EnrichmentMiddleware do
  @behaviour Jido.Signal.Middleware
  
  def init(opts) do
    %{
      enrichers: Keyword.get(opts, :enrichers, []),
      timeout: Keyword.get(opts, :timeout, 5000),
      async: Keyword.get(opts, :async, false)
    }
  end

  def call(signal, next, config) do
    enriched_signal = if config.async do
      enrich_async(signal, config)
    else
      enrich_sync(signal, config)
    end
    
    next.(enriched_signal)
  end

  defp enrich_sync(signal, config) do
    Enum.reduce(config.enrichers, signal, fn enricher, acc_signal ->
      apply_enricher(enricher, acc_signal, config.timeout)
    end)
  end

  defp enrich_async(signal, config) do
    tasks = Enum.map(config.enrichers, fn enricher ->
      Task.async(fn -> apply_enricher(enricher, signal, config.timeout) end)
    end)
    
    # Wait for all enrichments to complete
    enriched_data = tasks
    |> Task.await_many(config.timeout)
    |> Enum.reduce(%{}, fn enriched_signal, acc ->
      Map.merge(acc, enriched_signal.data)
    end)
    
    %{signal | data: Map.merge(signal.data, enriched_data)}
  end

  defp apply_enricher({module, function, args}, signal, timeout) do
    case :timer.tc(module, function, [signal | args]) do
      {time_us, enriched_signal} when time_us < timeout * 1000 ->
        enriched_signal
      {time_us, _} ->
        :telemetry.execute([:enrichment, :timeout], %{duration: time_us}, %{
          enricher: "#{module}.#{function}",
          signal_type: signal.type
        })
        signal
    end
  rescue
    error ->
      :telemetry.execute([:enrichment, :error], %{}, %{
        enricher: "#{module}.#{function}",
        error: Exception.message(error)
      })
      signal
  end
end

# Example enricher modules
defmodule MyApp.UserEnricher do
  def enrich_with_profile(signal) do
    case get_in(signal.data, ["user_id"]) do
      nil -> signal
      user_id ->
        case MyApp.UserService.get_profile(user_id) do
          {:ok, profile} ->
            %{signal | data: Map.put(signal.data, "user_profile", profile)}
          _ ->
            signal
        end
    end
  end
end

defmodule MyApp.GeoEnricher do
  def enrich_with_location(signal) do
    case get_in(signal.data, ["ip_address"]) do
      nil -> signal
      ip ->
        case MyApp.GeoService.lookup(ip) do
          {:ok, location} ->
            %{signal | data: Map.put(signal.data, "location", location)}
          _ ->
            signal
        end
    end
  end
end
```

## Anti-Spam and Content Filtering

Implement sophisticated content filtering and spam detection:

```elixir
defmodule MyApp.ContentFilterMiddleware do
  @behaviour Jido.Signal.Middleware
  
  def init(opts) do
    %{
      filters: Keyword.get(opts, :filters, []),
      action: Keyword.get(opts, :action, :block),  # :block, :flag, :quarantine
      whitelist: Keyword.get(opts, :whitelist, []),
      learning_mode: Keyword.get(opts, :learning_mode, false)
    }
  end

  def call(signal, next, config) do
    # Skip filtering for whitelisted sources
    if signal.source in config.whitelist do
      next.(signal)
    else
      case analyze_content(signal, config) do
        {:ok, :safe} ->
          next.(signal)
          
        {:ok, :suspicious, risk_score} ->
          handle_suspicious_content(signal, next, config, risk_score)
          
        {:ok, :unsafe, violations} ->
          handle_unsafe_content(signal, next, config, violations)
      end
    end
  end

  defp analyze_content(signal, config) do
    results = Enum.map(config.filters, fn filter ->
      apply_filter(filter, signal)
    end)
    
    violations = Enum.filter(results, fn
      {:violation, _} -> true
      _ -> false
    end)
    
    risk_scores = Enum.filter(results, fn
      {:risk, _} -> true
      _ -> false
    end)
    
    cond do
      length(violations) > 0 ->
        {:ok, :unsafe, violations}
        
      length(risk_scores) > 0 ->
        total_risk = risk_scores
        |> Enum.map(fn {:risk, score} -> score end)
        |> Enum.sum()
        
        if total_risk > 0.7 do
          {:ok, :suspicious, total_risk}
        else
          {:ok, :safe}
        end
        
      true ->
        {:ok, :safe}
    end
  end

  defp apply_filter({:spam_detection, opts}, signal) do
    content = extract_text_content(signal)
    
    spam_indicators = [
      repeated_chars_score(content),
      caps_lock_score(content),
      url_density_score(content),
      suspicious_patterns_score(content)
    ]
    
    risk_score = Enum.sum(spam_indicators) / length(spam_indicators)
    
    if risk_score > Keyword.get(opts, :threshold, 0.6) do
      {:risk, risk_score}
    else
      :safe
    end
  end

  defp apply_filter({:profanity_filter, opts}, signal) do
    content = extract_text_content(signal)
    profanity_list = Keyword.get(opts, :words, [])
    
    violations = Enum.filter(profanity_list, fn word ->
      String.contains?(String.downcase(content), String.downcase(word))
    end)
    
    if length(violations) > 0 do
      {:violation, {:profanity, violations}}
    else
      :safe
    end
  end

  defp apply_filter({:rate_anomaly, opts}, signal) do
    source = signal.source
    threshold = Keyword.get(opts, :threshold, 10)  # messages per minute
    
    recent_count = count_recent_messages(source, 60)
    
    if recent_count > threshold do
      {:risk, min(recent_count / threshold, 1.0)}
    else
      :safe
    end
  end

  defp handle_suspicious_content(signal, next, config, risk_score) do
    case config.action do
      :flag ->
        flagged_signal = add_flag(signal, :suspicious, risk_score)
        next.(flagged_signal)
        
      :quarantine ->
        quarantine_signal(signal, risk_score)
        {:ok, :quarantined}
        
      :block ->
        {:error, %{type: :content_filtered, reason: :suspicious, risk_score: risk_score}}
    end
  end

  defp handle_unsafe_content(signal, next, config, violations) do
    if config.learning_mode do
      # In learning mode, log violations but allow signal through
      log_violation(signal, violations)
      flagged_signal = add_flag(signal, :unsafe, violations)
      next.(flagged_signal)
    else
      case config.action do
        :block ->
          {:error, %{type: :content_filtered, reason: :unsafe, violations: violations}}
        _ ->
          {:error, %{type: :content_filtered, reason: :unsafe, violations: violations}}
      end
    end
  end

  # Content analysis helpers
  defp extract_text_content(signal) do
    signal.data
    |> Jason.encode!()
    |> String.replace(~r/[{}",:\[\]]/, "")
  end

  defp repeated_chars_score(content) do
    repeated_sequences = Regex.scan(~r/(.)\1{3,}/, content)
    min(length(repeated_sequences) * 0.2, 1.0)
  end

  defp caps_lock_score(content) do
    uppercase_count = String.length(Regex.replace(~r/[^A-Z]/, content, ""))
    total_letters = String.length(Regex.replace(~r/[^A-Za-z]/, content, ""))
    
    if total_letters > 0 do
      uppercase_count / total_letters
    else
      0
    end
  end

  defp url_density_score(content) do
    urls = Regex.scan(~r/https?:\/\/[^\s]+/, content)
    words = String.split(content) |> length()
    
    if words > 0 do
      min(length(urls) / words * 2, 1.0)
    else
      0
    end
  end

  defp suspicious_patterns_score(content) do
    patterns = [
      ~r/\$\$\$/,      # Multiple dollar signs
      ~r/!!!/,         # Multiple exclamation marks
      ~r/click here/i, # Common spam phrases
      ~r/free money/i,
      ~r/urgent/i
    ]
    
    matches = Enum.count(patterns, fn pattern ->
      Regex.match?(pattern, content)
    end)
    
    min(matches * 0.3, 1.0)
  end

  defp count_recent_messages(source, seconds) do
    # Implementation depends on your storage mechanism
    # This is a simplified example
    :ets.select_count(:message_counts, [
      {{source, :"$1"}, [{:>, :"$1", System.system_time(:second) - seconds}], [true]}
    ])
  end

  defp add_flag(signal, flag_type, details) do
    flags = Map.get(signal.data, "content_flags", [])
    new_flag = %{
      type: flag_type,
      details: details,
      timestamp: DateTime.utc_now()
    }
    
    %{signal | data: Map.put(signal.data, "content_flags", [new_flag | flags])}
  end

  defp quarantine_signal(signal, risk_score) do
    # Store in quarantine table for manual review
    MyApp.QuarantineStore.store(signal, %{
      risk_score: risk_score,
      quarantined_at: DateTime.utc_now()
    })
  end

  defp log_violation(signal, violations) do
    :telemetry.execute([:content_filter, :violation], %{}, %{
      signal_type: signal.type,
      source: signal.source,
      violations: violations
    })
  end
end
```

## Load Shedding Middleware

Gracefully handle system overload by shedding non-critical traffic:

```elixir
defmodule MyApp.LoadSheddingMiddleware do
  @behaviour Jido.Signal.Middleware
  use GenServer
  
  def init(opts) do
    shedder_name = Keyword.get(opts, :name, :default_shedder)
    
    {:ok, _pid} = GenServer.start_link(__MODULE__, %{
      cpu_threshold: Keyword.get(opts, :cpu_threshold, 80.0),
      memory_threshold: Keyword.get(opts, :memory_threshold, 85.0),
      queue_threshold: Keyword.get(opts, :queue_threshold, 1000),
      check_interval: Keyword.get(opts, :check_interval, 1000),
      priority_levels: Keyword.get(opts, :priority_levels, %{
        critical: 0,
        high: 1,
        normal: 2,
        low: 3
      })
    }, name: shedder_name)
    
    %{
      shedder_name: shedder_name,
      priority_func: Keyword.get(opts, :priority_func, &default_priority/1)
    }
  end

  def call(signal, next, config) do
    priority = config.priority_func.(signal)
    
    case should_shed_load(config.shedder_name, priority) do
      false ->
        next.(signal)
        
      {:shed, reason} ->
        :telemetry.execute([:load_shedding, :dropped], %{}, %{
          signal_type: signal.type,
          priority: priority,
          reason: reason
        })
        
        {:error, %{
          type: :load_shed,
          reason: reason,
          retry_after: calculate_retry_after(reason)
        }}
    end
  end

  # GenServer callbacks
  def init(state) do
    schedule_health_check(state.check_interval)
    {:ok, Map.put(state, :current_load, :normal)}
  end

  def handle_info(:health_check, state) do
    load_level = assess_system_load(state)
    new_state = %{state | current_load: load_level}
    
    :telemetry.execute([:load_shedding, :health_check], %{}, %{
      cpu_usage: :cpu_sup.avg1(),
      memory_usage: get_memory_usage(),
      load_level: load_level
    })
    
    schedule_health_check(state.check_interval)
    {:noreply, new_state}
  end

  def handle_call({:should_shed, priority}, _from, state) do
    should_shed = case state.current_load do
      :critical -> priority >= state.priority_levels.high
      :high -> priority >= state.priority_levels.normal
      :medium -> priority >= state.priority_levels.low
      :normal -> false
    end
    
    result = if should_shed do
      {:shed, state.current_load}
    else
      false
    end
    
    {:reply, result, state}
  end

  defp assess_system_load(state) do
    cpu_usage = :cpu_sup.avg1() / 256 * 100  # Convert to percentage
    memory_usage = get_memory_usage()
    queue_size = get_process_queue_size()
    
    cond do
      cpu_usage > state.cpu_threshold * 1.2 or 
      memory_usage > state.memory_threshold * 1.2 or
      queue_size > state.queue_threshold * 2 ->
        :critical
        
      cpu_usage > state.cpu_threshold or 
      memory_usage > state.memory_threshold or
      queue_size > state.queue_threshold ->
        :high
        
      cpu_usage > state.cpu_threshold * 0.8 or 
      memory_usage > state.memory_threshold * 0.8 or
      queue_size > state.queue_threshold * 0.8 ->
        :medium
        
      true ->
        :normal
    end
  end

  defp get_memory_usage do
    {:ok, memory_data} = :memsup.get_system_memory_data()
    total_memory = Keyword.get(memory_data, :total_memory, 1)
    available_memory = Keyword.get(memory_data, :available_memory, total_memory)
    
    (1 - available_memory / total_memory) * 100
  end

  defp get_process_queue_size do
    Process.info(self(), :message_queue_len)
    |> elem(1)
  end

  defp schedule_health_check(interval) do
    Process.send_after(self(), :health_check, interval)
  end

  defp should_shed_load(shedder_name, priority) do
    GenServer.call(shedder_name, {:should_shed, priority})
  end

  defp default_priority(signal) do
    # Extract priority from signal metadata or determine based on type
    case get_in(signal.data, ["priority"]) do
      "critical" -> 0
      "high" -> 1
      "normal" -> 2
      "low" -> 3
      _ ->
        # Determine priority based on signal type
        case signal.type do
          "system." <> _ -> 0    # System signals are critical
          "user.auth." <> _ -> 1 # Auth signals are high priority
          "user.action." <> _ -> 2 # User actions are normal
          _ -> 3 # Everything else is low priority
        end
    end
  end

  defp calculate_retry_after(load_level) do
    case load_level do
      :critical -> 60  # 1 minute
      :high -> 30      # 30 seconds
      :medium -> 10    # 10 seconds
      _ -> 5           # 5 seconds
    end
  end
end
```

## Middleware Composition and Ordering

Proper middleware ordering is crucial for effective signal processing:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # Configure bus with carefully ordered middleware
      {Jido.Signal.Bus, [
        name: :production_bus,
        middleware: [
          # 1. Load shedding first - reject traffic early if overloaded
          {MyApp.LoadSheddingMiddleware, [
            cpu_threshold: 75.0,
            memory_threshold: 80.0,
            queue_threshold: 500
          ]},
          
          # 2. Rate limiting - prevent abuse
          {MyApp.RateLimitMiddleware, [
            window_size: 60,
            max_requests: 1000,
            storage: :redis
          ]},
          
          # 3. Authentication/authorization middleware
          {MyApp.AuthMiddleware, [
            required_permissions: [:signal_publish]
          ]},
          
          # 4. Content filtering - check for spam/abuse
          {MyApp.ContentFilterMiddleware, [
            filters: [
              {:spam_detection, threshold: 0.7},
              {:profanity_filter, words: load_profanity_list()},
              {:rate_anomaly, threshold: 20}
            ],
            action: :flag,
            learning_mode: false
          ]},
          
          # 5. Circuit breaker for external dependencies
          {MyApp.CircuitBreakerMiddleware, [
            name: :external_services_circuit,
            failure_threshold: 5,
            recovery_timeout: 30_000
          ]},
          
          # 6. Enrichment - add context (after filtering for efficiency)
          {MyApp.EnrichmentMiddleware, [
            enrichers: [
              {MyApp.UserEnricher, :enrich_with_profile, []},
              {MyApp.GeoEnricher, :enrich_with_location, []}
            ],
            timeout: 3000,
            async: true
          ]},
          
          # 7. Metrics and monitoring - capture all signal data
          {MyApp.MetricsMiddleware, [
            emit_latency: true,
            emit_throughput: true,
            sample_rate: 0.1
          ]},
          
          # 8. Audit logging - record important signals
          {MyApp.AuditMiddleware, [
            log_all: false,
            log_patterns: ["user.auth.*", "system.*", "payment.*"]
          ]}
        ]
      ]}
    ]
    
    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
  
  defp load_profanity_list do
    # Load from configuration or external service
    Application.get_env(:my_app, :profanity_words, [])
  end
end
```

## Performance Monitoring Middleware

Comprehensive metrics collection for production monitoring:

```elixir
defmodule MyApp.MetricsMiddleware do
  @behaviour Jido.Signal.Middleware
  
  def init(opts) do
    %{
      emit_latency: Keyword.get(opts, :emit_latency, true),
      emit_throughput: Keyword.get(opts, :emit_throughput, true),
      emit_errors: Keyword.get(opts, :emit_errors, true),
      sample_rate: Keyword.get(opts, :sample_rate, 1.0),
      custom_metrics: Keyword.get(opts, :custom_metrics, [])
    }
  end

  def call(signal, next, config) do
    should_sample = :rand.uniform() <= config.sample_rate
    
    if should_sample do
      execute_with_metrics(signal, next, config)
    else
      next.(signal)
    end
  end

  defp execute_with_metrics(signal, next, config) do
    start_time = System.monotonic_time(:microsecond)
    
    # Emit throughput metrics
    if config.emit_throughput do
      :telemetry.execute([:jido_signal, :middleware, :throughput], %{count: 1}, %{
        signal_type: signal.type,
        source: signal.source
      })
    end
    
    try do
      result = next.(signal)
      
      # Emit success metrics
      duration = System.monotonic_time(:microsecond) - start_time
      
      if config.emit_latency do
        :telemetry.execute([:jido_signal, :middleware, :latency], %{
          duration: duration
        }, %{
          signal_type: signal.type,
          source: signal.source,
          status: :success
        })
      end
      
      # Custom metrics
      emit_custom_metrics(signal, result, config.custom_metrics, duration)
      
      result
      
    rescue
      error ->
        duration = System.monotonic_time(:microsecond) - start_time
        
        # Emit error metrics
        if config.emit_errors do
          :telemetry.execute([:jido_signal, :middleware, :error], %{
            count: 1,
            duration: duration
          }, %{
            signal_type: signal.type,
            source: signal.source,
            error_type: error.__struct__ |> to_string()
          })
        end
        
        reraise error, __STACKTRACE__
    end
  end

  defp emit_custom_metrics(signal, result, custom_metrics, duration) do
    Enum.each(custom_metrics, fn
      {:payload_size, _opts} ->
        payload_size = :erlang.external_size(signal.data)
        :telemetry.execute([:jido_signal, :payload_size], %{bytes: payload_size}, %{
          signal_type: signal.type
        })
        
      {:processing_stages, _opts} ->
        stages = get_in(signal.data, ["processing_stages"]) || []
        :telemetry.execute([:jido_signal, :processing_stages], %{count: length(stages)}, %{
          signal_type: signal.type
        })
        
      {:user_metrics, _opts} ->
        if user_id = get_in(signal.data, ["user_id"]) do
          :telemetry.execute([:jido_signal, :user_activity], %{count: 1}, %{
            user_id: user_id,
            signal_type: signal.type
          })
        end
    end)
  end
end
```

## Testing Complex Middleware

Comprehensive testing strategies for middleware:

```elixir
defmodule MyApp.MiddlewareTest do
  use ExUnit.Case, async: true
  alias Jido.Signal
  alias MyApp.RateLimitMiddleware
  
  describe "rate limiting middleware" do
    test "allows requests under the limit" do
      config = RateLimitMiddleware.init(max_requests: 10, window_size: 60)
      
      signal = Signal.new(%{
        type: "test.signal",
        source: "/test",
        data: %{test: true}
      })
      
      # Mock next function
      next = fn s -> {:ok, s} end
      
      # Should allow first request
      assert {:ok, ^signal} = RateLimitMiddleware.call(signal, next, config)
    end
    
    test "blocks requests over the limit" do
      config = RateLimitMiddleware.init(max_requests: 2, window_size: 60)
      
      signal = Signal.new(%{
        type: "test.signal",
        source: "/test",
        data: %{test: true}
      })
      
      next = fn s -> {:ok, s} end
      
      # First two requests should succeed
      assert {:ok, ^signal} = RateLimitMiddleware.call(signal, next, config)
      assert {:ok, ^signal} = RateLimitMiddleware.call(signal, next, config)
      
      # Third request should be rate limited
      assert {:error, %{type: :rate_limited}} = 
        RateLimitMiddleware.call(signal, next, config)
    end
    
    test "respects custom key functions" do
      config = RateLimitMiddleware.init(
        max_requests: 1,
        window_size: 60,
        key_func: fn signal -> get_in(signal.data, ["user_id"]) end
      )
      
      signal1 = Signal.new(%{type: "test", source: "/test", data: %{"user_id" => "user1"}})
      signal2 = Signal.new(%{type: "test", source: "/test", data: %{"user_id" => "user2"}})
      
      next = fn s -> {:ok, s} end
      
      # Different users should have separate limits
      assert {:ok, ^signal1} = RateLimitMiddleware.call(signal1, next, config)
      assert {:ok, ^signal2} = RateLimitMiddleware.call(signal2, next, config)
      
      # Same user should be rate limited
      assert {:error, %{type: :rate_limited}} = 
        RateLimitMiddleware.call(signal1, next, config)
    end
  end
  
  describe "circuit breaker middleware" do
    test "opens circuit after failure threshold" do
      {:ok, circuit_pid} = start_supervised({
        GenServer, 
        {MyApp.CircuitBreakerMiddleware, %{
          state: :closed,
          failure_count: 0,
          failure_threshold: 2,
          recovery_timeout: 1000,
          last_failure_time: nil,
          half_open_calls: 0
        }}
      })
      
      config = CircuitBreakerMiddleware.init(
        name: circuit_pid,
        failure_threshold: 2
      )
      
      signal = Signal.new(%{type: "test", source: "/test", data: %{}})
      
      # Mock failing next function
      failing_next = fn _s -> {:error, %{type: :service_unavailable}} end
      
      # First failure
      assert {:error, %{type: :service_unavailable}} = 
        CircuitBreakerMiddleware.call(signal, failing_next, config)
        
      # Second failure should open circuit
      assert {:error, %{type: :service_unavailable}} = 
        CircuitBreakerMiddleware.call(signal, failing_next, config)
      
      # Subsequent calls should be blocked by open circuit
      assert {:error, %{type: :circuit_open}} = 
        CircuitBreakerMiddleware.call(signal, failing_next, config)
    end
    
    test "transitions to half-open after recovery timeout" do
      # Test implementation for half-open state
      # ... detailed test code
    end
  end
  
  describe "middleware composition" do
    test "executes middleware in correct order" do
      execution_order = []
      
      middleware1 = fn signal, next ->
        execution_order = [:middleware1_pre | execution_order]
        result = next.(signal)
        execution_order = [:middleware1_post | execution_order]
        result
      end
      
      middleware2 = fn signal, next ->
        execution_order = [:middleware2_pre | execution_order]
        result = next.(signal)
        execution_order = [:middleware2_post | execution_order]
        result
      end
      
      core_processing = fn signal ->
        execution_order = [:core | execution_order]
        {:ok, signal}
      end
      
      # Compose middleware chain
      composed = middleware1.(signal, fn s ->
        middleware2.(s, core_processing)
      end)
      
      # Verify execution order
      assert Enum.reverse(execution_order) == [
        :middleware1_pre,
        :middleware2_pre, 
        :core,
        :middleware2_post,
        :middleware1_post
      ]
    end
  end
end
```

## Production Best Practices

### Configuration Management

```elixir
# config/prod.exs
config :my_app, :middleware,
  rate_limiting: [
    window_size: 300,
    max_requests: 10_000,
    storage: :redis,
    redis_url: System.get_env("REDIS_URL")
  ],
  circuit_breaker: [
    failure_threshold: 10,
    recovery_timeout: 60_000,
    half_open_max_calls: 5
  ],
  load_shedding: [
    cpu_threshold: 70.0,
    memory_threshold: 75.0,
    queue_threshold: 2000
  ]
```

### Monitoring and Alerting

```elixir
defmodule MyApp.MiddlewareMonitor do
  def handle_event([:jido_signal, :middleware, :error], measurements, metadata, _config) do
    if measurements.count > 10 do
      # Alert on high error rates
      MyApp.AlertManager.send_alert(:high_middleware_errors, %{
        error_count: measurements.count,
        signal_type: metadata.signal_type,
        error_type: metadata.error_type
      })
    end
  end
  
  def handle_event([:jido_signal, :middleware, :latency], measurements, metadata, _config) do
    if measurements.duration > 5_000_000 do  # 5 seconds
      # Alert on high latency
      MyApp.AlertManager.send_alert(:high_middleware_latency, %{
        duration_ms: measurements.duration / 1000,
        signal_type: metadata.signal_type
      })
    end
  end
end

# Attach telemetry handlers
:telemetry.attach_many(
  "middleware-monitor",
  [
    [:jido_signal, :middleware, :error],
    [:jido_signal, :middleware, :latency],
    [:circuit_breaker, :call],
    [:load_shedding, :dropped]
  ],
  &MyApp.MiddlewareMonitor.handle_event/4,
  []
)
```

### Graceful Degradation

Design middleware to gracefully handle failures:

```elixir
defmodule MyApp.ResilientMiddleware do
  @behaviour Jido.Signal.Middleware
  
  def call(signal, next, config) do
    try do
      enhanced_signal = enhance_signal(signal, config)
      next.(enhanced_signal)
    rescue
      error ->
        # Log error but don't block signal processing
        Logger.error("Middleware enhancement failed: #{Exception.message(error)}")
        
        # Continue with original signal
        next.(signal)
    end
  end
  
  defp enhance_signal(signal, config) do
    # Enhancement logic that might fail
    # ...
  end
end
```

This comprehensive guide provides production-ready middleware patterns that can handle real-world complexity while maintaining system reliability and performance. Each pattern includes error handling, monitoring, and testing strategies essential for production deployments.
