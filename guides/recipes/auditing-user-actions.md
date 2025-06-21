# Recipe: Comprehensive User Action Auditing

This recipe demonstrates how to build a complete user action auditing system using Jido.Signal. You'll learn to track every user interaction while maintaining performance and compliance with data protection regulations.

## Overview

User action auditing involves capturing, storing, and analyzing all user interactions within your system. This recipe covers:

- **Comprehensive Coverage** - Using wildcard routes to capture all user actions
- **Non-intrusive Monitoring** - Low-priority handlers that don't impact user experience
- **Causality Tracking** - Journal integration for understanding action relationships
- **Compliance** - GDPR-compliant audit trails with data retention policies
- **Performance** - Optimization strategies for high-volume auditing
- **Security** - Monitoring patterns for detecting suspicious activities

## Basic Audit System Setup

### 1. Define Audit Signal Types

Create structured signal types for different audit categories:

```elixir
defmodule MyApp.Audit.UserActionSignal do
  use Jido.Signal,
    type: "audit.user.action",
    schema: [
      user_id: [type: :string, required: true],
      action: [type: :string, required: true],
      resource: [type: :string, required: false],
      resource_id: [type: :string, required: false],
      ip_address: [type: :string, required: false],
      user_agent: [type: :string, required: false],
      session_id: [type: :string, required: false],
      outcome: [type: :string, required: true, in: ["success", "failure", "partial"]],
      risk_level: [type: :string, required: false, in: ["low", "medium", "high", "critical"]],
      context: [type: :map, required: false]
    ]
end

defmodule MyApp.Audit.SecurityEventSignal do
  use Jido.Signal,
    type: "audit.security.event",
    schema: [
      event_type: [type: :string, required: true],
      severity: [type: :string, required: true, in: ["info", "warning", "critical"]],
      user_id: [type: :string, required: false],
      details: [type: :map, required: true],
      source_ip: [type: :string, required: false],
      blocked: [type: :boolean, required: false, default: false]
    ]
end

defmodule MyApp.Audit.DataAccessSignal do
  use Jido.Signal,
    type: "audit.data.access",
    schema: [
      user_id: [type: :string, required: true],
      data_type: [type: :string, required: true],
      operation: [type: :string, required: true, in: ["read", "create", "update", "delete"]],
      record_count: [type: :integer, required: false, default: 1],
      sensitive: [type: :boolean, required: false, default: false],
      purpose: [type: :string, required: false]
    ]
end
```

### 2. Create the Audit Handler

Build a comprehensive audit handler that processes all user-related signals:

