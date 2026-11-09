# Lab 12: Kafka as a platform service: topics as code, with guardrails

**Time:** about 60 minutes · **Level:** beginner-friendly · **Needs:** Lab 5 (Kyverno)

Teams want event streaming without filing a ticket with "the Kafka team". You'll run a shared
Kafka cluster on cell-1 with **Strimzi**, let a team declare its **topic** and **user** as YAML,
and add **guardrails**: naming, size limits, and "you can only touch your own topics".

---

## Part A: The ideas in plain words

### A1. Kafka in one minute

| Word | Plain meaning |
|---|---|
| **Broker** | A Kafka server that stores messages |
| **Topic** | A named stream of messages, like a log file that many apps append to and read from |
| **Partition** | A topic is split into partitions so many consumers can read in parallel |
| **Retention** | How long messages are kept (here: days) |
| **Producer / consumer** | Writes to / reads from a topic. Consumers in a **group** share the work |
| **KRaft** | Kafka's own metadata mode (no ZooKeeper any more) |

### A2. Strimzi: Kafka as Kubernetes resources

**Strimzi** is an operator. You describe Kafka in YAML; it runs the brokers and keeps the
topics and users in sync:

| Resource | Becomes |
|---|---|
| `Kafka` + `KafkaNodePool` | The cluster (pods, storage, listeners, certificates) |
| `KafkaTopic` | A real topic (created by the **Topic Operator**) |
| `KafkaUser` | A client certificate + ACLs + quotas (created by the **User Operator**) |

### A3. Identity, permissions, fairness

```text
identity-svc pod ──mTLS (its own certificate)──► Kafka listener :9093 (TLS, client cert required)
                                                     │ who are you?   → CN=identity-svc
                                                     │ may you?       → ACLs: topics and groups starting "identity."
                                                     │ how much?      → quotas: 1 MiB/s produce, 2 MiB/s consume
```

- **No anonymous access**: the only listener needs a client certificate.
- **Prefix ACLs**: team `identity` owns everything named `identity.*` and nothing else.
- **Quotas**: one noisy team can't slow everybody down.

### A4. Guardrails at admission

The same Kyverno as Lab 5, now for `KafkaTopic`. A topic is rejected if:
- its name isn't `<team>.<name>`;
- it has more than 12 partitions;
- it keeps data longer than 7 days.

---

## Part B: Files in this folder

| File | What it is |
|---|---|
| `addon-strimzi-appset.yaml` | The Strimzi operator (chart 1.3.1) on **cell-1** only, namespace `kafka` |
| `kafka-cluster.yaml` | One-node KRaft Kafka 4.3.2 `platform`: mTLS-only listener, ACLs on, no auto-created topics |
| `team-repo-example/deploy/kafka/topic.yaml` | What a team writes: `identity.tenant-events`, 6 partitions, 3 days |
| `team-repo-example/deploy/kafka/user.yaml` | The team's identity `identity-svc`: certificate, prefix ACLs, quotas |
| `40-kafka-topic-guardrails.yaml` | The Kyverno policy (goes into `platform/policies`) |
| `mtls-client-test.sh` | A client pod that proves allowed and denied access |

```bash
export KUBECONFIG=~/idp-lab/fleet.kubeconfig
cd ~/idp-lab/platform-labs/lab-12-kafka-topics
```

---

## Step 1: The Strimzi operator on cell-1 (through Argo CD)

```bash
kubectl --context hub apply -f addon-strimzi-appset.yaml
kubectl --context hub -n argocd get app -l fleet.lab/addon=kafka
kubectl --context cell-1 -n kafka get pods
kubectl --context cell-1 api-resources | grep kafka.strimzi.io
```

**You should see:** `strimzi-cell-1` Synced / Healthy and `strimzi-cluster-operator` Running. The
values add `app.kubernetes.io/part-of: kafka-platform` to its pods, because your Lab 5 guardrail
applies to platform pods too.

---

## Step 2: The shared Kafka cluster

```bash
kubectl --context cell-1 apply -f kafka-cluster.yaml
kubectl --context cell-1 -n kafka get kafka platform -w      # wait for READY True (2-4 minutes)
kubectl --context cell-1 -n kafka get pods
```

**You should see:** `platform-dual-role-0` (the broker) and `platform-entity-operator-…` (Topic
and User Operators) Running.

Read `kafka-cluster.yaml`: one listener, `tls: true`, `authentication: tls`,
`authorization: simple`, `auto.create.topics.enable: false`. **A topic exists only if someone
declared it.**

> Single node means replication factor 1. Production: 3 controllers + N brokers across zones,
> RF=3, `min.insync.replicas=2`.

---

## Step 3: The guardrail (through Git)

