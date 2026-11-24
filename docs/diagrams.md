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
        B1[Node B]
        A1[Node A]
        G1[Gateway 1]
    end
    subgraph c2[Cloud 2]
        G2[Gateway 2]
        A2[Node A]
        B2[Node B]
    end
    B1 <--> G1
    A1 <--> G1
    G1 <-->|link code, read-only copies| G2
    G2 <--> A2
    G2 <--> B2
```

## When something fails

The gateway is the one single point of failure for syncing. More gateways are planned but not built yet.

```mermaid
flowchart LR
    F1[Gateway down] --> E1[Sync stops for everyone<br/>Nodes keep their files] --> R1[Rebuild it and restore the identity backup<br/>Heartbeat alert tells you]
    F2[A node down] --> E2[Other nodes keep their copies<br/>Nothing else is affected] --> R2[Discord alert after your wait time]
    F3[Linked cloud down] --> E3[Your cloud keeps working<br/>Their read-only copy stops updating] --> R3[Resumes when they are back]
```