```elixir
defmodule MyApp.Audit.Handler do
  use GenServer
  alias Jido.Signal.Bus
  alias MyApp.Audit.{Storage, Journal, SecurityMonitor}
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    bus_name = Keyword.get(opts, :bus, :main_bus)
    
    # Subscribe to ALL user-related signals with low priority
    Bus.subscribe(bus_name, "user.**", 
      dispatch: {:pid, target: self()},
      priority: :low,
      async: true
    )
    
    # Subscribe to system events for security monitoring
    Bus.subscribe(bus_name, "system.**",
      dispatch: {:pid, target: self()},
      priority: :low,
      async: true
    )
    
    # Subscribe to existing audit signals to prevent loops
    Bus.subscribe(bus_name, "audit.**",
      dispatch: {:pid, target: self()},
      priority: :low,
      async: true
    )
    
    state = %{
      bus: bus_name,
      stats: %{processed: 0, errors: 0},
      last_flush: System.monotonic_time(:second)
    }
    
    # Schedule periodic maintenance
    Process.send_after(self(), :maintenance, 60_000)
    
    {:ok, state}
  end

  # Handle user lifecycle events
  def handle_info({:signal, %{type: "user.created"} = signal}, state) do
    audit_signal = create_audit_signal(signal, %{
      action: "account_created",
      outcome: "success",
      risk_level: "low"
    })
    
    process_audit(audit_signal, state)
  end

  def handle_info({:signal, %{type: "user.login.attempt"} = signal}, state) do
    outcome = if signal.data[:success], do: "success", else: "failure"
    risk_level = determine_login_risk(signal)
    
    audit_signal = create_audit_signal(signal, %{
      action: "login_attempt",
      outcome: outcome,
      risk_level: risk_level,
      ip_address: signal.data[:ip_address],
      user_agent: signal.data[:user_agent]
    })
    
    # Create security event for failed logins
    if outcome == "failure" do
      security_signal = create_security_signal(signal, %{
        event_type: "failed_login",
        severity: if(risk_level in ["high", "critical"], do: "critical", else: "warning")
      })
      
      SecurityMonitor.check_threat(security_signal)
    end
    
    process_audit(audit_signal, state)
  end

  def handle_info({:signal, %{type: "user.profile.updated"} = signal}, state) do
    sensitive_fields = ["email", "phone", "ssn", "payment_info"]
    is_sensitive = Enum.any?(sensitive_fields, fn field -> 
      Map.has_key?(signal.data[:changes] || %{}, field)
    end)
    
    audit_signal = create_audit_signal(signal, %{
      action: "profile_update",
      outcome: "success",
      risk_level: if(is_sensitive, do: "medium", else: "low"),
      context: %{
        sensitive_data: is_sensitive,
        fields_changed: Map.keys(signal.data[:changes] || %{})
      }
    })
    
    process_audit(audit_signal, state)
  end

  # Handle data access patterns
  def handle_info({:signal, %{type: type} = signal}, state) 
      when type in ["user.data.read", "user.data.export", "user.data.delete"] do
    
    operation = case type do
      "user.data.read" -> "read"
      "user.data.export" -> "read"
      "user.data.delete" -> "delete"
    end
    
    data_signal = %MyApp.Audit.DataAccessSignal{
      source: "audit_system",
      data: %{
        user_id: signal.data[:user_id],
        data_type: signal.data[:data_type] || "user_profile",
        operation: operation,
        record_count: signal.data[:record_count] || 1,
        sensitive: signal.data[:sensitive] || false,
        purpose: signal.data[:purpose]
      }
    }
    
    process_audit(data_signal, state)
  end

  # Catch-all for other user signals
  def handle_info({:signal, %{type: "user." <> _} = signal}, state) do
    audit_signal = create_audit_signal(signal, %{
      action: signal.type,
      outcome: "success",
      risk_level: "low"
    })
    
    process_audit(audit_signal, state)
  end

  # Ignore audit signals to prevent loops
  def handle_info({:signal, %{type: "audit." <> _}}, state) do
    {:noreply, state}
  end

  # Maintenance tasks
  def handle_info(:maintenance, state) do
    # Flush any pending writes
    Storage.flush()
    
    # Clean up old data based on retention policies
    Storage.cleanup_expired()
    
    # Update statistics
    new_state = %{state | 
      stats: Storage.get_stats(),
      last_flush: System.monotonic_time(:second)
    }
    
    # Schedule next maintenance
    Process.send_after(self(), :maintenance, 60_000)
    
    {:noreply, new_state}
  end

  # Create audit signal from original signal
  defp create_audit_signal(original_signal, audit_data) do
    %MyApp.Audit.UserActionSignal{
      source: "audit_system",
      subject: original_signal.subject,
      data: Map.merge(%{
        user_id: extract_user_id(original_signal),
        session_id: original_signal.metadata[:session_id],
        ip_address: original_signal.metadata[:ip_address],
        user_agent: original_signal.metadata[:user_agent]
      }, audit_data),
      metadata: %{
        original_signal_id: original_signal.id,
        original_signal_type: original_signal.type,
        causation_id: Journal.get_causation_id(),
        correlation_id: Journal.get_correlation_id()
      }
    }
  end

  defp create_security_signal(original_signal, security_data) do
    %MyApp.Audit.SecurityEventSignal{
      source: "security_monitor",
      data: Map.merge(%{
        user_id: extract_user_id(original_signal),
        source_ip: original_signal.metadata[:ip_address],
        details: original_signal.data
      }, security_data),
      metadata: %{
        original_signal_id: original_signal.id,
        correlation_id: Journal.get_correlation_id()
      }
    }
  end

  defp process_audit(audit_signal, state) do
    try do
      # Store audit record
      Storage.store_audit(audit_signal)
      
      # Update causality journal
      Journal.record_event(audit_signal)
      
      # Publish audit signal for further processing
      Bus.publish(state.bus, audit_signal)
      
      new_stats = %{state.stats | processed: state.stats.processed + 1}
      {:noreply, %{state | stats: new_stats}}
    rescue
      error ->
        Logger.error("Audit processing failed: #{inspect(error)}")
        new_stats = %{state.stats | errors: state.stats.errors + 1}
        {:noreply, %{state | stats: new_stats}}
    end
  end

  defp extract_user_id(%{data: %{user_id: user_id}}), do: user_id
  defp extract_user_id(%{subject: "user:" <> user_id}), do: user_id
  defp extract_user_id(%{metadata: %{user_id: user_id}}), do: user_id
  defp extract_user_id(_), do: nil

  defp determine_login_risk(signal) do
    data = signal.data
    
    cond do
      data[:multiple_failures] && data[:failure_count] > 5 -> "critical"
      data[:suspicious_location] -> "high"
      data[:new_device] -> "medium"
      true -> "low"
    end
  end
end
```

