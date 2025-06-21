# Core Components at a Glance

Jido.Signal is built around five main components that work together to provide a complete event-driven architecture:

## Signal

The **Signal** is the universal message envelope that carries your data throughout the system. Every signal contains:

- Metadata (id, source, type, timestamp)
- Payload data
- Routing information
- Causality tracking

## Bus

The **Bus** serves as the central pub/sub hub for in-process communication. It:

- Manages subscriptions and routing
- Maintains a signal log for replay capabilities
- Handles persistent subscriptions
- Provides middleware integration points

## Router

The **Router** is an intelligent, trie-based engine that:

- Matches signals to handlers using path patterns
- Supports wildcards (`*` and `**`)
- Prioritizes handlers by specificity and priority
- Enables complex routing logic

## Dispatch

The **Dispatch** system is a pluggable architecture for sending signals to external destinations:

- Built-in adapters for HTTP, webhooks, PubSub, and more
- Asynchronous and batch processing capabilities
- Configurable retry and error handling
- Custom adapter support

## Journal

The **Journal** acts as a causality ledger that:

- Tracks relationships between signals
- Enables audit trails and debugging
- Supports complex workflow analysis
- Provides signal ancestry tracking

These components work together seamlessly to provide a robust foundation for event-driven applications.
