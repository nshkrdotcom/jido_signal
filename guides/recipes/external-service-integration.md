# Recipe: Secure External Service Integration

This guide demonstrates production-ready patterns for integrating Jido.Signal with external services using secure webhook delivery, proper authentication, and robust error handling.

## Core Security Concepts

### HMAC Signature Generation

Webhooks require cryptographic signatures to verify authenticity:

```elixir
defmodule MyApp.WebhookSecurity do
  @doc """
  Generate HMAC-SHA256 signature for webhook payload
  """
  def generate_signature(payload, secret) when is_binary(payload) and is_binary(secret) do
    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Verify incoming webhook signature
  """
  def verify_signature(payload, signature, secret) do
    expected = generate_signature(payload, secret)
    
    # Use secure comparison to prevent timing attacks
    case signature do
      "sha256=" <> received_signature ->
        secure_compare(expected, received_signature)
      _ ->
        false
    end
  end

  defp secure_compare(a, b) when byte_size(a) == byte_size(b) do
    a
    |> :binary.bin_to_list()
    |> Enum.zip(:binary.bin_to_list(b))
    |> Enum.reduce(0, fn {x, y}, acc -> acc ||| bxor(x, y) end)
    |> Kernel.==(0)
  end
  
  defp secure_compare(_, _), do: false
end
```

### Secret Management

Store webhook secrets securely using environment variables or secret managers:

```elixir
defmodule MyApp.Config do
  def webhook_secret(service) do
    case System.get_env("#{String.upcase(service)}_WEBHOOK_SECRET") do
      nil -> raise "Missing webhook secret for #{service}"
      secret -> secret
    end
  end

  def service_config(service) do
    %{
      url: System.get_env("#{String.upcase(service)}_WEBHOOK_URL"),
      secret: webhook_secret(service),
      timeout: String.to_integer(System.get_env("#{String.upcase(service)}_TIMEOUT", "10000"))
    }
  end
end
```

## Complete Integration Examples

### PagerDuty Alert Integration

Production-ready PagerDuty integration with incident management:

```elixir
defmodule MyApp.PagerDutyIntegration do
  alias Jido.Signal.Bus
  require Logger

  @pagerduty_events_url "https://events.pagerduty.com/v2/enqueue"

  def setup_alerting(bus_name \\ :main_bus) do
    config = MyApp.Config.service_config("pagerduty")
    
    # Subscribe to critical system events
    Bus.subscribe(bus_name, "alert.critical.**", 
      dispatch: {:webhook,
        url: @pagerduty_events_url,
        headers: %{
          "Authorization" => "Token token=#{config.secret}",
          "Content-Type" => "application/json"
        },
        transform: &transform_to_pagerduty_event/1,
        retry_policy: %{
          max_retries: 3,
          backoff: :exponential,
          base_delay: 2000,
          max_delay: 30_000
        },
        circuit_breaker: %{
          failure_threshold: 5,
          recovery_timeout: 300_000
        }
      }
    )

    # Subscribe to resolution events
    Bus.subscribe(bus_name, "alert.resolved.**",
      dispatch: {:webhook,
        url: @pagerduty_events_url,
        headers: %{
          "Authorization" => "Token token=#{config.secret}",
          "Content-Type" => "application/json"
        },
        transform: &transform_to_pagerduty_resolution/1
      }
    )
  end

  defp transform_to_pagerduty_event(signal) do
    %{
      routing_key: routing_key_for_service(signal.data.service),
      event_action: "trigger",
      dedup_key: signal.data.incident_id || generate_dedup_key(signal),
      payload: %{
        summary: signal.data.summary,
        severity: map_severity(signal.data.severity),
        source: signal.source,
        timestamp: signal.time,
        component: signal.data.component,
        group: signal.data.service,
        custom_details: signal.data
      },
      client: "jido-signal",
      client_url: "https://#{Application.get_env(:my_app, :host)}/incidents/#{signal.data.incident_id}"
    }
  end

  defp transform_to_pagerduty_resolution(signal) do
    %{
      routing_key: routing_key_for_service(signal.data.service),
      event_action: "resolve",
      dedup_key: signal.data.incident_id
    }
  end

  defp routing_key_for_service(service) do
    Application.get_env(:my_app, :pagerduty_routing_keys)[service] ||
      Application.get_env(:my_app, :pagerduty_default_routing_key)
  end

  defp map_severity(severity) do
    case severity do
      level when level in [:critical, :high] -> "critical"
      level when level in [:medium, :moderate] -> "error"
      level when level in [:low, :info] -> "warning"
      _ -> "info"
    end
  end

  defp generate_dedup_key(signal) do
    content = "#{signal.type}:#{signal.data.service}:#{signal.data.component}"
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
end
```

