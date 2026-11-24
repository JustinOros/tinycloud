# Diagrams

## How it fits together

Nodes only connect out. Files are encrypted before they leave a node, so the gateway relays data it cannot read.

```mermaid
flowchart LR
    subgraph home1[Your home]
        A[Node A]
    end
    subgraph home2[A friend's home]
        B[Node B]
    end
    G[Gateway<br/>relay, discovery, approvals]
    D[Dashboard and Discord alerts]
    A <-->|outbound only| G
    B <-->|outbound only| G
    G --> D
```

## Joining

```mermaid
sequenceDiagram
    participant N as New node
    participant P as Person
    participant O as Owner
    participant G as Gateway
    N->>P: tinycloud join prints a line and a short code
    P->>O: sends the line
    O->>G: tinycloud-gw approve NAME DEVICEID ROLE OWNER
    G->>O: prints the code
    O-->>P: compare the codes
    G-->>N: node is approved
    N->>G: connects and starts syncing
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