## Storage and Journal Integration

### 3. Audit Storage Module

Implement efficient storage with built-in retention and querying:

```elixir
defmodule MyApp.Audit.Storage do
  use GenServer
  alias MyApp.Audit.{RetentionPolicy, Encryption}
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def store_audit(audit_signal) do
    GenServer.cast(__MODULE__, {:store, audit_signal})
  end

  def query_user_actions(user_id, opts \\ []) do
    GenServer.call(__MODULE__, {:query_user, user_id, opts})
  end

  def get_audit_trail(signal_id) do
    GenServer.call(__MODULE__, {:trail, signal_id})
  end

  def init(opts) do
    # Initialize database connection
    {:ok, conn} = Database.connect(opts)
    
    # Create audit tables if they don't exist
    create_audit_tables(conn)
    
    state = %{
      conn: conn,
      buffer: [],
      buffer_size: 0,
      max_buffer: Keyword.get(opts, :buffer_size, 1000),
      batch_timeout: Keyword.get(opts, :batch_timeout, 5000)
    }
    
    # Start batch processing timer
    Process.send_after(self(), :flush_buffer, state.batch_timeout)
    
    {:ok, state}
  end

  def handle_cast({:store, audit_signal}, state) do
    # Add to buffer for batch processing
    new_buffer = [prepare_audit_record(audit_signal) | state.buffer]
    new_size = state.buffer_size + 1
    
    # Flush if buffer is full
    if new_size >= state.max_buffer do
      flush_buffer(state.conn, new_buffer)
      {:noreply, %{state | buffer: [], buffer_size: 0}}
    else
      {:noreply, %{state | buffer: new_buffer, buffer_size: new_size}}
    end
  end

  def handle_call({:query_user, user_id, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)
    start_date = Keyword.get(opts, :start_date)
    end_date = Keyword.get(opts, :end_date)
    actions = Keyword.get(opts, :actions, [])
    
    query = build_user_query(user_id, limit, offset, start_date, end_date, actions)
    result = Database.query(state.conn, query)
    
    {:reply, result, state}
  end

  def handle_call({:trail, signal_id}, _from, state) do
    # Get full causality chain for a signal
    trail = get_causality_chain(state.conn, signal_id)
    {:reply, trail, state}
  end

  def handle_info(:flush_buffer, state) do
    if state.buffer_size > 0 do
      flush_buffer(state.conn, state.buffer)
      new_state = %{state | buffer: [], buffer_size: 0}
    else
      new_state = state
    end
    
    # Schedule next flush
    Process.send_after(self(), :flush_buffer, state.batch_timeout)
    {:noreply, new_state}
  end

  defp prepare_audit_record(audit_signal) do
    data = audit_signal.data
    
    %{
      id: audit_signal.id,
      timestamp: audit_signal.time,
      user_id: data.user_id,
      action: data.action,
      resource: data.resource,
      resource_id: data.resource_id,
      outcome: data.outcome,
      risk_level: data.risk_level,
      ip_address: data.ip_address,
      user_agent: data.user_agent,
      session_id: data.session_id,
      context: encrypt_if_sensitive(data.context),
      original_signal_id: audit_signal.metadata[:original_signal_id],
      causation_id: audit_signal.metadata[:causation_id],
      correlation_id: audit_signal.metadata[:correlation_id]
    }
  end

  defp flush_buffer(conn, buffer) do
    try do
      Database.batch_insert(conn, "audit_logs", buffer)
    rescue
      error ->
        Logger.error("Failed to flush audit buffer: #{inspect(error)}")
        # Store failed records for retry
        ErrorBuffer.store_failed_batch(buffer)
    end
  end

  defp encrypt_if_sensitive(nil), do: nil
  defp encrypt_if_sensitive(context) when is_map(context) do
    if context[:sensitive_data] do
      Encryption.encrypt(context)
    else
      context
    end
  end

  defp build_user_query(user_id, limit, offset, start_date, end_date, actions) do
    """
    SELECT * FROM audit_logs 
    WHERE user_id = $1
    #{if start_date, do: "AND timestamp >= $#{get_param_index(start_date)}", else: ""}
    #{if end_date, do: "AND timestamp <= $#{get_param_index(end_date)}", else: ""}
    #{if actions != [], do: "AND action = ANY($#{get_param_index(actions)})", else: ""}
    ORDER BY timestamp DESC
    LIMIT $#{get_param_index(limit)} OFFSET $#{get_param_index(offset)}
    """
  end

  defp create_audit_tables(conn) do
    Database.query(conn, """
    CREATE TABLE IF NOT EXISTS audit_logs (
      id UUID PRIMARY KEY,
      timestamp TIMESTAMPTZ NOT NULL,
      user_id VARCHAR(255) NOT NULL,
      action VARCHAR(255) NOT NULL,
      resource VARCHAR(255),
      resource_id VARCHAR(255),
      outcome VARCHAR(50) NOT NULL,
      risk_level VARCHAR(50),
      ip_address INET,
      user_agent TEXT,
      session_id VARCHAR(255),
      context JSONB,
      original_signal_id UUID,
      causation_id UUID,
      correlation_id UUID,
      created_at TIMESTAMPTZ DEFAULT NOW()
    );
    
    CREATE INDEX IF NOT EXISTS idx_audit_user_timestamp ON audit_logs(user_id, timestamp);  
    CREATE INDEX IF NOT EXISTS idx_audit_action ON audit_logs(action);
    CREATE INDEX IF NOT EXISTS idx_audit_risk_level ON audit_logs(risk_level);
    CREATE INDEX IF NOT EXISTS idx_audit_causation ON audit_logs(causation_id);
    """)
  end
end
```

