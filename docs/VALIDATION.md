# Validation and evidence

Commands to prove each requirement, with the output you should expect.

---

## 1. `wizexercise.txt` — how it got in, and proof it is there

**How it got in.** It is a file at `app/wizexercise.txt` in this repository, copied into
the image at build time by the last `COPY` in `app/Dockerfile`:

```dockerfile
COPY wizexercise.txt /app/wizexercise.txt
```

It is baked into an image layer, not mounted, injected, or fetched at runtime. Delete the
container and rebuild from the image and the file is still there.

### Proof A — in the image layers, before it runs

```bash
docker build -t wiz-todo:local app/
docker run --rm --entrypoint sh wiz-todo:local -c 'ls -l /app/wizexercise.txt && cat /app/wizexercise.txt'
```

Or inspect the layer without running anything:

```bash
docker save wiz-todo:local | tar -tv | grep wizexercise
```

### Proof B — in the running container on Kubernetes

```bash
POD=$(kubectl -n wiz-todo get pods -l app.kubernetes.io/name=wiz-todo \
        -o jsonpath='{.items[0].metadata.name}')

kubectl -n wiz-todo exec "$POD" -- ls -l /app/wizexercise.txt
kubectl -n wiz-todo exec "$POD" -- cat /app/wizexercise.txt
```

Expected:

```
-rw-r--r-- 1 app app 18 Aug 10 12:00 /app/wizexercise.txt
Your Full Name
```

### Proof C — over HTTP, through the load balancer

```bash
ALB=$(kubectl -n wiz-todo get ingress wiz-todo \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl "http://$ALB/wizexercise.txt"
curl -s "http://$ALB/api/status" | jq
```

### Proof D — in the pipeline

Both `.github/workflows/app.yml` verification steps write the file contents to the job
summary: once from the built image before push, once from the running pod after rollout.
Screenshot the job summary for your walkthrough.

---

## 2. The app really uses MongoDB, via an environment variable

```bash
kubectl -n wiz-todo get deployment wiz-todo -o yaml | grep -A6 'name: MONGODB_URI'
kubectl -n wiz-todo exec "$POD" -- printenv MONGODB_URI
```

The URI resolves to the VM's **private** IP. Add a todo in the UI, then read it back off
the VM directly:

```bash
ssh -i ~/.ssh/wizex ubuntu@$(terraform -chdir=terraform output -raw mongodb_public_ip)
mongo wizdemo -u todoapp -p --authenticationDatabase wizdemo --eval 'db.todos.find().pretty()'
```

---

## 3. Outdated versions

```bash
# Operating system
ssh ubuntu@<vm-ip> 'lsb_release -a'          # Ubuntu 20.04 LTS, April 2020

# Database
ssh ubuntu@<vm-ip> 'mongod --version'        # db version v4.4.x, EOL February 2024
```

Or from the app, with no SSH needed: `curl http://$ALB/api/status` returns
`databaseVersion`.

---

## 4. Database access is restricted to Kubernetes, and requires auth

```bash
# From your laptop: should hang and time out. The security group only allows the EKS nodes.
nc -vz <vm-public-ip> 27017

# Unauthenticated access from a pod: rejected.
kubectl -n wiz-todo exec "$POD" -- node -e "
  const {MongoClient} = require('mongodb');
  new MongoClient('mongodb://<vm-private-ip>:27017/wizdemo')
    .connect().then(c => c.db('wizdemo').collection('todos').find().toArray())
    .then(console.log).catch(e => console.log('rejected:', e.message));
"
```

Also confirm on the host that authorization is on:

```bash
ssh ubuntu@<vm-ip> 'grep -A2 security /etc/mongod.conf'
```

---

## 5. Backups run daily and land in the public bucket

```bash
ssh ubuntu@<vm-ip> 'cat /etc/cron.d/mongo-backup; tail -20 /var/log/mongo-backup.log'

BUCKET=$(terraform -chdir=terraform output -raw mongodb_backup_bucket)
aws s3 ls "s3://$BUCKET/backups/wizdemo/"
```

Force one immediately rather than waiting for 02:00 UTC:

```bash
ssh ubuntu@<vm-ip> 'sudo /usr/local/bin/mongo-backup.sh'
```

---

## 6. The bucket is anonymously readable and listable

Use `--no-sign-request`, or a logged-out browser, to prove there is no credential involved:

```bash
aws s3 ls "s3://$BUCKET/" --recursive --no-sign-request
curl -s "https://$BUCKET.s3.<region>.amazonaws.com/" | head -40

KEY=$(aws s3 ls "s3://$BUCKET/backups/wizdemo/" --no-sign-request | awk '{print $4}' | tail -1)
curl -sO "https://$BUCKET.s3.<region>.amazonaws.com/backups/wizdemo/$KEY"
mongorestore --gzip --archive="$KEY" --dryRun
```

That last command is the punchline: a complete copy of the database, restorable by anyone,
with no AWS account required.

---

## 7. Cluster-admin on the workload

```bash
kubectl auth can-i '*' '*' --all-namespaces \
  --as=system:serviceaccount:wiz-todo:wiz-todo          # yes

kubectl describe clusterrolebinding wiz-todo-cluster-admin
```

From inside the pod, using its mounted service account token:

```bash
kubectl -n wiz-todo exec "$POD" -- sh -c '
  TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  wget -qO- --no-check-certificate \
    --header="Authorization: Bearer $TOKEN" \
    https://kubernetes.default.svc/api/v1/namespaces/kube-system/secrets | head -c 400
'
```

---

## 8. Nodes are in private subnets

```bash
kubectl get nodes -o wide     # internal IPs only, no external IP
aws ec2 describe-instances \
  --filters "Name=tag:eks:cluster-name,Values=$(terraform -chdir=terraform output -raw eks_cluster_name)" \
  --query 'Reservations[].Instances[].{Id:InstanceId,Public:PublicIpAddress,Subnet:SubnetId}'
```

`Public` should be `null` for every node.

---

## 9. Audit logging and controls

```bash
# CSP control plane audit logging
aws cloudtrail get-trail-status --name $(terraform -chdir=terraform output -raw cloudtrail_name)
aws cloudtrail lookup-events --max-results 5

# Kubernetes control plane audit logging
aws logs describe-log-groups --log-group-name-prefix /aws/eks/

# Detective: which rules are failing, and why that is the desired outcome
aws configservice describe-compliance-by-config-rule \
  --query 'ComplianceByConfigRules[?Compliance.ComplianceType==`NON_COMPLIANT`].ConfigRuleName'

aws guardduty list-findings --detector-id $(aws guardduty list-detectors --query 'DetectorIds[0]' --output text)

# Preventative: prove IMDSv1 is refused
ssh ubuntu@<vm-ip> 'curl -s -m 3 http://169.254.169.254/latest/meta-data/ || echo "IMDSv1 blocked"'
ssh ubuntu@<vm-ip> 'TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60"); \
  curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/iam/security-credentials/'

aws ec2 get-ebs-encryption-by-default    # true
```
