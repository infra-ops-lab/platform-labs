#!/bin/bash
# Tested with Strimzi 1.3.1 and Kafka 4.3.2. Proves: mTLS identity -> prefix ACLs -> other teams' topics denied.
export KUBECONFIG=~/idp-lab/fleet.kubeconfig; k1(){ kubectl --context cell-1 "$@"; }
cat <<'YAML' | k1 apply -f -
apiVersion: v1
kind: Pod
metadata: { name: identity-client, namespace: kafka, labels: { app.kubernetes.io/part-of: lab } }
spec:
  restartPolicy: Never
  containers:
    - name: c
      image: quay.io/strimzi/kafka:1.3.1-kafka-4.3.2
      command: [sleep, "3600"]
      env:
        - { name: USER_PW, valueFrom: { secretKeyRef: { name: identity-svc, key: user.password } } }
        - { name: CA_PW, valueFrom: { secretKeyRef: { name: platform-cluster-ca-cert, key: ca.password } } }
      volumeMounts: [{ name: user, mountPath: /user }, { name: ca, mountPath: /ca }]
  volumes:
    - { name: user, secret: { secretName: identity-svc } }             # issued by the User Operator
    - { name: ca, secret: { secretName: platform-cluster-ca-cert } }   # cluster CA truststore
YAML
k1 -n kafka wait --for=condition=Ready pod/identity-client --timeout=120s
k1 -n kafka exec identity-client -- bash -c '
printf "security.protocol=SSL\nssl.truststore.location=/ca/ca.p12\nssl.truststore.type=PKCS12\nssl.truststore.password=$CA_PW\nssl.keystore.location=/user/user.p12\nssl.keystore.type=PKCS12\nssl.keystore.password=$USER_PW\n" > /tmp/c.properties
B=platform-kafka-bootstrap:9093; K=/opt/kafka/bin
echo hello | $K/kafka-console-producer.sh --bootstrap-server $B --command-config /tmp/c.properties --topic identity.tenant-events
$K/kafka-console-consumer.sh --bootstrap-server $B --command-config /tmp/c.properties --topic identity.tenant-events --group identity.reader --from-beginning --max-messages 1 --timeout-ms 20000
echo x | $K/kafka-console-producer.sh --bootstrap-server $B --command-config /tmp/c.properties --topic payments.ledger   # expect TopicAuthorizationException'
