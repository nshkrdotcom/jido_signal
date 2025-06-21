# What is Jido.Signal?

Jido.Signal is a comprehensive toolkit for building event-driven and agent-based systems in Elixir. It provides a standardized approach to inter-service communication through a powerful signal-based architecture.

## Core Value Propositions

- **Standardized Signals**: Universal message envelopes that follow the CloudEvents specification
- **High-Performance Routing**: Intelligent, trie-based engine for matching signals to handlers
- **Pluggable Dispatch**: Flexible system for sending signals to various destinations
- **System Traceability**: Built-in causality tracking for understanding signal relationships

## Key Features

- **In-Process Pub/Sub**: Fast, reliable message passing within your application
- **External Integration**: Send signals to HTTP endpoints, webhooks, and other services
- **Persistent Subscriptions**: Ensure at-least-once delivery for critical events
- **Middleware Support**: Interceptor pattern for cross-cutting concerns
- **Journaling**: Track causality and audit trails across your system

## CloudEvents Compatibility

Jido.Signal aligns with the [CloudEvents specification](https://cloudevents.io/), ensuring your signals are portable and interoperable with other event-driven systems.
