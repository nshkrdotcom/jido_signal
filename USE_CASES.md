# Comprehensive Use Cases and Integration Points for Jido Signal

## 1. Event-Driven Architecture Use Cases

### Microservices Communication
```elixir
# Service-to-service events
Signal.new(%{
  type: "order.created",
  source: "/order-service",
  data: %{order_id: "12345", customer_id: "67890"},
  jido_dispatch: [
    {:http, url: "https://inventory-service/webhooks", method: :post},
    {:http, url: "https://payment-service/webhooks", method: :post},
    {:pubsub, target: :event_bus, topic: "orders"}
  ]
})
```

### Domain Event Sourcing
```elixir
# Aggregate events with causality tracking
Journal.record(journal, %Signal{
  type: "account.debited",
  source: "/banking/accounts",
  subject: "account-123",
  data: %{amount: 100.00, balance: 400.00}
}, cause_id: "payment-initiated-456")
```

### CQRS Implementation
```elixir
# Command-Query separation
defmodule BankingSignals do
  # Commands
  use Jido.Signal,
    type: "banking.command.transfer",
    schema: [
      from_account: [type: :string, required: true],
      to_account: [type: :string, required: true],
      amount: [type: :float, required: true]
    ]

  # Events
  use Jido.Signal,
    type: "banking.event.transfer_completed",
    schema: [
      transaction_id: [type: :string, required: true],
      timestamp: [type: :string, required: true]
    ]
end
```

## 2. Real-Time System Integration

### IoT Device Management
```elixir
# Device telemetry processing
Router.new([
  {"sensor.temperature", MetricsCollector, 100},
  {"sensor.temperature", fn signal -> 
    signal.data.value > 85 
  end, AlertManager, 90},
  {"device.**", DeviceStateTracker, 50},
  {"device.offline", [
    {NotificationService, [priority: :high]},
    {MaintenanceScheduler, [auto_schedule: true]}
  ]}
])
```

### Real-Time Analytics
```elixir
# Streaming analytics pipeline
Bus.subscribe(analytics_bus, "metrics.**", 
  dispatch: {:pid, target: analytics_processor},
  persistent?: true,
  start_from: :current
)

# Time-series data collection
Signal.new(%{
  type: "metrics.cpu_usage",
  source: "/monitoring/node-1",
  data: %{
    value: 85.5,
    timestamp: DateTime.utc_now(),
    tags: %{hostname: "web-01", region: "us-east"}
  },
  jido_dispatch: [
    {:webhook, url: "https://metrics.company.com/ingest"},
    {:logger, level: :debug}
  ]
})
```

### Live Dashboard Updates
```elixir
# Real-time UI updates via PubSub
Router.add(router, [
  {"user.activity.**", {:pubsub, target: :dashboard_pubsub, topic: "user_events"}},
  {"system.performance.**", {:pubsub, target: :dashboard_pubsub, topic: "system_metrics"}},
  {"alert.**", {:pubsub, target: :dashboard_pubsub, topic: "alerts"}}
])
```

## 3. Workflow and Process Management

### Business Process Orchestration
```elixir
# Multi-step workflow coordination
defmodule OrderWorkflow do
  def handle_order_created(signal) do
    # Step 1: Validate inventory
    Signal.new(%{
      type: "inventory.check_requested",
      source: "/order-workflow",
      subject: signal.data.order_id,
      data: %{items: signal.data.items},
      jido_dispatch: {:http, url: "https://inventory-service/check"}
    })
  end
  
  def handle_inventory_confirmed(signal) do
    # Step 2: Process payment
    Signal.new(%{
      type: "payment.charge_requested",
      source: "/order-workflow", 
      subject: signal.subject,
      data: %{amount: signal.data.total_amount},
      jido_dispatch: {:http, url: "https://payment-service/charge"}
    })
  end
end
```

### State Machine Implementation
```elixir
# Process state transitions
Router.new([
  {"order.created", OrderStateMachine},
  {"payment.completed", OrderStateMachine},
  {"inventory.reserved", OrderStateMachine},
  {"shipping.dispatched", OrderStateMachine}
])

# State machine tracks transitions via journal
defmodule OrderStateMachine do
  def handle_signal(signal) do
    current_state = get_order_state(signal.subject)
    new_state = transition(current_state, signal.type)
    
    Signal.new(%{
      type: "order.state_changed",
      source: "/state-machine",
      subject: signal.subject,
      data: %{from: current_state, to: new_state},
      jido_dispatch: [
        {:logger, level: :info},
        {:pubsub, target: :order_events, topic: "state_changes"}
      ]
    })
  end
end
```

