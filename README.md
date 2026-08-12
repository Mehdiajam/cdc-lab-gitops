# Local CDC Pipeline with Kafka, Debezium \& Argo CD

**Author:** Mehdi Ajam
**Project:** Cloud DevOps Internship — Local CDC Pipeline
**Repo:** [Mehdiajam/cdc-lab-gitops](https://github.com/Mehdiajam/cdc-lab-gitops)
**Environment:** Windows 11 + WSL2 (Ubuntu) + Docker Desktop + kind

\---

## 1\. Overview

This project implements a local **Change Data Capture (CDC)** pipeline that:

1. Watches a MySQL database (a real production-like DB — `PharmacieDB`, hosted natively on Windows) for row-level changes (inserts, updates, deletes)
2. Streams those changes in real time into **Apache Kafka** via **Debezium**
3. Runs entirely on a local **Kubernetes** cluster (via `kind`)
4. Is deployed and kept in sync using **Argo CD** (GitOps) — the entire cluster state is defined in Git and auto-applied/auto-healed by Argo CD

### Architecture

```
┌─────────────────────────────┐
│  Windows Host                │
│  MySQL (PharmacieDB)    │  wal\_level = logical
│  listen\_addresses = '\*'      │
└───────────────┬───────────────┘
                │ host.docker.internal:5432
                ▼
┌───────────────────────────────────────────────────┐
│  kind Kubernetes cluster (WSL2 / Docker Desktop)   │
│                                                     │
│  ┌───────────────┐   ┌────────────────────────┐   │
│  │ Strimzi        │   │ Argo CD                 │   │
│  │ Operator       │   │ (GitOps controller)     │   │
│  └───────────────┘   └───────────┬──────────────┘   │
│                                   │ watches Git repo │
│  ┌────────────┐  ┌─────────────┐ │  ┌─────────────┐ │
│  │ Kafka       │   MySQL    │◄┘  │ Kafka       │ │
│  │ (KRaft mode)│  │ (test DB)   │    │ Connect +   │ │
│  │             │  │             │    │ Debezium    │ │
│  └─────────────┘  └─────────────┘    └──────┬──────┘ │
│                                              │        │
└──────────────────────────────────────────────┼────────┘
                                                │
                                    Debezium connector polls
                                    PharmacieDB via WAL / logical
                                    replication → publishes to
                                    Kafka topics (winpg.public.\*)
```

\---

## 2\. Prerequisites \& Initial Environment Setup

### 2.1 Install WSL2 (Windows)

Run in **PowerShell as Administrator**:

```powershell
wsl --install
```

Installs WSL2 + Ubuntu by default. Restart when prompted, then set a username/password on first Ubuntu launch.

Check/force WSL2 (not WSL1):

```powershell
wsl --set-default-version 2
wsl -l -v
```

If Ubuntu isn't listed, install it explicitly:

```powershell
wsl --install -d Ubuntu
```

Launch a specific distro by name (avoids accidentally landing in Docker's internal WSL VM):

```powershell
wsl -d Ubuntu
```

> \*\*Lesson learned:\*\* running the bare `wsl` command can sometimes drop you into Docker Desktop's internal `docker-desktop` VM instead of your actual Ubuntu distro. Always verify with `whoami` and `pwd` — you want your own username, not `root`, and a path like `/home/yourname` or `/mnt/c/...`, not `/mnt/host/...`.

### 2.2 Install Docker Desktop

Install Docker Desktop for Windows normally, then enable WSL integration:

**Docker Desktop → Settings → Resources → WSL Integration** → toggle on your Ubuntu distro → **Apply \& Restart**

Verify from inside Ubuntu:

```bash
docker --version
docker run hello-world
```

### 2.3 Fix Docker permission errors

If you see `permission denied while trying to connect to the docker API`:

```bash
sudo usermod -aG docker $USER
```

Then fully restart your WSL session (group changes require this):

```powershell
wsl --shutdown
```

Reopen Ubuntu, then verify:

```bash
groups
docker run hello-world
```

### 2.4 Install kubectl

```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
kubectl version --client
```

### 2.5 Install kind (Kubernetes IN Docker)

```bash
\[ $(uname -m) = x86\_64 ] \&\& curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-amd64
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind
kind version
```

\---

## 3\. Creating the Local Kubernetes Cluster

```bash
cd \~
mkdir cdc-lab \&\& cd cdc-lab
kind create cluster --name cdc-lab
```

Verify:

```bash
kubectl cluster-info --context kind-cdc-lab
kubectl get nodes
```

> \*\*Note:\*\* `kind` runs your Kubernetes "nodes" as Docker containers. If you ever see `docker ps -a | grep cdc-lab` return nothing, the cluster container was deleted and everything inside it (all pods, all data) is gone — you'd need to recreate the cluster from scratch. This happened once during this project (see §9, Disaster Recovery).

\---

## 4\. Installing Argo CD

### 4.1 Install

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Wait for all pods to be ready:

```bash
kubectl get pods -n argocd -w
```

### 4.2 Access the UI

Port-forward the Argo CD server (run in the background with `\&` so the terminal stays usable):

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443 \&
```

Get the initial admin password (regenerated every time the cluster is rebuilt):

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo
```

Open `https://localhost:8080` in a browser, accept the self-signed cert warning, log in as `admin` with the password above.

> \*\*Troubleshooting — `ERR\_SSL\_PROTOCOL\_ERROR`:\*\* if the browser can't establish an HTTPS connection even though `curl -k https://localhost:8080` works fine, it's a browser-side issue (stale HSTS cache, duplicate port-forward processes, etc.), not a server problem. Fixes that worked: killing all `port-forward` processes and starting exactly one (`pkill -f "port-forward"`), using `127.0.0.1` instead of `localhost`, or switching to a different local port (e.g. `9443:443`).

### 4.3 Install the Argo CD CLI (optional but useful)

```bash
curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
rm argocd-linux-amd64
argocd login localhost:8080 --username admin --password <password> --insecure
```

\---

## 5\. Deploying Kafka (via Strimzi)

We use **Strimzi**, the standard Kubernetes operator for running Kafka, in **KRaft mode** (no ZooKeeper — Kafka's newer built-in consensus mechanism).

### 5.1 Install the Strimzi operator

```bash
kubectl create namespace kafka
kubectl apply -f https://strimzi.io/install/latest?namespace=kafka -n kafka
kubectl get pods -n kafka -w
```

Wait for `strimzi-cluster-operator-xxxx` to show `1/1 Running`.

> \*\*Troubleshooting — stale kubectl API cache:\*\* if `kubectl apply` on a `Kafka` resource fails with `no matches for kind "Kafka"` even though the CRD exists (`kubectl get crd | grep strimzi` shows it), clear kubectl's local cache: `rm -rf \~/.kube/cache`.

### 5.2 Kafka cluster manifest (KRaft mode)

`kafka/kafka-cluster.yaml`:

```yaml
apiVersion: kafka.strimzi.io/v1
kind: KafkaNodePool
metadata:
  name: dual-role
  namespace: kafka
  labels:
    strimzi.io/cluster: cdc-kafka
spec:
  replicas: 1
  roles:
    - controller
    - broker
  storage:
    type: ephemeral
---
apiVersion: kafka.strimzi.io/v1
kind: Kafka
metadata:
  name: cdc-kafka
  namespace: kafka
  annotations:
    strimzi.io/node-pools: enabled
    strimzi.io/kraft: enabled
spec:
  kafka:
    version: 4.2.0
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: tls
        port: 9093
        type: internal
        tls: true
    config:
      offsets.topic.replication.factor: 1
      transaction.state.log.replication.factor: 1
      transaction.state.log.min.isr: 1
      default.replication.factor: 1
      min.insync.replicas: 1
  entityOperator:
    topicOperator: {}
    userOperator: {}
```

Apply:

```bash
kubectl apply -f kafka/kafka-cluster.yaml
kubectl get pods -n kafka -w
```

**Key design notes:**

* `KafkaNodePool` defines the actual broker/controller node(s) — this replaced the older `spec.kafka.replicas` / `spec.zookeeper` fields once ZooKeeper was dropped from newer Strimzi versions.
* `roles: \[controller, broker]` combines both roles onto a single node — fine for local testing, not for production.
* `storage: type: ephemeral` means data is lost if the pod restarts — acceptable for a local lab, never for production.
* All replication factors are `1` because this is a single-broker cluster.

> \*\*Troubleshooting — API version mismatches:\*\* the Strimzi operator version installed determines which `apiVersion` (`v1beta2` vs `v1`) and which Kafka versions are supported. Check what's actually installed before writing manifests:
> ```bash
> kubectl get crd kafkas.kafka.strimzi.io -o jsonpath='{.spec.versions\[\*].name}'
> ```
> This project hit `Unsupported Kafka.spec.kafka.version: 3.7.0. Supported versions are: \[4.2.0, 4.2.1, 4.3.0]` — always check supported versions rather than assuming.

\---

## 6\. Deploying MySQL (in-cluster test database)

This is a throwaw MySQL instance inside the cluster, used only to validate the CDC pipeline mechanics before pointing it at the real Windows database.

### 6.1 Create credentials as a Kubernetes Secret (not hardcoded in YAML)

```bash
kubectl create secret generic mysql-credentials \\
  --namespace=kafka \\
  --from-literal=MYSQL\_USER=dbuser \\
  --from-literal=MYSQL\_PASSWORD=dbpassword \\
  --from-literal=MySQL=inventory
```

### 6.2 mysql manifest

`mysql/mysql.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysql
  namespace: kafka
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
        - name: mysql
          image: debezium/mysql:15
          env:
            - name: mysql\_USER
              valueFrom:
                secretKeyRef:
                  name: mysql-credentials
                  key: mysql\_USER
            - name: mysql\_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mysql-credentials
                  key: mysql\_PASSWORD
            - name: mysql\_DB
              valueFrom:
                secretKeyRef:
                  name: mysql-credentials
                  key: mysql\_DB
          ports:
            - containerPort: 5432
          args:
            - "-c"
            - "wal\_level=logical"
---
apiVersion: v1
kind: Service
metadata:
  name: mysql
  namespace: kafka
spec:
  selector:
    app: mysql
  ports:
    - port: 5432
      targetPort: 5432
```

**Key design notes:**

* Uses the `debezium/mysql:15` image — a plain mysql image pre-configured with CDC-friendly defaults.
* `wal\_level=logical` is passed as a startup arg — this is the critical setting that allows Debezium to read the write-ahead log for row-level change capture.
* Credentials come from the Secret via `valueFrom.secretKeyRef` rather than being hardcoded — better practice, even for a local test.

Apply:

```bash
kubectl apply -f mysql/mysql.yaml
```

> \*\*Troubleshooting — YAML tab characters:\*\* editing YAML by hand (or via copy-paste from some tools) can silently introduce tab characters, which YAML forbids. This caused a cryptic `error converting YAML to JSON: yaml: line 20: found character that cannot start any token`. Check for tabs before applying any manifest:
> ```bash
> cat -A path/to/file.yaml | grep '\\^I'
> ```
> Should return nothing. If it finds matches, recreate the file cleanly with a heredoc rather than trying to manually fix indentation.

\---

## 7\. Deploying Kafka Connect + Debezium

This was the most complex part of the setup — several approaches were attempted before landing on the one that works reliably.

### 7.1 What we tried first (and why it failed): Strimzi's build-from-source mechanism

Strimzi supports building a custom Kafka Connect image (base image + Debezium plugin tarball) and pushing it to a container registry. We set up a local Docker registry connected to the kind cluster network for this:

```bash
# Create a local registry container
docker run -d --restart=always -p 5000:5000 --name kind-registry registry:2

# Connect it to kind's docker network
docker network connect kind kind-registry

# Register it with the cluster (informational, for tooling awareness)
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:5000"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

# Patch containerd on the kind node to resolve localhost:5000 to the registry container
REGISTRY\_DIR="/etc/containerd/certs.d/localhost:5000"
docker exec cdc-lab-control-plane mkdir -p "${REGISTRY\_DIR}"
cat <<EOF | docker exec -i cdc-lab-control-plane cp /dev/stdin "${REGISTRY\_DIR}/hosts.toml"
\[host."http://kind-registry:5000"]
EOF
```

This approach ultimately **failed for two compounding reasons**:

1. **Pods can't reach `localhost:5000`** — inside a build pod, `localhost` refers to the pod itself, not the host registry. Fix attempted: exposed the registry as a proper Kubernetes Service/Endpoints pointing at the registry container's actual Docker network IP.
2. **HTTPS vs HTTP mismatch** — Strimzi's build tool (Buildah) defaults to HTTPS when pushing to any registry; our local registry only serves plain HTTP. Error: `http: server gave HTTP response to HTTPS client`. This is fixable via a mounted `registries.conf` marking the registry as insecure, but by this point the approach had accumulated enough fragility (registry networking, TLS config, multiple manifest field-name changes across Strimzi versions) that we abandoned it in favor of a simpler approach.

> \*\*Lesson:\*\* for local/learning environments, Strimzi's build-and-push mechanism adds real operational complexity (you need a working local registry, correct network routing from pods to that registry, and correct TLS/insecure-registry configuration). It's worth understanding conceptually, but not worth fighting for a local CDC proof-of-concept.

### 7.2 What we tried second (and why it also failed): pre-built Debezium image via Strimzi's `KafkaConnect` CRD

```yaml
apiVersion: kafka.strimzi.io/v1
kind: KafkaConnect
metadata:
  name: cdc-connect
  namespace: kafka
spec:
  version: 4.2.0
  image: quay.io/debezium/connect:2.5   # <- pre-built image instead of build:
  bootstrapServers: cdc-kafka-kafka-bootstrap:9092
  # ...
```

This **also failed**, with a different error:

```
/docker-entrypoint.sh: line 330: /opt/kafka/kafka\_connect\_run.sh: No such file or directory
```

**Root cause:** Strimzi's `KafkaConnect` CRD expects the container image to contain Strimzi's own launcher scripts (`kafka\_connect\_run.sh`). Official Debezium images use a completely different startup mechanism (`docker-entrypoint.sh` + environment variables). You cannot simply swap in an arbitrary Connect image under Strimzi's CRD — the CRD and the image are tightly coupled.

### 7.3 What actually worked: Custom Image + Strimzi KafkaConnect CRD

Rather than fighting Strimzi's registry build mechanism, we built a custom Kafka Connect image locally and loaded it into `kind`. This allowed us to use the proper Strimzi `KafkaConnect` CRD.

First, build the custom image (which includes the Debezium MySQL plugin) and load it into the cluster:

```bash
docker build -t custom-debezium-connect:latest ./debezium
kind load docker-image custom-debezium-connect:latest --name cdc-lab
```

`debezium/kafka-connect.yaml`:

```yaml
apiVersion: kafka.strimzi.io/v1
kind: KafkaConnect
metadata:
  name: cdc-connect
  namespace: kafka
  annotations:
    strimzi.io/use-connector-resources: "true"
spec:
  version: 4.2.0
  replicas: 1
  image: custom-debezium-connect:latest
  bootstrapServers: cdc-kafka-kafka-bootstrap:9092
  config:
    group.id: cdc-connect-cluster
    offset.storage.topic: cdc-connect-offsets
    config.storage.topic: cdc-connect-configs
    status.storage.topic: cdc-connect-status
    config.storage.replication.factor: -1
    offset.storage.replication.factor: -1
    status.storage.replication.factor: -1
```
---
apiVersion: v1
kind: Service
metadata:
  name: kafka-connect
  namespace: kafka
spec:
  selector:
    app: kafka-connect
  ports:
    - port: 8083
      targetPort: 8083
```

Apply:

```bash
kubectl apply -f debezium/kafka-connect.yaml
kubectl get pods -n kafka -w
```

This image already bundles the Debezium connector plugins (mysql, MySQL, MongoDB, Oracle, SQL Server, etc.) — no build or registry push needed.

### 7.4 Verify Kafka Connect is healthy

```bash
kubectl exec -n kafka <kafka-connect-pod-name> -- curl -s localhost:8083/
```

Should return JSON with version/cluster info.

Check available plugins:

```bash
kubectl exec -n kafka <kafka-connect-pod-name> -- curl -s localhost:8083/connector-plugins | grep -i mysql
```

Should list `io.debezium.connector.mysqlql.mysqlConnector`.

\---

## 8\. Registering Debezium Connectors (GitOps)

Connector configs are now managed declaratively via Strimzi's `KafkaConnector` CRD, allowing Argo CD to fully manage their lifecycle.

### 8.1 Test connector (in-cluster mysql)

`connector-configs/mysql-connector.yaml`:

```yaml
apiVersion: kafka.strimzi.io/v1
kind: KafkaConnector
metadata:
  name: mysql-connector
  namespace: kafka
  labels:
    strimzi.io/cluster: cdc-connect
spec:
  class: io.debezium.connector.mysql.MySqlConnector
  tasksMax: 1
  config:
    database.hostname: "host.docker.internal"
    database.port: "3306"
    database.user: "debezium"
    database.password: "dbz_password"
    database.server.id: "184054"
    topic.prefix: "mysqlcdc"
    database.include.list: "cdc_test"
    database.connectionTimeZone: "UTC"
    schema.history.internal.kafka.bootstrap.servers: "cdc-kafka-kafka-bootstrap:9092"
    schema.history.internal.kafka.topic: "schema-changes.cdc_test"
```

### 8.2 Register a connector

Simply apply the manifest (or let Argo CD sync it):

```bash
kubectl apply -f connector-configs/mysql-connector.yaml
```

### 8.3 Check connector/task status

You can check the status via Kubernetes native commands:

```bash
kubectl get kafkaconnector -n kafka
kubectl describe kafkaconnector mysql-connector -n kafka
```

Look for `Ready` in the status conditions.

### 8.4 Delete a connector

```bash
kubectl delete -f connector-configs/mysql-connector.yaml
```

\---

## 9\. Connecting to a Database Hosted on Windows

Connecting Debezium (running inside a `kind`/Docker container on WSL2) to a native Windows MySQL install required bridging several network layers: **pod → kind node (Docker container) → Docker Desktop → WSL2 → Windows host**.

### 9.1 Configure MySQL on Windows for CDC

In `MySQL.conf` (path via `SHOW config\_file;` in `psql`, typically `C:\\Program Files\\MySQL\\<version>\\data\\MySQL.conf`):

```
listen\_addresses = '\*'
wal\_level = logical
```

> Both lines are commented out (`#...`) by default. Make sure to \*\*uncomment\*\* them, not just add new lines — a duplicate commented-out line does nothing.

### 9.2 Allow remote connections — `pg\_hba.conf`

Same data directory:

```
host    all             all             172.16.0.0/12          scram-sha-256
host    all             all             192.168.0.0/16          scram-sha-256
```

### 9.3 Restart MySQL (required for `wal\_level` to take effect)

PowerShell (as Administrator):

```powershell
Restart-Service mysql-x64-<version>
```

### 9.4 Allow the port through Windows Firewall

```powershell
New-NetFirewallRule -DisplayName "MySQL CDC" -Direction Inbound -Protocol TCP -LocalPort 5432 -Action Allow
```

### 9.5 Grant replication rights to the connecting user

In `psql` (as a superuser):

```sql
ALTER ROLE your\_username REPLICATION;
```

### 9.6 Verify the settings actually applied

```sql
SHOW wal\_level;   -- must return 'logical'
```

### 9.7 The networking path that actually worked: `host.docker.internal`

Several hostnames/IPs were tested from different points in the network stack:

|From|Target|Result|
|-|-|-|
|WSL2 shell|`host.docker.internal`|❌ Timed out (resolved to a stale/incorrect IP)|
|WSL2 shell|vEthernet (WSL) adapter IP (e.g. `172.17.144.1`, found via Windows `ipconfig`)|✅ Worked|
|kind node (Docker container)|that same vEthernet IP|❌ Timed out — Docker containers are network-isolated from WSL2's own interfaces|
|kind node (Docker container)|`host.docker.internal`|✅ Worked (Docker Desktop provides this specifically for container→host access)|

**Conclusion:** always use **`host.docker.internal`** as `database.hostname` in the connector config — this is Docker Desktop's built-in mechanism for containers to reach the host, and it resolves correctly *inside* the kind node/pods, even though it may resolve differently (or not work at all) from a plain WSL2 shell.

Test connectivity directly from inside the kind node before trying via the connector:

```bash
docker exec cdc-lab-control-plane getent hosts host.docker.internal
docker exec cdc-lab-control-plane bash -c "echo > /dev/tcp/host.docker.internal/5432" \&\& echo SUCCESS || echo FAILED
```

\---

## 10\. Verifying the Pipeline — Manual Tests

### 10.1 List Kafka topics

Debezium auto-creates one topic per table it captures, named `<topic.prefix>.<schema>.<table>`:

```bash
kubectl exec -n kafka cdc-kafka-dual-role-0 -- \\
  bin/kafka-topics.sh --bootstrap-server localhost:9092 --list
```

### 10.2 Read existing messages from a topic

```bash
kubectl exec -n kafka cdc-kafka-dual-role-0 -- \\
  bin/kafka-console-consumer.sh \\
  --bootstrap-server localhost:9092 \\
  --topic winpg.public.Clients \\
  --from-beginning \\
  --max-messages 1
```

\# Prettier version

&#x20;

kubectl exec -n kafka cdc-kafka-dual-role-0 -- \\

&#x20; bin/kafka-console-consumer.sh \\

&#x20;   --bootstrap-server localhost:9092 \\

&#x20;   --topic mysqlcdc.cdc\_test.customers \\

&#x20;   --from-beginning \\

&#x20;   --max-messages 1

| jq '{op: .payload.op, before: .payload.before, after: .payload.after, ts: .payload.ts\_ms}'

### 10.3 Watch for a live change in real time

**Terminal A** — start a consumer that blocks waiting for the *next* new message (no `--from-beginning`):

```bash
kubectl exec -n kafka cdc-kafka-dual-role-0 -- \\
  bin/kafka-console-consumer.sh \\
  --bootstrap-server localhost:9092 \\
  --topic winpg.public.Clients \\
  --max-messages 1
```

**Terminal B** — make a real change in the source database:

```bash
psql -h host.docker.internal -U mysql -d PharmacieDB \\
  -c "UPDATE \\"Clients\\" SET \\"Solde\\" = '54321.00' WHERE \\"Code\\" = 'CL0001';"
```

**Terminal A** should immediately print the new event. Anatomy of a captured event:

```json
{
  "payload": {
    "before": null,
    "after": {
      "Code": "A1",
      "Nom": "Mehdi",
      "Solde": "1000",
      "...": "..."
    },
    "source": {
      "db": "PharmacieDB",
      "schema": "public",
      "table": "Clients",
      "txId": 2622,
      "lsn": 1557709336
    },
    "op": "u",
    "ts\_ms": 1783325569106
  }
}
```

|Field|Meaning|
|-|-|
|`op`|Operation type: `c` = create/insert, `u` = update, `d` = delete, `r` = read (initial snapshot)|
|`before` / `after`|Row state before and after the change (before may be `null` depending on the table's `REPLICA IDENTITY` setting)|
|`source.lsn`|MySQL WAL position — proves the event came from the live replication stream, not a snapshot|
|`source.snapshot`|`false` for live changes; `true`/`first\_in\_data\_collection`/etc. for initial snapshot reads|

\---

## 11\. GitOps with Argo CD

### 11.1 Repository structure

```
cdc-lab-gitops/
├── kafka/
│   └── kafka-cluster.yaml         # KafkaNodePool + Kafka (Strimzi)
├── mysql/
│   └── mysql.yaml              # Test mysql Deployment + Service
├── debezium/
│   └── kafka-connect.yaml         # Kafka Connect Deployment + Service
├── connector-configs/             # Excluded from Argo CD (see 11.4)
│   ├── mysql-connector.json
│   └── windows-mysql-connector.json
└── .gitignore
```

### 11.2 Push manifests to Git

```bash
git config --global user.name "Mehdi Ajam"
git config --global user.email "your-email@example.com"

git add .
git commit -m "Add Kafka, mysql, and Kafka Connect manifests for CDC pipeline"
git push origin main
```

> GitHub no longer accepts account passwords for `git push` over HTTPS. Use a \*\*Personal Access Token\*\* (GitHub → Settings → Developer settings → Personal access tokens → Generate new token (classic), scope: `repo`) as the password when prompted. To avoid re-entering it every push:
> ```bash
> git config --global credential.helper store
> ```

### 11.3 Create the Argo CD Application (via UI)

**Argo CD UI → "+ NEW APP"**

|Field|Value|
|-|-|
|Application Name|`cdc-pipeline`|
|Project|`default`|
|Sync Policy|**Automatic**, with **Prune Resources** and **Self Heal** checked|
|Repository URL|`https://github.com/Mehdiajam/cdc-lab-gitops.git`|
|Revision|`HEAD`|
|Path|`.`|
|Directory Recurse|**enabled** (required — manifests live in subfolders, not repo root)|
|Directory Exclude|`connector-configs/\*\*`|
|Cluster URL|`https://kubernetes.default.svc`|
|Namespace|`kafka`|

Equivalent via CLI:

```bash
argocd app create cdc-pipeline \\
  --repo https://github.com/Mehdiajam/cdc-lab-gitops.git \\
  --path . \\
  --directory-recurse \\
  --dest-server https://kubernetes.default.svc \\
  --dest-namespace kafka \\
  --sync-policy automated \\
  --self-heal \\
  --auto-prune
```

### 11.4 Why `connector-configs/` is excluded from Argo CD

Connector JSON files are **not Kubernetes manifests** — they're REST API payloads consumed by Kafka Connect's own HTTP API (`POST /connectors`), applied via `curl`, never via `kubectl`. When Argo CD's directory recursion first picked these files up, it failed with:

```
Object 'Kind' is missing in '{"config":{...},"name":"inventory-connector"}'
```

Excluding `connector-configs/\*\*` keeps a clean separation: Argo CD manages Kubernetes resources; connector registration is a separate, deliberate step (§8).

### 11.5 What Argo CD actually provides here

* **Single source of truth** — the Git repo defines exactly what should exist in the cluster; no more remembering a sequence of `kubectl apply` commands.
* **Self-healing** — if the live cluster drifts from Git (e.g. someone runs `kubectl scale ... --replicas=0` manually), Argo CD detects and reverts it automatically. Demonstrated with:

```bash
  kubectl scale deployment mysql -n kafka --replicas=0
  # Argo CD auto-restores replicas=1 within moments, since Git says 1
  ```

* **Audit trail \& rollback** — every infrastructure change is a Git commit; Argo CD's "History and Rollback" view allows one-click revert to any previous state.
* **Disaster recovery** — proven directly in this project (§12): when the entire `kind` cluster was lost, re-deploying Kafka, MySQL, and Kafka Connect required only recreating the cluster and re-pointing Argo CD at the existing repo — no manifest work needed.

**What Argo CD does *not* do here:** it is not part of the CDC data path itself. MySQL → Debezium → Kafka functions completely independently of Argo CD; Argo CD only manages *how the underlying infrastructure gets deployed and kept consistent*.

\---

## 12\. Disaster Recovery — Lessons from a Real Incident

During this project, the entire `cdc-lab` kind cluster was accidentally deleted (likely during cleanup while working on an unrelated project in a different kind cluster, `demo-loki`). This section documents the actual recovery, since it doubles as a good demonstration of why GitOps matters.

### 12.1 Diagnosing cluster loss

Symptom: `kubectl` commands returned `Error from server (NotFound): namespaces "kafka" not found`, despite the namespace clearly having existed before.

```bash
kubectl config current-context      # revealed the WRONG context was active (kind-demo-loki)
kubectl config get-contexts         # listed all known contexts
kind get clusters                   # confirmed cdc-lab was NOT in the list of live clusters
docker ps -a | grep cdc-lab         # confirmed: no container at all — cluster genuinely deleted
```

> \*\*Key lesson:\*\* always verify `kubectl config current-context` before running commands, especially when multiple `kind` clusters exist for different projects. Consider a prompt tool like `kube-ps1` that displays the active context in your shell prompt at all times.

### 12.2 Recovery steps

1. **Recreate the cluster:**

```bash
   kind create cluster --name cdc-lab
   kubectl config use-context kind-cdc-lab
   ```

2. **Reinstall Strimzi operator** (§5.1) and **Argo CD** (§4.1) — these were installed imperatively, not via GitOps, so they must be reinstalled manually each time.
3. **Recreate the `MySQL-credentials` Secret** (§6.1) — Secrets were deliberately never committed to Git (they'd expose plaintext credentials), so they must be recreated by hand after any cluster rebuild. This was the one step initially missed, causing `MySQL` to fail with `CreateContainerConfigError` until the Secret was recreated.
4. **Recreate the Argo CD Application** (§11.3) pointing at the same Git repo — Argo CD then automatically redeployed Kafka, mysql, and Kafka Connect exactly as they were defined in Git, with no manual manifest work required.
5. **Re-register the Debezium connector** (§8.3) — this lives in `connector-configs/`, intentionally outside Argo CD's management, so it must be re-registered via the API after any rebuild.
6. **Re-verify connectivity** to `PharmacieDB` (§10.3) — confirmed working identically to before, since `host.docker.internal` resolution is a property of Docker Desktop, not tied to a specific cluster instance.

### 12.3 What this proved

Everything that was defined in Git (Kafka, MySQL, Kafka Connect) came back with almost no effort. Everything that lived *outside* Git (the operators, Argo CD itself, the Secret, the connector registration) had to be redone by hand — a direct, practical illustration of why GitOps matters and which gaps remain in this setup (see §13).

\---

## 13\. Known Gaps \& Future Improvements

* **Plaintext credentials:** the `mysql-connector.json` file currently stores database credentials in plain text (mitigated somewhat since the current password is empty, but this is not a real solution). Planned fix: integrate **External Secrets Operator (ESO) + Vault** — already used successfully on another project — to inject credentials at runtime instead of storing them in Git or in plain JSON files.
* **Operators \& Argo CD itself are not GitOps-managed** — Strimzi's operator and Argo CD were installed imperatively (`kubectl apply` against upstream manifests). A more mature setup would manage these via an "app of apps" Argo CD pattern, so a full environment rebuild requires zero manual `kubectl` steps.
* **Ephemeral storage** — both Kafka and mysql currently use `ephemeral` storage, meaning all data is lost on pod restart. Fine for a local proof-of-concept; would need persistent volumes for anything longer-lived.
* **Single broker / single replica everywhere** — appropriate for local testing, not representative of production resilience (no replication, no fault tolerance).
* **Git history still contains old credential references** — Level 1 cleanup was performed (stopped tracking `connector-configs/\*.json` going forward via `.gitignore` + `git rm --cached`); a full history purge (`git filter-repo`) was deferred since the exposed password is empty, but should be done before any real password is ever committed.

\---

## 14\. Quick Reference — Common Commands

```bash
# Switch cluster context (important when working across multiple kind clusters)
kubectl config get-contexts
kubectl config use-context kind-cdc-lab

# Check everything is running
kubectl get pods -n kafka
kubectl get pods -n argocd

# Port-forward Argo CD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443 \&

# List Kafka topics
kubectl exec -n kafka cdc-kafka-dual-role-0 -- bin/kafka-topics.sh --bootstrap-server localhost:9092 --list

# Check a connector's status
kubectl exec -n kafka <kafka-connect-pod> -- curl -s localhost:8083/connectors/mysql-connector/status

# Watch live CDC events
kubectl exec -n kafka cdc-kafka-dual-role-0 -- bin/kafka-console-consumer.sh \\
  --bootstrap-server localhost:9092 --topic winpg.public.Clients --max-messages 1
```