```bash
cd /tmp && { [ -d policies ] || git clone http://localhost:3300/platform/policies.git; } && cd policies && git pull
cp ~/idp-lab/platform-labs/lab-12-kafka-topics/40-kafka-topic-guardrails.yaml .
git add . && git commit -m "Guardrails for Kafka topics" && git push
kubectl --context hub -n argocd annotate app policies-cell-1 policies-cell-2 argocd.argoproj.io/refresh=normal --overwrite
kubectl --context cell-1 get clusterpolicy kafka-topic-guardrails
```

**You should see:** `READY True` on cell-1. On cell-2 there's no Strimzi, so Kyverno warns that
the kind is unknown and the rule simply has nothing to check. That's why the policy can go to
the whole fleet.

> **Order matters (found while testing).** If the policy reaches a cell **before** the
> `KafkaTopic` kind exists there, Kyverno keeps a stale copy and does **not** check topics, even
> after Strimzi is installed. That's why this step comes after Step 1. If you later add Strimzi
> to cell-2, re-apply the policy there (any change to it, or a Kyverno restart) and test with a
> bad topic.

The file also has a small ClusterRole so Kyverno's reports and background controllers may read
KafkaTopics (without it you get a "requires permissions get,list,watch" warning).

Prove it with three bad topics:

```bash
cd ~/idp-lab/platform-labs/lab-12-kafka-topics
for t in 'events:3:86400000' 'identity.huge:50:86400000' 'identity.forever:3:2592000000'; do
  IFS=: read name parts ret <<<"$t"
  cat <<EOF | kubectl --context cell-1 apply -f - 2>&1 | tail -1
apiVersion: kafka.strimzi.io/v1
kind: KafkaTopic
metadata: { name: $name, namespace: kafka, labels: { strimzi.io/cluster: platform } }
spec: { partitions: $parts, replicas: 1, config: { retention.ms: $ret } }
EOF
done
```

**You should see:** all three **denied** by `kafka-topic-guardrails`: no team prefix, 50 partitions,
30 days.

Kubernetes already rejects uppercase object names, so the regex only has to check the
`<team>.<name>` shape.

---

## Step 4: Be the team: declare a topic and a user

```bash
kubectl --context cell-1 apply -f team-repo-example/deploy/kafka/
kubectl --context cell-1 -n kafka get kafkatopic,kafkauser
kubectl --context cell-1 -n kafka get secret identity-svc
```

**You should see:** the topic and the user `READY True`, and a Secret `identity-svc` holding the
team's client certificate (`user.p12`, `user.password`), written by the User Operator.

> **In real life** these two files live in the team's own repo (for example created by a
> Backstage template), and Argo CD syncs them. No ticket, no Kafka admin. The platform
> controls the shape through the policy, the ACLs and the quotas.

---

## Step 5: Prove identity and ACLs

```bash
./mtls-client-test.sh
```

It starts a client pod with the team's certificate and the cluster's CA, then:
1. produces `hello` to `identity.tenant-events` (allowed);
2. consumes it back with group `identity.reader` (allowed);
3. produces to `payments.ledger` (another team's prefix): **denied**.

**You should see:** `hello` printed by the consumer, then
`TopicAuthorizationException: Not authorized to access topics: [payments.ledger]`.

Clean up: `kubectl --context cell-1 -n kafka delete pod identity-client`.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Strimzi or Kafka pods missing, `FailedCreate` | Your Lab 5 guardrails (`part-of` label, pinned tags) |
| Kafka not Ready for a long time | Not enough memory in Docker; the broker requests 1 Gi |
| Bad topics are *accepted* | The policy reached the cell before the Strimzi CRDs: re-apply it (`kubectl annotate clusterpolicy kafka-topic-guardrails lab/touch=$(date +%s) --overwrite`), then test again |
| Topic Ready False | The topic must be in namespace `kafka` with label `strimzi.io/cluster: platform` |
| Client: `SSL handshake failed` | Wrong truststore/keystore or password; the script reads them from the Secrets |

---

## Questions to think through

1. **Shared cluster vs cluster per tenant vs a managed service (MSK, MSK Serverless, Event Hubs)?**
   Isolation, noisy neighbours, minimum cost, compliance boundary, and who runs it at 3 a.m.
2. **Schemas as a platform service.** Where does the registry live (Apicurio, Confluent Schema
   Registry, AWS Glue)? BACKWARD compatibility checked in CI; schemas live in the service repo.
3. **A Backstage template for an event-driven service.** Topic + user + schema + dead-letter
   topic + consumer group naming + dashboards, all as code in the new repo.
4. **Why prefix ACLs and not one ACL per topic?** A team creates topics without asking the
   platform again; ownership is the naming convention, enforced by the guardrail.