### Saga Pattern Implementation
```elixir
# Distributed transaction coordination
defmodule BookingTrip do
  def start_saga(booking_data) do
    saga_id = ID.generate!()
    
    # Step 1: Reserve flight
    Signal.new(%{
      type: "flight.reservation_requested",
      source: "/booking-saga",
      subject: saga_id,
      data: booking_data.flight,
      jido_dispatch: {:http, url: "https://flight-service/reserve"}
    })
  end
  
  def handle_flight_reserved(signal) do
    # Step 2: Reserve hotel
    Signal.new(%{
      type: "hotel.reservation_requested", 
      source: "/booking-saga",
      subject: signal.subject,
      data: signal.data.hotel_details,
      jido_dispatch: {:http, url: "https://hotel-service/reserve"}
    })
  end
  
  def handle_failure(signal) do
    # Compensation: Cancel previous reservations
    Signal.new(%{
      type: "saga.compensation_requested",
      source: "/booking-saga",
      subject: signal.subject,
      data: %{failed_step: signal.type, reason: signal.data.error},
      jido_dispatch: {:named, target: {:name, :compensation_manager}}
    })
  end
end
```

## 4. External System Integration

### Webhook Integration
```elixir
# Incoming webhook processing
defmodule WebhookHandler do
  def handle_github_webhook(payload) do
    Signal.new(%{
      type: "github.push_received",
      source: "/webhooks/github",
      data: payload,
      jido_dispatch: [
        {:named, target: {:name, :ci_pipeline}},
        {:logger, level: :info}
      ]
    })
  end
  
  def handle_stripe_webhook(payload) do
    Signal.new(%{
      type: "stripe.payment_intent.succeeded",
      source: "/webhooks/stripe", 
      data: payload,
      jido_dispatch: [
        {:http, url: "https://fulfillment-service/process"},
        {:pubsub, target: :payment_events, topic: "successful_payments"}
      ]
    })
  end
end

# Outgoing webhook delivery
Signal.new(%{
  type: "user.signup_completed",
  source: "/auth-service",
  data: %{user_id: "123", email: "user@example.com"},
  jido_dispatch: [
    {:webhook, 
     url: "https://customer-service.partner.com/user-events",
     secret: "webhook-secret-key",
     event_type_map: %{"user.signup_completed" => "user.created"}
    }
  ]
})
```

### Message Queue Integration
```elixir
# RabbitMQ/Kafka bridge
defmodule MessageQueueAdapter do
  @behaviour Jido.Signal.Dispatch.Adapter
  
  def validate_opts(opts) do
    # Validate queue connection options
    {:ok, opts}
  end
  
  def deliver(signal, opts) do
    queue = Keyword.fetch!(opts, :queue)
    exchange = Keyword.get(opts, :exchange, "signals")
    
    payload = Jason.encode!(signal)
    
    case AMQP.Basic.publish(channel, exchange, queue, payload) do
      :ok -> :ok
      error -> {:error, error}
    end
  end
end

# Usage
Signal.new(%{
  type: "order.shipped",
  source: "/fulfillment",
  data: %{tracking_number: "1234567890"},
  jido_dispatch: [
    {:message_queue, queue: "order_updates", exchange: "orders"},
    {:email, template: "shipping_notification"}
  ]
})
```

### Database Change Streams
```elixir
# Database trigger -> Signal conversion
defmodule DatabaseChangeListener do
  def handle_user_change(%{operation: "INSERT", table: "users", data: user_data}) do
    Signal.new(%{
      type: "user.created",
      source: "/database/users",
      subject: user_data.id,
      data: user_data,
      jido_dispatch: [
        {:pubsub, target: :user_events, topic: "user_lifecycle"},
        {:webhook, url: "https://crm.company.com/webhooks/users"}
      ]
    })
  end
  
  def handle_order_change(%{operation: "UPDATE", table: "orders", data: order_data}) do
    Signal.new(%{
      type: "order.status_changed",
      source: "/database/orders", 
      subject: order_data.id,
      data: %{
        status: order_data.status,
        previous_status: order_data.previous_status
      },
      jido_dispatch: {:named, target: {:name, :order_processor}}
    })
  end
end
```

