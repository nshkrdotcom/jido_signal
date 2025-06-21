# Guide: The Dispatch System

The Dispatch System is Jido.Signal's pluggable architecture for sending signals to various destinations. It provides a unified interface for delivering signals to processes, external services, logging systems, and custom endpoints.

## Adapter-Based Architecture

The dispatch system uses adapters to handle different delivery mechanisms. Each adapter implements the `Jido.Signal.Dispatch.Adapter` behaviour, providing consistent interfaces for validation and delivery.

```elixir
# Basic dispatch configuration
dispatch_config = {:pid, target: self()}

# Dispatch with options
dispatch_config = {:http, url: "https://api.example.com/webhook", headers: %{"Authorization" => "Bearer token"}}
```

## Built-in Adapters

### `:pid` - Process Delivery

Sends signals directly to Elixir processes:

```elixir
# Send to a specific PID
Bus.subscribe(:my_bus, "user.*", dispatch: {:pid, target: self()})

# Send to a named process
Bus.subscribe(:my_bus, "user.*", dispatch: {:pid, target: :user_handler})

# Async delivery to avoid blocking
Bus.subscribe(:my_bus, "user.*", dispatch: {:pid, target: self(), async: true})
```

**Options:**
- `target` - PID or registered process name (required)
- `async` - Send asynchronously (default: false)
- `timeout` - Delivery timeout in milliseconds (default: 5000)

### `:named` - Named Process Delivery

Sends signals to processes registered with specific names:

```elixir
# Send to locally registered process
Bus.subscribe(:my_bus, "user.*", dispatch: {:named, name: MyApp.UserHandler})

# Send to globally registered process
Bus.subscribe(:my_bus, "user.*", dispatch: {:named, name: {:global, :user_handler}})

# Send via Registry
Bus.subscribe(:my_bus, "user.*", dispatch: {:named, name: {:via, Registry, {MyApp.Registry, :handler}}})
```

**Options:**
- `name` - Process name specification (required)
- `async` - Send asynchronously (default: false)
- `timeout` - Delivery timeout (default: 5000)

### `:pubsub` - Phoenix.PubSub Integration

Distributes signals across clustered nodes using Phoenix.PubSub:

```elixir
# Broadcast to a topic
Bus.subscribe(:my_bus, "user.*", dispatch: {:pubsub, topic: "user_events"})

# Use custom PubSub instance
Bus.subscribe(:my_bus, "user.*", dispatch: {:pubsub, 
  pubsub: MyApp.PubSub, 
  topic: "critical_events"
})

# Local broadcast only
Bus.subscribe(:my_bus, "user.*", dispatch: {:pubsub, 
  topic: "local_events", 
  local?: true
})
```