### 4. Journal Integration for Causality

Track the relationships between user actions:

```elixir
defmodule MyApp.Audit.Journal do
  use GenServer
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def record_event(signal) do
    GenServer.cast(__MODULE__, {:record, signal})
  end

  def get_causation_id do
    Process.get(:causation_id)
  end

  def get_correlation_id do
    Process.get(:correlation_id) || generate_correlation_id()
  end

  def set_causation_context(causation_id, correlation_id) do
    Process.put(:causation_id, causation_id)
    Process.put(:correlation_id, correlation_id)
  end

  def init(_opts) do
    {:ok, %{events: %{}, chains: %{}}}
  end

  def handle_cast({:record, signal}, state) do
    event_record = %{
      id: signal.id,
      type: signal.type,
      timestamp: signal.time,
      causation_id: signal.metadata[:causation_id],
      correlation_id: signal.metadata[:correlation_id],
      parent_id: signal.metadata[:original_signal_id]
    }
    
    new_events = Map.put(state.events, signal.id, event_record)
    new_chains = update_causality_chain(state.chains, event_record)
    
    {:noreply, %{state | events: new_events, chains: new_chains}}
  end

  defp update_causality_chain(chains, event) do
    if event.parent_id do
      chain_id = event.causation_id || event.correlation_id
      existing_chain = Map.get(chains, chain_id, [])
      new_chain = [event | existing_chain]
      Map.put(chains, chain_id, new_chain)
    else
      chains
    end
  end

  defp generate_correlation_id do
    correlation_id = UUID.uuid4()
    Process.put(:correlation_id, correlation_id)
    correlation_id
  end
end
```

## GDPR Compliance and Data Management

### 5. Retention Policy and Data Protection

Implement GDPR-compliant data handling:

```elixir
defmodule MyApp.Audit.RetentionPolicy do
  @moduledoc """
  Handles data retention and GDPR compliance for audit logs.
  
  Retention periods:
  - Security events: 7 years
  - Financial transactions: 7 years  
  - General user actions: 2 years
  - Marketing interactions: 2 years (or until consent withdrawn)
  """
  
  def cleanup_expired do
    current_time = DateTime.utc_now()
    
    # Clean up different categories with different retention periods
    cleanup_category("general", years_ago(current_time, 2))
    cleanup_category("security", years_ago(current_time, 7))
    cleanup_category("financial", years_ago(current_time, 7))
    cleanup_marketing_data(current_time)
  end

  def handle_gdpr_request(user_id, request_type) do
    case request_type do
      :export -> export_user_data(user_id)
      :delete -> delete_user_data(user_id)
      :anonymize -> anonymize_user_data(user_id)
    end
  end

  defp export_user_data(user_id) do
    # Export all user audit data in structured format
    audit_data = MyApp.Audit.Storage.query_user_actions(user_id, limit: :all)
    
    structured_export = %{
      user_id: user_id,
      export_date: DateTime.utc_now(),
      audit_trail: Enum.map(audit_data, &format_for_export/1),
      retention_info: get_retention_info(user_id)
    }
    
    {:ok, structured_export}
  end

  defp delete_user_data(user_id) do
    # Delete audit data where legally permissible
    deletable_data = get_deletable_audit_data(user_id)
    
    Enum.each(deletable_data, fn record ->
      MyApp.Audit.Storage.delete_record(record.id)
    end)
    
    # Anonymize data that must be retained for legal purposes
    anonymize_required_retention_data(user_id)
    
    {:ok, %{deleted: length(deletable_data)}}
  end

  defp anonymize_user_data(user_id) do
    # Replace user identifiers with anonymous IDs
    anonymous_id = generate_anonymous_id()
    
    MyApp.Audit.Storage.anonymize_user_records(user_id, anonymous_id)
    
    {:ok, %{anonymized_to: anonymous_id}}
  end

  defp get_deletable_audit_data(user_id) do
    current_time = DateTime.utc_now()
    
    # Only delete data outside legal retention requirements
    MyApp.Audit.Storage.query_user_actions(user_id, 
      end_date: years_ago(current_time, 2),
      exclude_categories: ["security", "financial"]
    )
  end

  defp years_ago(datetime, years) do
    DateTime.add(datetime, -years * 365 * 24 * 60 * 60, :second)
  end
end
```

### 6. Security Monitoring and Threat Detection

Add intelligent security monitoring:

```elixir
defmodule MyApp.Audit.SecurityMonitor do
  use GenServer
  alias MyApp.Audit.{ThreatDetection, AlertSystem}
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def check_threat(security_signal) do
    GenServer.cast(__MODULE__, {:check_threat, security_signal})
  end

  def init(_opts) do
    state = %{
      user_sessions: %{},
      ip_tracking: %{},
      threat_scores: %{},
      blocked_ips: MapSet.new()
    }
    
    {:ok, state}
  end

  def handle_cast({:check_threat, signal}, state) do
    threat_level = analyze_threat(signal, state)
    
    new_state = case threat_level do
      :critical -> 
        handle_critical_threat(signal, state)
      :high -> 
        handle_high_threat(signal, state)
      :medium -> 
        track_suspicious_activity(signal, state)
      :low -> 
        update_baseline_metrics(signal, state)
    end
    
    {:noreply, new_state}
  end

  defp analyze_threat(signal, state) do
    checks = [
      check_brute_force_attack(signal, state),
      check_unusual_access_patterns(signal, state),
      check_geographic_anomalies(signal, state),
      check_privilege_escalation(signal, state)
    ]
    
    # Determine overall threat level
    case Enum.max(checks) do
      score when score >= 90 -> :critical
      score when score >= 70 -> :high  
      score when score >= 40 -> :medium
      _ -> :low
    end
  end

  defp handle_critical_threat(signal, state) do
    # Immediate response to critical threats
    user_id = signal.data.user_id
    ip_address = signal.data.source_ip
    
    # Block IP address
    new_blocked = MapSet.put(state.blocked_ips, ip_address)
    
    # Disable user account temporarily
    MyApp.Users.temporary_disable(user_id, reason: "security_threat")
    
    # Send immediate alert
    AlertSystem.send_critical_alert(%{
      type: "security_threat",
      user_id: user_id,
      ip_address: ip_address,
      details: signal.data.details,
      action_taken: "account_disabled_ip_blocked"
    })
    
    %{state | blocked_ips: new_blocked}
  end

  defp check_brute_force_attack(signal, state) do
    if signal.data.event_type == "failed_login" do
      ip = signal.data.source_ip
      recent_failures = count_recent_failures(ip, minutes: 10)
      
      cond do
        recent_failures > 20 -> 95  # Critical
        recent_failures > 10 -> 80  # High
        recent_failures > 5 -> 50   # Medium
        true -> 10                  # Low
      end
    else
      0
    end
  end

  defp check_unusual_access_patterns(signal, state) do
    user_id = signal.data.user_id
    
    if user_id do
      user_history = get_user_behavior_baseline(user_id)
      current_pattern = extract_access_pattern(signal)
      
      ThreatDetection.calculate_anomaly_score(user_history, current_pattern)
    else
      0
    end
  end
end
```