## 5. Monitoring and Observability

### Distributed Tracing
```elixir
# Trace correlation across services
defmodule TracingMiddleware do
  use Jido.Signal.Bus.Middleware
  
  def before_publish(signals, context, state) do
    traced_signals = Enum.map(signals, fn signal ->
      trace_id = :opentelemetry.get_trace_id()
      span_id = :opentelemetry.get_span_id()
      
      %{signal | 
        data: Map.merge(signal.data, %{
          trace_id: trace_id,
          span_id: span_id,
          parent_span: context.metadata[:parent_span]
        })
      }
    end)
    
    {:cont, traced_signals, state}
  end
end
```

### Metrics Collection
```elixir
# System metrics aggregation
defmodule MetricsCollector do
  def collect_system_metrics do
    [:cpu, :memory, :disk].each(fn metric_type ->
      value = System.get_metric(metric_type)
      
      Signal.new(%{
        type: "system.metrics.#{metric_type}",
        source: "/monitoring/#{Node.self()}",
        data: %{
          value: value,
          timestamp: DateTime.utc_now(),
          node: Node.self()
        },
        jido_dispatch: [
          {:http, url: "https://metrics.company.com/v1/metrics", method: :post},
          {:logger, level: :debug, structured: true}
        ]
      })
    end)
  end
end

# Custom business metrics
Signal.new(%{
  type: "business.revenue.daily_total", 
  source: "/analytics/revenue",
  data: %{
    amount: 15_000.50,
    currency: "USD",
    date: Date.utc_today(),
    breakdown: %{
      subscriptions: 12_000.00,
      one_time: 3_000.50
    }
  },
  jido_dispatch: [
    {:webhook, url: "https://dashboard.company.com/webhooks/metrics"},
    {:pubsub, target: :analytics_pubsub, topic: "revenue_metrics"}
  ]
})
```

### Error Tracking and Alerting
```elixir
# Error aggregation and notification
Router.new([
  {"error.**", ErrorAggregator, 100},
  {"error.critical", fn signal ->
    signal.data.severity == "critical"
  end, PagerDutyAlert, 95},
  {"error.rate_exceeded", SlackNotifier, 90}
])

defmodule ErrorAggregator do
  def handle_error_signal(signal) do
    # Check error rate thresholds
    error_rate = calculate_error_rate(signal.source)
    
    if error_rate > 0.05 do
      Signal.new(%{
        type: "error.rate_exceeded",
        source: "/monitoring/error-aggregator",
        data: %{
          source_service: signal.source,
          error_rate: error_rate,
          threshold: 0.05,
          sample_errors: get_recent_errors(signal.source, 5)
        },
        jido_dispatch: [
          {:webhook, url: "https://alerts.company.com/error-rate"},
          {:pubsub, target: :alerts_pubsub, topic: "error_rates"}
        ]
      })
    end
  end
end
```

### Health Check Orchestration
```elixir
# Distributed health monitoring
defmodule HealthChecker do
  def schedule_health_checks do
    services = ["auth", "orders", "payments", "inventory"]
    
    Enum.each(services, fn service ->
      Signal.new(%{
        type: "health.check_requested",
        source: "/monitoring/health-checker",
        subject: service,
        data: %{service: service, check_type: "deep"},
        jido_dispatch: {:http, 
          url: "https://#{service}-service/health",
          timeout: 5000
        }
      })
    end)
  end
  
  def handle_health_response(signal) do
    case signal.data.status do
      "healthy" -> :ok
      "degraded" -> 
        Signal.new(%{
          type: "health.degraded",
          source: "/monitoring/health-checker",
          subject: signal.subject,
          data: signal.data,
          jido_dispatch: {:webhook, url: "https://alerts.company.com/health"}
        })
      "unhealthy" ->
        Signal.new(%{
          type: "health.failed",
          source: "/monitoring/health-checker", 
          subject: signal.subject,
          data: signal.data,
          jido_dispatch: [
            {:webhook, url: "https://alerts.company.com/health", priority: :critical},
            {:named, target: {:name, :incident_manager}}
          ]
        })
    end
  end
end
```

