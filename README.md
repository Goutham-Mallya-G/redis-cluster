# Redis Cluster Lifecycle Tool

A complete Ansible-driven CLI tool for managing a 6-node Redis cluster with zero-downtime rolling upgrades. This project fulfills all assignment requirements, including S4 (Idempotency) and S5 (Logging).

## Prerequisites
- Docker or Podman installed on your host machine.
- Python 3.x
- Ansible (`pip install ansible`)

## Quick Start Guide

### Step 0: Setup Environment
Before proceeding, run the setup script to configure correct file permissions for the CLI tool and SSH keys (especially important after cloning the repository):
```bash
./setup.sh
```

### Step 1: Bring Up the Infrastructure
The tool is designed to work seamlessly with either Docker or Podman. The network is configured statically on the `10.99.0.0/24` subnet.

Navigate to the `infra` directory and start the 6 container nodes:
```bash
cd infra
docker compose up -d --build
# OR, if using podman:
podman-compose up -d --build  
cd ..
```
*(Note: The containers will map SSH port 22 to host ports 2201-2206, though Ansible connects locally via `127.0.0.1` and uses the static container IPs `10.99.0.11` to `10.99.0.16` directly over the bridge network for internal commands.)*

### Step 2: Provision the Cluster (Phase 1)
The `redis-tool` acts as an orchestration wrapper around Ansible and direct TCP commands. It automatically detects your container runtime.

Run the following command to install Redis and form the cluster topology. It will automatically print the topology upon completion:
```bash
./redis-tool provision --version 7.0.15 --masters 3 --replicas-per-master 1
```

### Step 3: Seed and Verify Data (Phase 2)
Generate test data to ensure the cluster is accepting writes securely, and verify it can be read back. It will print the key distribution across the masters when finished.
```bash
./redis-tool data seed --keys 1000
./redis-tool data verify --keys 1000
```

### Step 4: Check Cluster Status (Phase 3)
Query the current state of the cluster, memory usage, and master/replica pairings:
```bash
./redis-tool status
```

### Step 5: Perform Zero-Downtime Rolling Upgrade (Phase 4)
Upgrade the cluster to a new Redis version without dropping any writes or losing data:
```bash
./redis-tool upgrade --target-version 7.2.6 --strategy rolling
```

**How the Rolling Upgrade Works:**
To ensure zero client-visible downtime and guaranteed data integrity, the tool implements the following sequence:
1. **Pre-flight Checks**: Verifies cluster health and pre-verifies the 1000 seeded keys.
2. **Upgrade Replicas First**: We iterate over the replicas sequentially. Upgrading replicas is entirely safe since they do not serve client writes. We stop Redis, replace the binary with the target version, and restart it. We wait for it to resync with its master.
3. **Upgrade Masters via Failover**: Once all replicas are upgraded, we cannot simply take down a master, or the cluster would experience a brief write outage. Instead, we:
   - Issue a `CLUSTER FAILOVER` command to the replica of the target master.
   - The cluster safely promotes the upgraded replica to be the new master, with zero data loss.
   - The old master gracefully downgrades to a replica state.
   - We safely upgrade the old master (which is now a replica).

### Step 6: Full Cluster Verification (Phase 5)
Perform a final, exhaustive check to ensure the upgrade was fully successful:
```bash
./redis-tool verify --full
```

### S4: Idempotency
The deployment and upgrade mechanisms are designed to be fully idempotent:
- **Idempotency**: The Ansible playbooks and python wrapper detect the current state of each node. If `provision` is run on an already provisioned cluster, it skips installation. If `upgrade` is interrupted, re-running it will skip nodes already at the target version, ensuring safe recovery without duplicate operations.

### S5: Logging
The tool is designed to be highly observable:
- **Logging**: All operations generate structured logs. Every action performed by `redis-tool` is logged to the `logs/` directory with timestamps, providing a clear audit trail of cluster events, failovers, and playbook executions.


---

## Advanced Features and Safeguards
The `redis-tool` implements several production-grade safeguards to ensure cluster stability:

- **Pre-Upgrade Data Verification**: Before initiating a rolling upgrade, the tool automatically validates the integrity of the seeded keys. This ensures the cluster is in a healthy, readable state before any nodes are restarted.
- **Semantic Version Downgrade Prevention**: Redis RDB and AOF files are not backwards compatible. Downgrading from 7.2 to 7.0 will cause nodes to crash on startup. The tool strictly parses semantic version strings and will fatally abort if a downgrade is attempted, protecting the cluster from corruption.
- **Per-Node Idempotency**: The upgrade playbook executes with node-level idempotency. If a cluster upgrade is interrupted, re-running the command will identify and skip nodes that are already at the target version.
- **Sudo-less Execution**: To maximize compatibility with minimal container images, the Ansible playbooks use `su` rather than `sudo` to drop privileges to the `redis` user.
- **Automated Topology Reporting**: Upon successful provisioning or data seeding, the tool immediately outputs the cluster topology, clearly defining master and replica associations.

---

## Project Structure
```text
submission/
├── redis-tool             (Python CLI entrypoint)
├── ansible/
│   ├── ansible.cfg        (Ansible configuration)
│   ├── inventory/
│   │   └── hosts.ini      (6 Redis nodes with static IPs)
│   ├── playbooks/
│   │   ├── provision.yml  (Installs Redis, creates cluster)
│   │   ├── status.yml     (Fetches node and cluster state)
│   │   └── upgrade_node.yml (Idempotent upgrade task for a single node)
│   └── roles/
│       └── redis/         (Core role: download, compile, config, systemd)
├── infra/
│   ├── Dockerfile         (Ubuntu 22.04 base image with SSH)
│   └── compose.yml        (Docker/Podman compose network)
├── logs/                  (Local runtime logs generated by the tool)
├── output/                (Command outputs and state verification files)
└── README.md
```

## Architecture & Limitations
- **SSH Auth**: The inventory strictly uses SSH key-based authentication (`id_rsa` generated in `infra/`) to securely connect without passwords, meeting the production requirements.
- **Python-driven Orchestration**: Instead of one monolithic Ansible playbook for the upgrade, `redis-tool` loops over the nodes in Python and calls a smaller `upgrade_node.yml` playbook. This makes orchestrating the complex failover logic vastly easier to read, test, and abort upon failure compared to Jinja/Ansible loop logic.
- **Data Operations**: `data seed` and `data verify` are executed via `ansible redis-node-1 -m shell` looping over `redis-cli`, meaning they are securely orchestrated to execute directly inside the cluster container to bypass any host-networking isolation issues in Podman.
- **Limitations**:
  - The script assumes `redis-cli` is accessible via `ansible localhost shell` if used locally, or it can be easily run natively inside the container.
  - The `redis-tool` makes hardcoded assumptions about the internal IP addresses (`10.99.0.11` to `10.99.0.16`), which is adequate for this specific 6-node static test but would need to parse `hosts.ini` dynamically in a production version.
