---
apiVersion: v1
kind: Namespace
metadata:
  name: security
---
apiVersion: v1
kind: Secret
metadata:
  name: onepassword-connect-credentials-secret
  namespace: security
stringData:
  1password-credentials.json: 'op://kubernetes/1password/OP_CREDENTIALS_JSON' # quote
---
apiVersion: v1
kind: Secret
metadata:
  name: onepassword-connect-vault-secret
  namespace: security
stringData:
  token: op://kubernetes/1password/OP_CONNECT_TOKEN
---
apiVersion: v1
kind: Namespace
metadata:
  name: flux-system
---
apiVersion: v1
kind: Namespace
metadata:
  name: network
---
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-tunnel-id-secret
  namespace: network
stringData:
  CLOUDFLARE_TUNNEL_ID: op://kubernetes/cloudflare/CLOUDFLARE_TUNNEL_ID
---
apiVersion: v1
kind: Namespace
metadata:
  name: observability