## 6. Data Processing Pipelines

### ETL Pipeline Coordination
```elixir
# Data transformation workflow
defmodule DataPipeline do
  def start_etl_job(source_config) do
    job_id = ID.generate!()
    
    Signal.new(%{
      type: "etl.extraction_started",
      source: "/data-pipeline/orchestrator",
      subject: job_id,
      data: source_config,
      jido_dispatch: [
        {:named, target: {:name, :data_extractor}},
        {:logger, level: :info}
      ]
    })
  end
  
  def handle_extraction_complete(signal) do
    Signal.new(%{
      type: "etl.transformation_requested",
      source: "/data-pipeline/orchestrator",
      subject: signal.subject,
      data: %{
        extracted_records: signal.data.record_count,
        data_location: signal.data.output_path
      },
      jido_dispatch: {:named, target: {:name, :data_transformer}}
    })
  end
  
  def handle_transformation_complete(signal) do
    Signal.new(%{
      type: "etl.load_requested",
      source: "/data-pipeline/orchestrator",
      subject: signal.subject, 
      data: %{
        transformed_data: signal.data.output_path,
        target_schema: signal.data.schema
      },
      jido_dispatch: {:named, target: {:name, :data_loader}}
    })
  end
end
```

### Stream Processing
```elixir
# Real-time data stream processing
defmodule StreamProcessor do
  def setup_processing_pipeline do
    Router.new([
      # Raw events
      {"stream.raw.**", DataValidator, 100},
      
      # Validated events  
      {"stream.validated.**", [
        {DataEnricher, []},
        {DuplicateDetector, []},
        {DataClassifier, []}
      ], 90},
      
      # Enriched events
      {"stream.enriched.**", [
        {AggregationEngine, []},
        {MLFeatureExtractor, []},
        {OutputWriter, []}
      ], 80},
      
      # Anomaly detection
      {"stream.anomaly_detected", [
        {AlertManager, [severity: :high]},
        {IncidentLogger, []}
      ], 70}
    ])
  end
end

# Window-based aggregations  
defmodule WindowAggregator do
  def process_window_close(window_id) do
    aggregated_data = calculate_window_metrics(window_id)
    
    Signal.new(%{
      type: "analytics.window_aggregated",
      source: "/stream-processor/aggregator",
      data: %{
        window_id: window_id,
        metrics: aggregated_data,
        window_size: "5m"
      },
      jido_dispatch: [
        {:http, url: "https://analytics.company.com/windows", method: :post},
        {:pubsub, target: :analytics_events, topic: "aggregations"}
      ]
    })
  end
end
```

### ML Pipeline Integration
```elixir
# Machine learning workflow coordination
defmodule MLPipeline do
  def trigger_model_training(dataset_id) do
    Signal.new(%{
      type: "ml.training_requested",
      source: "/ml-pipeline/orchestrator",
      subject: dataset_id,
      data: %{
        dataset_id: dataset_id,
        model_type: "classification",
        hyperparameters: %{learning_rate: 0.01, epochs: 100}
      },
      jido_dispatch: {:http, 
        url: "https://ml-service/train",
        method: :post,
        timeout: 3_600_000  # 1 hour timeout
      }
    })
  end
  
  def handle_training_complete(signal) do
    Signal.new(%{
      type: "ml.model_validation_requested",
      source: "/ml-pipeline/orchestrator",
      subject: signal.subject,
      data: %{
        model_id: signal.data.model_id,
        validation_dataset: signal.data.validation_set
      },
      jido_dispatch: {:http, url: "https://ml-service/validate"}
    })
  end
  
  def handle_validation_complete(signal) do
    if signal.data.accuracy > 0.95 do
      Signal.new(%{
        type: "ml.model_deployment_requested",
        source: "/ml-pipeline/orchestrator",
        subject: signal.subject,
        data: %{
          model_id: signal.data.model_id,
          deployment_env: "production"
        },
        jido_dispatch: {:http, url: "https://ml-service/deploy"}
      })
    else
      Signal.new(%{
        type: "ml.model_rejected",
        source: "/ml-pipeline/orchestrator",
        subject: signal.subject,
        data: %{
          model_id: signal.data.model_id,
          accuracy: signal.data.accuracy,
          threshold: 0.95
        },
        jido_dispatch: {:logger, level: :warn}
      })
    end
  end
end
```