### Slack Notification System

Rich Slack notifications with proper formatting and rate limiting:

```elixir
defmodule MyApp.SlackIntegration do
  alias Jido.Signal.Bus
  require Logger

  def setup_notifications(bus_name \\ :main_bus) do
    config = MyApp.Config.service_config("slack")
    
    # Development/staging notifications
    Bus.subscribe(bus_name, "deploy.**",
      dispatch: {:webhook,
        url: config.url,
        transform: &transform_to_slack_deployment/1,
        rate_limit: %{
          requests: 50,
          window: 60_000  # 1 minute
        }
      }
    )

    # Error notifications with throttling
    Bus.subscribe(bus_name, "error.**",
      dispatch: {:webhook,
        url: config.url,
        transform: &transform_to_slack_error/1,
        throttle: %{
          key: &error_throttle_key/1,
          max_calls: 5,
          window: 300_000  # 5 minutes
        }
      }
    )

    # Business metrics
    Bus.subscribe(bus_name, "metrics.milestone.**",
      dispatch: {:webhook,
        url: config.url,
        transform: &transform_to_slack_milestone/1
      }
    )
  end

  defp transform_to_slack_deployment(signal) do
    %{
      channel: deployment_channel(signal.data.environment),
      username: "Deploy Bot",
      icon_emoji: deployment_emoji(signal.data.status),
      attachments: [
        %{
          color: deployment_color(signal.data.status),
          title: "Deployment #{signal.data.status}",
          fields: [
            %{
              title: "Environment",
              value: signal.data.environment,
              short: true
            },
            %{
              title: "Version",
              value: signal.data.version,
              short: true
            },
            %{
              title: "Duration",
              value: format_duration(signal.data.duration),
              short: true
            },
            %{
              title: "Deployed By",
              value: signal.data.deployed_by,
              short: true
            }
          ],
          footer: "Jido Signal",
          ts: DateTime.to_unix(signal.time)
        }
      ]
    }
  end

  defp transform_to_slack_error(signal) do
    %{
      channel: "#alerts",
      username: "Error Bot",
      icon_emoji: ":rotating_light:",
      attachments: [
        %{
          color: "danger",
          title: "Application Error",
          text: "```#{signal.data.error_message}```",
          fields: [
            %{
              title: "Service",
              value: signal.data.service,
              short: true
            },
            %{
              title: "Environment",
              value: signal.data.environment,
              short: true
            },
            %{
              title: "Error Count",
              value: "#{signal.data.count} occurrences",
              short: true
            },
            %{
              title: "First Seen",
              value: format_timestamp(signal.data.first_seen),
              short: true
            }
          ],
          actions: [
            %{
              type: "button",
              text: "View Logs",
              url: "https://logs.example.com/search?q=#{signal.data.trace_id}"
            },
            %{
              type: "button",
              text: "Create Issue",
              url: "https://github.com/myorg/myapp/issues/new"
            }
          ],
          footer: "Jido Signal",
          ts: DateTime.to_unix(signal.time)
        }
      ]
    }
  end

  defp transform_to_slack_milestone(signal) do
    %{
      channel: "#general",
      username: "Metrics Bot",
      icon_emoji: ":chart_with_upwards_trend:",
      text: "🎉 #{signal.data.milestone} achieved!",
      attachments: [
        %{
          color: "good",
          fields: [
            %{
              title: "Metric",
              value: signal.data.metric_name,
              short: true
            },
            %{
              title: "Value",
              value: format_number(signal.data.value),
              short: true
            }
          ],
          footer: "Jido Signal",
          ts: DateTime.to_unix(signal.time)
        }
      ]
    }
  end

  defp error_throttle_key(signal) do
    "#{signal.data.service}:#{signal.data.error_type}"
  end

  defp deployment_channel("production"), do: "#production"
  defp deployment_channel("staging"), do: "#staging"
  defp deployment_channel(_), do: "#development"

  defp deployment_emoji("success"), do: ":white_check_mark:"
  defp deployment_emoji("failed"), do: ":x:"
  defp deployment_emoji("started"), do: ":rocket:"
  defp deployment_emoji(_), do: ":information_source:"

  defp deployment_color("success"), do: "good"
  defp deployment_color("failed"), do: "danger"
  defp deployment_color(_), do: "warning"

  defp format_duration(ms) when is_integer(ms) do
    seconds = div(ms, 1000)
    minutes = div(seconds, 60)
    remaining_seconds = rem(seconds, 60)
    
    cond do
      minutes > 0 -> "#{minutes}m #{remaining_seconds}s"
      seconds > 0 -> "#{seconds}s"
      true -> "#{ms}ms"
    end
  end

  defp format_timestamp(datetime) do
    datetime
    |> DateTime.to_unix()
    |> then(&"<!date^#{&1}^{date_short_pretty} at {time}|#{datetime}>")
  end

  defp format_number(number) when is_integer(number) do
    number
    |> Integer.to_string()
    |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")
  end
