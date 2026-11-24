# Diagrams

## How it fits together

Nodes only connect out. Files are encrypted before they leave a node, so the gateway relays data it cannot read.

```mermaid
flowchart LR
    subgraph home2[A friend's home]
        B[Node B]
    end
    subgraph home1[Your home]
        A[Node A]
    end
    G[Gateway<br/>relay, discovery, approvals]
    D[Dashboard and Discord alerts]
    B <-->|outbound only| G
    A <-->|outbound only| G
    G --> D
```

## Joining

```mermaid
sequenceDiagram
    participant N as New node
    participant O as Owner
    participant G as Gateway
    N->>O: join line and short code
    O->>G: tinycloud-gw approve (codes must match)
    G->>N: approved, syncing starts
```

## Two clouds linked

Each person manages only their own gateway, nodes and data. A link gives each side a read-only copy of what the other offers.

```mermaid
flowchart LR
    subgraph c1[Cloud 1]
        direction TB
        G1[Gateway 1]
        N1[Nodes]
        G1 --- N1
    end
    subgraph c2[Cloud 2]
        direction TB
        G2[Gateway 2]
        N2[Nodes]
        G2 --- N2
    end
    G1 <-->|link code, read-only copies| G2
```