## 7. Security and Compliance

### Audit Logging
```elixir
# Comprehensive audit trail
defmodule AuditLogger do
  use Jido.Signal.Bus.Middleware
  
  def before_dispatch(signal, subscriber, context, state) do
    # Log all signal dispatches for audit
    audit_signal = Signal.new(%{
      type: "audit.signal_dispatched",
      source: "/audit/middleware",
      data: %{
        original_signal_id: signal.id,
        original_signal_type: signal.type,
        subscriber_target: format_target(subscriber.dispatch),
        timestamp: DateTime.utc_now(),
        context: context
      },
      jido_dispatch: [
        {:http, url: "https://audit-service.company.com/events"},
        {:logger, level: :info, structured: true}
      ]
    })
    
    {:cont, signal, state}
  end
end

# Sensitive data access tracking
Signal.new(%{
  type: "security.sensitive_data_accessed",
  source: "/user-service/profile",
  data: %{
    user_id: "user-123",
    accessed_by: "admin-456", 
    data_type: "personal_information",
    access_reason: "customer_support_request",
    session_id: "session-789"
  },
  jido_dispatch: [
    {:http, url: "https://security-audit.company.com/access-logs"},
    {:logger, level: :warn, structured: true}
  ]
})
```

### Compliance Monitoring
```elixir
# GDPR compliance tracking
defmodule GDPRCompliance do
  def track_data_processing(signal) do
    if contains_personal_data?(signal.data) do
      Signal.new(%{
        type: "compliance.gdpr.data_processed",
        source: "/compliance/gdpr-monitor",
        data: %{
          original_signal: signal.id,
          data_subject: extract_data_subject(signal.data),
          processing_purpose: signal.data.purpose,
          legal_basis: signal.data.legal_basis,
          retention_period: signal.data.retention_days
        },
        jido_dispatch: [
          {:http, url: "https://compliance.company.com/gdpr-log"},
          {:logger, level: :info}
        ]
      })
    end
  end
  
  def handle_data_deletion_request(signal) do
    Signal.new(%{
      type: "compliance.gdpr.deletion_requested",
      source: "/compliance/gdpr-processor",
      subject: signal.data.user_id,
      data: %{
        user_id: signal.data.user_id,
        request_date: DateTime.utc_now(),
        verification_status: "pending"
      },
      jido_dispatch: [
        {:named, target: {:name, :data_deletion_orchestrator}},
        {:logger, level: :info}
      ]
    })
  end
end
```

### Authentication and Authorization
```elixir
# Permission-based signal filtering
defmodule AuthorizationMiddleware do
  use Jido.Signal.Bus.Middleware
  
  def before_dispatch(signal, subscriber, context, state) do
    case authorize_signal_access(signal, subscriber, context) do
      :authorized -> 
        {:cont, signal, state}
      :unauthorized ->
        # Log unauthorized access attempt
        Signal.new(%{
          type: "security.unauthorized_access_attempt",
          source: "/security/authorization-middleware",
          data: %{
            signal_type: signal.type,
            subscriber: format_subscriber(subscriber),
            denied_reason: "insufficient_permissions"
          },
          jido_dispatch: {:logger, level: :warn}
        })
        {:skip, state}
      {:error, reason} ->
        {:halt, reason, state}
    end
  end
  
  defp authorize_signal_access(signal, subscriber, context) do
    # Check if subscriber has permission for this signal type
    required_permission = "signal:#{signal.type}:read"
    subscriber_permissions = get_subscriber_permissions(subscriber)
    
    if required_permission in subscriber_permissions do
      :authorized
    else
      :unauthorized
    end
  end
end
```

## 8. Testing and Development