end
```

### Secure Payment Webhook Processing

Handle payment webhooks with proper signature verification and idempotency:

```elixir
defmodule MyApp.PaymentWebhookProcessor do
  alias Jido.Signal.Bus
  require Logger

  def setup_payment_processing(bus_name \\ :main_bus) do
    stripe_config = MyApp.Config.service_config("stripe")
    paypal_config = MyApp.Config.service_config("paypal")

    # Stripe webhooks
    Bus.subscribe(bus_name, "payment.stripe.**",
      dispatch: [
        # Primary processing
        {:webhook,
          url: stripe_config.url,
          secret: stripe_config.secret,
          signature_header: "Stripe-Signature",
          verify_signature: &verify_stripe_signature/3,
          transform: &transform_stripe_webhook/1,
          idempotency_key: &stripe_idempotency_key/1
        },
        # Audit logging
        {:logger, level: :info, format: "Payment webhook processed: $type"}
      ]
    )

    # PayPal webhooks
    Bus.subscribe(bus_name, "payment.paypal.**",
      dispatch: {:webhook,
        url: paypal_config.url,
        verify_signature: &verify_paypal_signature/3,
        transform: &transform_paypal_webhook/1
      }
    )
  end

  defp verify_stripe_signature(payload, signature, webhook_secret) do
    case String.split(signature, ",") do
      [timestamp_part, signature_part] ->
        with ["t", timestamp] <- String.split(timestamp_part, "="),
             ["v1", received_signature] <- String.split(signature_part, "=") do
          
          # Check timestamp to prevent replay attacks
          current_time = System.system_time(:second)
          webhook_time = String.to_integer(timestamp)
          
          if current_time - webhook_time > 300 do  # 5 minute tolerance
            false
          else
            signed_payload = "#{timestamp}.#{payload}"
            expected_signature = MyApp.WebhookSecurity.generate_signature(signed_payload, webhook_secret)
            MyApp.WebhookSecurity.secure_compare(expected_signature, received_signature)
          end
        else
          _ -> false
        end
      _ -> false
    end
  end

  defp verify_paypal_signature(payload, signature, webhook_secret) do
    # PayPal uses different signature format
    expected = MyApp.WebhookSecurity.generate_signature(payload, webhook_secret)
    MyApp.WebhookSecurity.secure_compare(expected, signature)
  end

  defp transform_stripe_webhook(signal) do
    %{
      event_type: signal.data.type,
      event_id: signal.data.id,
      object: signal.data.data.object,
      created: signal.data.created,
      api_version: signal.data.api_version,
      livemode: signal.data.livemode,
      metadata: %{
        source: "stripe",
        signal_id: signal.id,
        processed_at: DateTime.utc_now()
      }
    }
  end

  defp transform_paypal_webhook(signal) do
    %{
      event_type: signal.data.event_type,
      event_id: signal.data.id,
      resource: signal.data.resource,
      create_time: signal.data.create_time,
      metadata: %{
        source: "paypal",
        signal_id: signal.id,
        processed_at: DateTime.utc_now()
      }
    }
  end

  defp stripe_idempotency_key(signal) do
    # Use Stripe event ID as idempotency key
    signal.data.id
  end
end