## Performance Optimization

### 7. High-Volume Auditing Strategies

Optimize for systems with millions of daily user actions:

```elixir
defmodule MyApp.Audit.PerformanceOptimizer do
  @moduledoc """
  Performance optimizations for high-volume audit systems:
  
  - Batch processing for database writes
  - Sampling for non-critical events  
  - Async processing with backpressure
  - Partitioned storage by time and user
  - Compression for long-term storage
  """

  def configure_high_volume_auditing do
    # Configure batching parameters
    Application.put_env(:my_app, :audit_batch_size, 5000)
    Application.put_env(:my_app, :audit_batch_timeout, 2000)
    
    # Configure sampling rates for different event types
    sampling_config = %{
      "user.page.view" => 0.1,      # Sample 10% of page views
      "user.search" => 0.2,         # Sample 20% of searches  
      "user.login.attempt" => 1.0,  # Audit all login attempts
      "user.profile.updated" => 1.0, # Audit all profile changes
      "user.payment.**" => 1.0       # Audit all payment events
    }
    
    Application.put_env(:my_app, :audit_sampling, sampling_config)
    
    # Configure storage partitioning
    setup_time_based_partitioning()
  end

  def should_audit?(signal_type) do
    sampling_rate = get_sampling_rate(signal_type)
    :rand.uniform() <= sampling_rate
  end

  defp get_sampling_rate(signal_type) do
    sampling_config = Application.get_env(:my_app, :audit_sampling, %{})
    
    # Check for exact match first
    case Map.get(sampling_config, signal_type) do
      nil -> 
        # Check for wildcard matches
        check_wildcard_sampling(signal_type, sampling_config)
      rate -> 
        rate
    end
  end

  defp check_wildcard_sampling(signal_type, config) do
    wildcard_matches = Enum.filter(config, fn {pattern, _rate} ->
      String.contains?(pattern, "*")
    end)
    
    Enum.find_value(wildcard_matches, 1.0, fn {pattern, rate} ->
      if matches_pattern?(signal_type, pattern) do
        rate
      else
        nil
      end
    end)
  end

  defp setup_time_based_partitioning do
    # Create monthly partitions for audit data
    Enum.each(0..12, fn months_ahead ->
      partition_date = DateTime.add(DateTime.utc_now(), months_ahead * 30 * 24 * 60 * 60, :second)
      create_monthly_partition(partition_date)
    end)
  end

  defp create_monthly_partition(date) do
    year_month = Calendar.strftime(date, "%Y_%m")
    table_name = "audit_logs_#{year_month}"
    
    Database.query("""
    CREATE TABLE IF NOT EXISTS #{table_name} (
      LIKE audit_logs INCLUDING ALL
    ) INHERITS (audit_logs);
    
    ALTER TABLE #{table_name} ADD CONSTRAINT #{table_name}_timestamp_check
    CHECK (timestamp >= '#{Calendar.strftime(date, "%Y-%m-01")}' 
           AND timestamp < '#{Calendar.strftime(Date.add(date, 32), "%Y-%m-01")}');
    """)
  end
end
```

## Complete Working Example

### 8. User Lifecycle Tracking System

Here's a complete example that tracks a user's entire lifecycle:

```elixir
defmodule MyApp.Example.UserLifecycleAudit do
  @moduledoc """
  Complete example demonstrating comprehensive user lifecycle auditing.
  
  This tracks:
  - Account creation and verification
  - Login/logout patterns
  - Profile changes and data access
  - Subscription and billing events
  - Security events and violations
  - Account deletion and data export
  """
  
  use GenServer
  alias Jido.Signal.Bus
  alias MyApp.Audit
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def demo_user_lifecycle do
    # Simulate a complete user lifecycle with auditing
    user_id = "demo_user_#{System.unique_integer()}"
    
    # 1. Account Creation
    create_user_signal = Jido.Signal.new(%{
      type: "user.created",
      source: "user_service",
      data: %{
        user_id: user_id,
        email: "demo@example.com",
        registration_method: "email"
      },
      metadata: %{
        ip_address: "192.168.1.100",
        user_agent: "Mozilla/5.0...",
        session_id: "sess_#{System.unique_integer()}"
      }
    })
    
    Bus.publish(:main_bus, create_user_signal)
    
    # 2. Email Verification
    Process.sleep(100)
    verify_signal = Jido.Signal.new(%{
      type: "user.email.verified",
      source: "auth_service", 
      data: %{user_id: user_id},
      subject: "user:#{user_id}"
    })
    
    Bus.publish(:main_bus, verify_signal)
    
    # 3. First Login
    Process.sleep(200)
    login_signal = Jido.Signal.new(%{
      type: "user.login.attempt",
      source: "auth_service",
      data: %{
        user_id: user_id,
        success: true,
        method: "password"
      },
      metadata: %{
        ip_address: "192.168.1.100",
        user_agent: "Mozilla/5.0...",
        session_id: "sess_#{System.unique_integer()}"
      }
    })
    
    Bus.publish(:main_bus, login_signal)
    
    # 4. Profile Updates (some sensitive)
    Process.sleep(300)
    profile_signal = Jido.Signal.new(%{
      type: "user.profile.updated",
      source: "profile_service",
      data: %{
        user_id: user_id,
        changes: %{
          "name" => "Demo User",
          "phone" => "+1-555-0123",  # Sensitive
          "preferences" => %{"newsletter" => true}
        }
      },
      subject: "user:#{user_id}"
    })
    
    Bus.publish(:main_bus, profile_signal)
    
    # 5. Subscription Event
    Process.sleep(150)
    subscription_signal = Jido.Signal.new(%{
      type: "user.subscription.created",
      source: "billing_service",
      data: %{
        user_id: user_id,
        plan: "premium",
        amount: 2999,  # $29.99
        currency: "USD"
      },
      subject: "user:#{user_id}"
    })
    
    Bus.publish(:main_bus, subscription_signal)
    
    # 6. Suspicious Activity (failed login from different IP)
    Process.sleep(400)
    suspicious_login = Jido.Signal.new(%{
      type: "user.login.attempt",
      source: "auth_service",
      data: %{
        user_id: user_id,
        success: false,
        method: "password",
        failure_reason: "invalid_password",
        failure_count: 3,
        suspicious_location: true
      },
      metadata: %{
        ip_address: "203.0.113.42",  # Different IP
        user_agent: "curl/7.68.0",   # Suspicious user agent
        session_id: "sess_#{System.unique_integer()}"
      }
    })
    
    Bus.publish(:main_bus, suspicious_login)
    
    # 7. Data Export Request (GDPR)
    Process.sleep(200)
    export_signal = Jido.Signal.new(%{
      type: "user.data.export",
      source: "privacy_service",
      data: %{
        user_id: user_id,
        request_type: "gdpr_export",
        data_types: ["profile", "audit_logs", "billing"]
      },
      subject: "user:#{user_id}"
    })
    
    Bus.publish(:main_bus, export_signal)
    
    # Allow time for processing
    Process.sleep(1000)
    
    # Query the audit trail
    audit_trail = Audit.Storage.query_user_actions(user_id, limit: 50)
    
    IO.puts("\n=== User Lifecycle Audit Trail ===")
    IO.puts("User ID: #{user_id}")
    IO.puts("Total Audit Records: #{length(audit_trail)}")
    
    Enum.each(audit_trail, fn record ->
      IO.puts("#{record.timestamp} | #{record.action} | #{record.outcome} | Risk: #{record.risk_level}")
    end)
    
    # Show security events
    security_events = Audit.Storage.query_security_events(user_id)
    if length(security_events) > 0 do
      IO.puts("\n=== Security Events ===")
      Enum.each(security_events, fn event ->
        IO.puts("#{event.timestamp} | #{event.event_type} | Severity: #{event.severity}")
      end)
    end
    
    user_id
  end

  def init(opts) do
    bus_name = Keyword.get(opts, :bus, :main_bus)
    {:ok, %{bus: bus_name}}
  end
end
```