### Test Event Generation
```elixir
# Test data generation for development
defmodule TestEventGenerator do
  def generate_user_journey(user_id) do
    events = [
      %{type: "user.registered", data: %{user_id: user_id}},
      %{type: "user.email_verified", data: %{user_id: user_id}},
      %{type: "user.profile_completed", data: %{user_id: user_id}},
      %{type: "subscription.started", data: %{user_id: user_id, plan: "pro"}}
    ]
    
    Enum.each(events, fn event ->
      Signal.new(%{
        type: event.type,
        source: "/test/user-journey-generator",
        subject: user_id,
        data: event.data,
        jido_dispatch: [
          {:logger, level: :debug},
          {:pubsub, target: :test_events, topic: "user_journeys"}
        ]
      })
      
      # Simulate realistic timing
      Process.sleep(:rand.uniform(1000))
    end)
  end
end

# Load testing signal generation
defmodule LoadTestGenerator do
  def generate_load(signals_per_second, duration_seconds) do
    interval = div(1000, signals_per_second)
    end_time = System.system_time(:millisecond) + (duration_seconds * 1000)
    
    spawn(fn -> 
      generate_signals_loop(interval, end_time)
    end)
  end
  
  defp generate_signals_loop(interval, end_time) do
    if System.system_time(:millisecond) < end_time do
      Signal.new(%{
        type: "load_test.signal_generated",
        source: "/test/load-generator",
        data: %{
          sequence: :erlang.unique_integer([:positive]),
          timestamp: DateTime.utc_now()
        },
        jido_dispatch: {:noop, []}
      })
      
      Process.sleep(interval)
      generate_signals_loop(interval, end_time)
    end
  end
end
```

### Development Utilities
```elixir
# Signal debugging and inspection
defmodule SignalDebugger do
  def setup_debug_routing(bus) do
    # Catch-all debug subscription
    Bus.subscribe(bus, "**",
      dispatch: {:console, []},
      subscription_id: "debug-console"
    )
    
    # Signal flow visualization
    Bus.subscribe(bus, "**", 
      dispatch: {:named, target: {:name, :signal_tracer}},
      subscription_id: "debug-tracer"
    )
  end
  
  def trace_signal_flow(signal_id) do
    # Get signal from journal
    case Journal.get_signal(journal, signal_id) do
      {:ok, signal} ->
        effects = Journal.get_effects(journal, signal_id)
        cause = Journal.get_cause(journal, signal_id)
        
        IO.puts("Signal Flow for #{signal_id}:")
        if cause, do: IO.puts("  Caused by: #{cause.id} (#{cause.type})")
        IO.puts("  Signal: #{signal.type}")
        IO.puts("  Effects:")
        Enum.each(effects, fn effect ->
          IO.puts("    -> #{effect.id} (#{effect.type})")
        end)
        
      {:error, :not_found} ->
        IO.puts("Signal #{signal_id} not found")
    end
  end
end

# Development event replay
defmodule EventReplayer do
  def replay_production_events(bus, date_range) do
    # Load events from production backup
    events = load_production_events(date_range)
    
    Enum.each(events, fn event ->
      # Replay with development dispatch config
      signal = %{event | 
        jido_dispatch: [
          {:logger, level: :info},
          {:pubsub, target: :dev_events, topic: "replayed"}
        ]
      }
      
      Bus.publish(bus, [signal])
      Process.sleep(10)  # Throttle replay
    end)
  end
end
```

## Integration Points Summary

### External System Types
1. **HTTP APIs** - REST/GraphQL service integration
2. **Message Queues** - RabbitMQ, Apache Kafka, AWS SQS
3. **Databases** - Change streams, triggers, event sourcing
4. **Webhooks** - Bidirectional webhook communication
5. **PubSub Systems** - Redis, Phoenix PubSub, Google Cloud Pub/Sub
6. **Monitoring Tools** - Prometheus, Grafana, DataDog, New Relic
7. **Notification Services** - Email, SMS, Push notifications, Slack
8. **Authentication Providers** - OAuth, SAML, JWT validation
9. **Cloud Services** - AWS Lambda, Google Cloud Functions, Azure Functions
10. **IoT Platforms** - MQTT brokers, device management platforms

### Framework Integration
1. **Phoenix Framework** - Real-time channels, controllers, background jobs
2. **Oban** - Background job processing with signal triggers
3. **Broadway** - Data ingestion pipeline integration
4. **Ecto** - Database event triggers and change tracking
5. **Absinthe** - GraphQL subscription handling
6. **OpenTelemetry** - Distributed tracing and observability
7. **ExUnit** - Testing framework integration
8. **Livebook** - Interactive development and debugging

This comprehensive use case and integration point overview demonstrates the flexibility and power of the Jido Signal system for building sophisticated event-driven applications with extensive external system integration capabilities.