**Options:**
- `topic` - PubSub topic name (required)
- `pubsub` - PubSub instance name (default: app's configured PubSub)
- `local?` - Broadcast only to local node (default: false)

### `:logger` - Structured Logging

Logs signals using Elixir's Logger:

```elixir
# Basic logging
Bus.subscribe(:my_bus, "error.**", dispatch: {:logger, level: :error})

# With custom formatting
Bus.subscribe(:my_bus, "user.*", dispatch: {:logger, 
  level: :info,
  format: "User event: $type from $source",
  metadata: [:user_id, :timestamp]
})
```

**Options:**
- `level` - Log level (`:debug`, `:info`, `:warn`, `:error`)
- `format` - Custom log format string
- `metadata` - Additional metadata fields to include

### `:console` - Console Output

Prints signals to stdout/stderr for development and debugging:

```elixir
# Simple console output
Bus.subscribe(:my_bus, "debug.**", dispatch: {:console})

# Formatted output
Bus.subscribe(:my_bus, "user.*", dispatch: {:console, 
  format: :pretty,
  colors: true
})

# Output to stderr
Bus.subscribe(:my_bus, "error.**", dispatch: {:console, 
  device: :stderr,
  format: :json
})
```

**Options:**
- `format` - Output format (`:json`, `:pretty`, `:compact`)
- `colors` - Enable colored output (default: true)
- `device` - Output device (`:stdio`, `:stderr`)

### `:noop` - No Operation

Discards signals (useful for testing and conditional routing):

```elixir
# Conditional dispatch based on environment
dispatch_config = if Mix.env() == :test do
  {:noop}
else
  {:logger, level: :info}
end

Bus.subscribe(:my_bus, "test.**", dispatch: dispatch_config)
```

### `:http` - HTTP Delivery

Sends signals as HTTP requests:

```elixir
# Basic HTTP POST
Bus.subscribe(:my_bus, "webhook.**", dispatch: {:http, 
  url: "https://api.example.com/events"
})

# With authentication and custom headers
Bus.subscribe(:my_bus, "critical.**", dispatch: {:http,
  url: "https://alerts.example.com/webhook",
  method: :post,
  headers: %{
    "Authorization" => "Bearer #{token}",
    "Content-Type" => "application/json",
    "X-Source" => "jido-signal"
  },
  timeout: 10_000
})
```

**Options:**
- `url` - Target URL (required)
- `method` - HTTP method (default: `:post`)
- `headers` - Custom headers map
- `timeout` - Request timeout in milliseconds (default: 5000)
- `retry_policy` - Retry configuration for failed requests

### `:webhook` - Webhook Delivery

Specialized HTTP delivery with webhook-specific features:

```elixir
# Webhook with signature verification
Bus.subscribe(:my_bus, "payment.**", dispatch: {:webhook,
  url: "https://merchant.example.com/webhook",
  secret: "webhook_secret_key",
  signature_header: "X-Signature"
})

# Multiple webhook endpoints
Bus.subscribe(:my_bus, "order.**", dispatch: {:webhook,
  urls: [
    "https://inventory.example.com/webhook",
    "https://analytics.example.com/webhook",
    "https://notifications.example.com/webhook"
  ],
  parallel: true
})
```

**Options:**
- `url` or `urls` - Webhook endpoint(s)
- `secret` - Secret for HMAC signature generation
- `signature_header` - Header name for signature (default: "X-Signature")
- `parallel` - Send to multiple URLs concurrently (default: false)

## Dispatching to Multiple Targets

Send signals to multiple destinations simultaneously:

```elixir
Bus.subscribe(:my_bus, "user.created", dispatch: [
  {:logger, level: :info},
  {:http, url: "https://crm.example.com/webhook"},
  {:pid, target: :email_service},
  {:pubsub, topic: "user_events"}
])
```

## Asynchronous and Batch Dispatching

### Asynchronous Dispatch

For non-blocking delivery:

```elixir
# Individual async dispatch
Dispatch.dispatch_async(signal, {:http, url: "https://slow-api.example.com"})

# Async subscription
Bus.subscribe(:my_bus, "analytics.**", dispatch: {:http, 
  url: "https://analytics.example.com", 
  async: true
})
```

### Batch Dispatch

For high-throughput scenarios:

```elixir
signals = [signal1, signal2, signal3]

# Batch dispatch to single target
Dispatch.dispatch_batch(signals, {:http, url: "https://api.example.com/batch"})

# Batch dispatch with different targets
dispatch_configs = [
  {:logger, level: :info},
  {:http, url: "https://api.example.com/webhook"}
]

Dispatch.dispatch_batch(signals, dispatch_configs)
```

## Error Handling and Retries

### Retry Policies

Configure automatic retries for failed deliveries:

```elixir
Bus.subscribe(:my_bus, "critical.**", dispatch: {:http,
  url: "https://critical-api.example.com/webhook",
  retry_policy: %{
    max_retries: 3,
    backoff: :exponential,
    base_delay: 1000,        # 1 second
    max_delay: 30_000,       # 30 seconds
    jitter: true
  }
})
```

### Dead Letter Handling

Route failed signals to alternative destinations:

```elixir
Bus.subscribe(:my_bus, "payment.**", dispatch: [
  # Primary delivery
  {:http, url: "https://payment-processor.example.com/webhook"},
  
  # Dead letter queue for failures
  {:logger, level: :error, on_failure: true},
  {:http, url: "https://dead-letter-queue.example.com", on_failure: true}
])
```

### Circuit Breaker Pattern

Protect against cascading failures:

```elixir
Bus.subscribe(:my_bus, "external.**", dispatch: {:http,
  url: "https://external-service.example.com",
  circuit_breaker: %{
    failure_threshold: 5,
    recovery_timeout: 60_000,
    half_open_max_calls: 3
  }
})
```

## Custom Dispatch Adapters

Create custom adapters for specialized delivery needs:

```elixir
defmodule MyApp.SlackAdapter do
  @behaviour Jido.Signal.Dispatch.Adapter
  
  @impl true
  def validate_opts(opts) do
    required = [:channel, :token]
    case NimbleOptions.validate(opts, required) do
      {:ok, validated} -> {:ok, validated}
      {:error, error} -> {:error, error}
    end
  end
  
  @impl true
  def deliver(signal, opts) do
    case post_to_slack(signal, opts) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end
  
  defp post_to_slack(signal, opts) do
    # Implementation details
  end
end
```

Use custom adapters:

```elixir
Bus.subscribe(:my_bus, "alerts.**", dispatch: {MyApp.SlackAdapter,
  channel: "#alerts",
  token: "slack-bot-token"
})
```

## Performance Optimization

### Connection Pooling

For HTTP-based adapters, use connection pooling:

```elixir
# Configure HTTP client with pooling
Bus.subscribe(:my_bus, "api.**", dispatch: {:http,
  url: "https://api.example.com/webhook",
  pool: :api_pool,
  pool_size: 10,
  pool_timeout: 5000
})
```

### Batching Strategies

Optimize for throughput with batching:

```elixir
# Time-based batching
Bus.subscribe(:my_bus, "metrics.**", dispatch: {:http,
  url: "https://metrics.example.com/batch",
  batch_size: 100,
  batch_timeout: 5000
})

# Size-based batching
Bus.subscribe(:my_bus, "logs.**", dispatch: {:http,
  url: "https://logs.example.com/bulk",
  batch_size: 1000,
  flush_interval: 10_000
})
```

## Monitoring and Observability

### Telemetry Integration

The dispatch system emits telemetry events for monitoring:

```elixir
:telemetry.attach("dispatch-metrics", [:jido_signal, :dispatch, :deliver], fn event, measurements, metadata, _config ->
  # Log delivery metrics
  Logger.info("Signal delivered", [
    adapter: metadata.adapter,
    duration: measurements.duration,
    success: metadata.success
  ])
end)
```

### Health Checks

Monitor adapter health:

```elixir
# Check adapter connectivity
{:ok, status} = Dispatch.health_check({:http, url: "https://api.example.com"})
# Returns: %{status: :healthy, latency: 45, last_success: ~U[...]}
```

The Dispatch System provides a flexible, robust foundation for integrating Jido.Signal with any external system or service, ensuring reliable signal delivery across your entire architecture.