## Querying and Reporting

### 9. Audit Data Analysis

Build comprehensive reporting capabilities:

```elixir
defmodule MyApp.Audit.Reporting do
  @moduledoc """
  Comprehensive audit reporting and analysis tools.
  """
  
  def generate_user_activity_report(user_id, date_range) do
    actions = MyApp.Audit.Storage.query_user_actions(user_id, 
      start_date: date_range.start,
      end_date: date_range.end
    )
    
    %{
      user_id: user_id,
      period: date_range,
      total_actions: length(actions),
      action_breakdown: group_by_action(actions),
      risk_analysis: analyze_risk_patterns(actions),
      timeline: build_timeline(actions),
      security_events: count_security_events(actions)
    }
  end

  def generate_security_summary(date_range) do
    security_events = get_security_events(date_range)
    
    %{
      period: date_range,
      total_events: length(security_events),
      critical_events: count_by_severity(security_events, "critical"),
      blocked_attempts: count_blocked_activities(security_events),
      top_threat_sources: find_top_threat_sources(security_events),
      recommendations: generate_security_recommendations(security_events)
    }
  end

  def compliance_audit_report(date_range) do
    %{
      period: date_range,
      gdpr_requests: count_gdpr_requests(date_range),
      data_exports: count_data_exports(date_range),
      account_deletions: count_account_deletions(date_range),
      retention_compliance: check_retention_compliance(date_range),
      audit_completeness: verify_audit_completeness(date_range)
    }
  end

  defp group_by_action(actions) do
    Enum.group_by(actions, & &1.action)
    |> Enum.map(fn {action, records} ->
      {action, %{
        count: length(records),
        success_rate: calculate_success_rate(records),
        avg_risk_level: calculate_avg_risk(records)
      }}
    end)
    |> Enum.into(%{})
  end

  defp analyze_risk_patterns(actions) do
    risk_counts = Enum.group_by(actions, & &1.risk_level)
                 |> Enum.map(fn {level, records} -> {level, length(records)} end)
                 |> Enum.into(%{})
    
    high_risk_actions = Enum.filter(actions, &(&1.risk_level in ["high", "critical"]))
    
    %{
      risk_distribution: risk_counts,
      high_risk_count: length(high_risk_actions),
      risk_trend: calculate_risk_trend(actions)
    }
  end
end
```

## Best Practices Summary

### Key Recommendations

1. **Use Low-Priority Handlers** - Ensure audit processing doesn't impact user experience
2. **Implement Sampling** - For high-volume systems, audit critically based on risk levels
3. **Batch Database Operations** - Use buffering and batch inserts for performance
4. **Partition Data** - Use time-based partitioning for efficient querying
5. **Encrypt Sensitive Context** - Protect sensitive audit data with encryption
6. **Plan for GDPR** - Build data export, deletion, and anonymization from the start
7. **Monitor Performance** - Track audit system performance and adjust as needed
8. **Causality Tracking** - Use journal integration to understand action relationships
9. **Security Integration** - Combine auditing with real-time threat detection
10. **Regular Cleanup** - Implement automated retention policies and data cleanup

### Configuration Example

```elixir
# config/config.exs
config :my_app, :audit,
  bus: :main_bus,
  storage: [
    batch_size: 1000,
    batch_timeout: 5000,
    encryption: true
  ],
  retention: [
    general: {years: 2},
    security: {years: 7}, 
    financial: {years: 7}
  ],
  sampling: %{
    "user.page.view" => 0.1,
    "user.search" => 0.2,
    "user.login.**" => 1.0,
    "user.payment.**" => 1.0
  },
  gdpr: [
    export_format: :json,
    anonymization: true,
    deletion_grace_period: {days: 30}
  ]
```

This comprehensive auditing system provides complete visibility into user actions while maintaining performance, compliance, and security. The modular design allows you to customize components based on your specific requirements and compliance needs.