# Webhook receiver for processing external webhooks
defmodule MyApp.WebhookController do
  use Phoenix.Controller
  alias Jido.Signal.Bus
  require Logger

  def stripe_webhook(conn, params) do
    with {:ok, payload} <- read_body(conn),
         signature <- get_req_header(conn, "stripe-signature") |> List.first(),
         webhook_secret <- MyApp.Config.webhook_secret("stripe"),
         true <- MyApp.PaymentWebhookProcessor.verify_stripe_signature(payload, signature, webhook_secret) do
      
      signal = Jido.Signal.new(%{
        type: "payment.stripe.#{params["type"]}",
        source: "stripe_webhook",
        data: params,
        metadata: %{
          remote_ip: get_peer_data(conn).address |> :inet.ntoa() |> to_string(),
          user_agent: get_req_header(conn, "user-agent") |> List.first()
        }
      })

      Bus.publish(:main_bus, signal)
      
      json(conn, %{received: true})
    else
      false ->
        Logger.warning("Invalid Stripe webhook signature", webhook_ip: get_peer_data(conn).address)
        send_resp(conn, 400, "Invalid signature")
      {:error, reason} ->
        Logger.error("Failed to process Stripe webhook", error: reason)
        send_resp(conn, 500, "Processing failed")
    end
  end

  defp read_body(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, _conn} -> {:ok, body}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

## Advanced Error Handling and Resilience

### Circuit Breaker Implementation

Protect against service failures with intelligent circuit breaking:

```elixir
defmodule MyApp.CircuitBreakerConfig do
  def external_service_config do
    %{
      # Open circuit after 5 failures in 60 seconds
      failure_threshold: 5,
      failure_window: 60_000,
      
      # Stay open for 5 minutes before trying again
      recovery_timeout: 300_000,
      
      # Allow 3 test requests in half-open state
      half_open_max_calls: 3,
      
      # Consider these as failures
      failure_conditions: [
        {:status_code, 500..599},
        {:timeout, :any},
        {:connection_error, :any}
      ]
    }
  end
end

# Usage in webhook configuration
Bus.subscribe(:main_bus, "external.**",
  dispatch: {:webhook,
    url: "https://unreliable-service.example.com",
    circuit_breaker: MyApp.CircuitBreakerConfig.external_service_config(),
    fallback: {:logger, level: :error, message: "Service unavailable, logged instead"}
  }
)
```

### Comprehensive Retry Strategies

Different retry patterns for different failure types:

```elixir
defmodule MyApp.RetryStrategies do
  def critical_payment_retry do
    %{
      max_retries: 5,
      backoff: :exponential,
      base_delay: 1000,
      max_delay: 60_000,
      jitter: true,
      retry_conditions: [
        {:status_code, [500, 502, 503, 504]},
        {:timeout, :any},
        {:connection_error, [:econnrefused, :timeout]}
      ],
      dead_letter_queue: "payment_failures"
    }
  end

  def analytics_retry do
    %{
      max_retries: 2,
      backoff: :linear,
      base_delay: 5000,
      retry_conditions: [
        {:status_code, 500..599}
      ],
      give_up_after: 300_000  # 5 minutes total
    }
  end

  def notification_retry do
    %{
      max_retries: 3,
      backoff: :exponential,
      base_delay: 2000,
      max_delay: 30_000,
      retry_conditions: [
        {:status_code, [429, 500, 502, 503]}
      ]
    }
  end
end
```

## Rate Limiting and Traffic Management

### Token Bucket Rate Limiting

Implement sophisticated rate limiting for external services:

```elixir
defmodule MyApp.RateLimiter do
  use GenServer
  require Logger

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  def check_rate_limit(service, requests \\ 1) do
    GenServer.call(__MODULE__, {:check_limit, service, requests})
  end

  def init(config) do
    # Initialize token buckets for each service
    buckets = Map.new(config, fn {service, limits} ->
      {service, %{
        tokens: limits.max_requests,
        max_tokens: limits.max_requests,
        refill_rate: limits.refill_rate,
        last_refill: System.monotonic_time(:millisecond)
      }}
    end)

    # Schedule periodic refill
    :timer.send_interval(1000, :refill_tokens)

    {:ok, buckets}
  end

  def handle_call({:check_limit, service, requests}, _from, buckets) do
    case Map.get(buckets, service) do
      nil ->
        {:reply, {:error, :unknown_service}, buckets}
      
      bucket ->
        if bucket.tokens >= requests do
          updated_bucket = %{bucket | tokens: bucket.tokens - requests}
          updated_buckets = Map.put(buckets, service, updated_bucket)
          {:reply, :ok, updated_buckets}
        else
          {:reply, {:error, :rate_limited}, buckets}
        end
    end
  end

  def handle_info(:refill_tokens, buckets) do
    now = System.monotonic_time(:millisecond)
    
    updated_buckets = Map.new(buckets, fn {service, bucket} ->
      time_passed = now - bucket.last_refill
      tokens_to_add = div(time_passed * bucket.refill_rate, 1000)
      
      new_tokens = min(bucket.tokens + tokens_to_add, bucket.max_tokens)
      
      {service, %{bucket | 
        tokens: new_tokens, 
        last_refill: now
      }}
    end)

    {:noreply, updated_buckets}
  end
end

# Configuration for different services
rate_limit_config = %{
  slack: %{max_requests: 50, refill_rate: 1},      # 50 requests, 1 per second refill
  pagerduty: %{max_requests: 100, refill_rate: 2}, # 100 requests, 2 per second refill
  stripe: %{max_requests: 1000, refill_rate: 10}   # 1000 requests, 10 per second refill
}

# Start rate limiter
{:ok, _} = MyApp.RateLimiter.start_link(rate_limit_config)

# Use in webhook dispatch
Bus.subscribe(:main_bus, "notification.**",
  dispatch: {:webhook,
    url: "https://api.slack.com/webhook",
    pre_dispatch: fn signal, opts ->
      case MyApp.RateLimiter.check_rate_limit(:slack) do
        :ok -> {:ok, signal, opts}
        {:error, :rate_limited} -> 
          {:delay, 1000}  # Delay and retry
      end
    end
  }
)
```

## Monitoring and Health Checks

### Service Health Monitoring

Continuously monitor external service health:

```elixir
defmodule MyApp.ServiceHealthMonitor do
  use GenServer
  alias Jido.Signal.Bus
  require Logger

  @health_check_interval 30_000  # 30 seconds
  @services_to_monitor [
    %{name: :slack, url: "https://slack.com/api/api.test"},
    %{name: :pagerduty, url: "https://api.pagerduty.com/abilities"},
    %{name: :stripe, url: "https://api.stripe.com/v1/charges?limit=1"}
  ]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def init(state) do
    schedule_health_checks()
    {:ok, state}
  end

  def handle_info(:health_check, state) do
    Enum.each(@services_to_monitor, &check_service_health/1)
    schedule_health_checks()
    {:noreply, state}
  end

  defp schedule_health_checks do
    Process.send_after(self(), :health_check, @health_check_interval)
  end

  defp check_service_health(service) do
    start_time = System.monotonic_time(:millisecond)
    
    case HTTPoison.get(service.url, [], [timeout: 10_000, recv_timeout: 10_000]) do
      {:ok, %{status_code: status}} when status in 200..299 ->
        latency = System.monotonic_time(:millisecond) - start_time
        publish_health_signal(service.name, :healthy, %{latency: latency})
        
      {:ok, %{status_code: status}} ->
        publish_health_signal(service.name, :degraded, %{status_code: status})
        
      {:error, reason} ->
        publish_health_signal(service.name, :unhealthy, %{error: reason})
    end
  end

  defp publish_health_signal(service, status, metadata) do
    signal = Jido.Signal.new(%{
      type: "health.service.#{status}",
      source: "health_monitor",
      data: Map.merge(%{service: service, status: status}, metadata)
    })

    Bus.publish(:main_bus, signal)
  end
end

# Start health monitor
{:ok, _} = MyApp.ServiceHealthMonitor.start_link([])

# React to health changes
Bus.subscribe(:main_bus, "health.service.unhealthy",
  dispatch: [
    {:logger, level: :error},
    {:webhook, 
      url: "https://hooks.slack.com/alerts",
      transform: fn signal ->
        %{
          text: "🚨 Service #{signal.data.service} is unhealthy: #{inspect(signal.data.error)}"
        }
      end
    }
  ]
)
```

## Testing Webhook Integrations

### Comprehensive Test Suite

Test webhook integrations thoroughly:

```elixir
defmodule MyApp.WebhookIntegrationTest do
  use ExUnit.Case, async: false
  import Mock
  alias Jido.Signal.Bus

  setup do
    # Start test bus
    {:ok, bus_pid} = Bus.start_link(name: :test_bus)
    
    # Mock HTTP client
    HTTPoison.start()
    
    on_exit(fn ->
      GenServer.stop(bus_pid)
    end)
    
    %{bus: :test_bus}
  end

  test "stripe webhook signature verification", %{bus: bus} do
    payload = ~s({"id":"evt_test","type":"payment_intent.succeeded"})
    timestamp = System.system_time(:second)
    secret = "whsec_test_secret"
    
    # Generate valid signature
    signed_payload = "#{timestamp}.#{payload}"
    signature = :crypto.mac(:hmac, :sha256, secret, signed_payload) |> Base.encode16(case: :lower)
    full_signature = "t=#{timestamp},v1=#{signature}"
    
    assert MyApp.PaymentWebhookProcessor.verify_stripe_signature(payload, full_signature, secret)
  end

  test "webhook delivery with retry on failure", %{bus: bus} do
    # Mock HTTP client to fail first two attempts, succeed on third
    with_mock HTTPoison, [
      post: fn _url, _body, _headers, _opts ->
        case Process.get(:attempt_count, 0) do
          count when count < 2 ->
            Process.put(:attempt_count, count + 1)
            {:error, :timeout}
          _ ->
            Process.put(:attempt_count, 0)
            {:ok, %HTTPoison.Response{status_code: 200, body: ~s({"success": true})}}
        end
      end
    ] do
      # Setup webhook with retry policy
      Bus.subscribe(bus, "test.**",
        dispatch: {:webhook,
          url: "https://api.example.com/webhook",
          retry_policy: %{
            max_retries: 3,
            backoff: :exponential,
            base_delay: 100
          }
        }
      )

      # Publish test signal
      signal = Jido.Signal.new(%{
        type: "test.webhook",
        source: "test",
        data: %{message: "test payload"}
      })

      Bus.publish(bus, signal)

      # Wait for retries to complete
      Process.sleep(1000)

      # Verify final success
      assert called(HTTPoison.post(:_, :_, :_, :_))
    end
  end

  test "rate limiting prevents excessive requests", %{bus: bus} do
    # Configure strict rate limiting
    Bus.subscribe(bus, "rate_limit_test.**",
      dispatch: {:webhook,
        url: "https://api.example.com/webhook",
        rate_limit: %{
          requests: 2,
          window: 1000  # 2 requests per second
        }
      }
    )

    # Send 5 signals quickly
    signals = for i <- 1..5 do
      Jido.Signal.new(%{
        type: "rate_limit_test.signal",
        source: "test",
        data: %{id: i}
      })
    end

    with_mock HTTPoison, [
      post: fn _url, _body, _headers, _opts ->
        {:ok, %HTTPoison.Response{status_code: 200}}
      end
    ] do
      Enum.each(signals, &Bus.publish(bus, &1))
      Process.sleep(100)

      # Should only see 2 HTTP calls due to rate limiting
      assert called(HTTPoison.post(:_, :_, :_, :_)) |> length() <= 2
    end
  end

  test "circuit breaker opens on repeated failures" do
    # Test circuit breaker behavior
    with_mock HTTPoison, [
      post: fn _url, _body, _headers, _opts ->
        {:error, :econnrefused}
      end
    ] do
      # Configure circuit breaker
      dispatch_config = {:webhook,
        url: "https://failing-service.example.com",
        circuit_breaker: %{
          failure_threshold: 3,
          recovery_timeout: 60_000
        }
      }

      # Send multiple failing requests
      for i <- 1..5 do
        signal = Jido.Signal.new(%{
          type: "test.circuit_breaker",
          source: "test",
          data: %{attempt: i}
        })
        
        Jido.Signal.Dispatch.dispatch(signal, dispatch_config)
        Process.sleep(10)
      end

      # Circuit should be open after 3 failures
      # Further requests should be rejected without HTTP calls
      assert called(HTTPoison.post(:_, :_, :_, :_)) |> length() == 3
    end
  end
end
```

## Security Best Practices Summary

1. **Always verify webhook signatures** using secure comparison functions
2. **Store secrets in environment variables** or dedicated secret managers
3. **Implement timestamp validation** to prevent replay attacks
4. **Use HTTPS everywhere** for webhook endpoints
5. **Rate limit incoming webhooks** to prevent DoS attacks  
6. **Log security events** for monitoring and incident response
7. **Validate all incoming payloads** against expected schemas
8. **Implement idempotency** to handle duplicate webhooks safely
9. **Use circuit breakers** to protect against cascading failures
10. **Monitor external service health** proactively

This comprehensive guide provides production-ready patterns for secure external service integration using Jido.Signal, ensuring robust, scalable, and secure webhook processing in your applications.
