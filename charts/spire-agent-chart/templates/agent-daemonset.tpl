apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: spire-agent
  namespace: {{ .Values.namespace }}
  labels:
    app: spire-agent
spec:
  selector:
    matchLabels:
      app: spire-agent
  template:
    metadata:
      namespace: spire
      labels:
        app: spire-agent
    spec:
      hostPID: true
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      serviceAccountName: "spire-agent"
      containers:
        - name: spire-agent
          image: gcr.io/spiffe-io/spire-agent:0.11.0
          args: ["-config", "/run/spire/config/agent.conf","-joinToken","{{ .Values.joinToken }}"]
          volumeMounts:
            - name: spire-config
              mountPath: /run/spire/config
              readOnly: true
            - name: spire-agent-socket
              mountPath: /run/spire/sockets
              readOnly: false
            - name: spire-agent-token
              mountPath: /var/run/secrets/tokens
          livenessProbe:
            exec:
              command:
                - /opt/spire/bin/spire-agent
                - healthcheck
                - -socketPath
                - /run/spire/sockets/agent.sock
            failureThreshold: 2
            initialDelaySeconds: 15
            periodSeconds: 60
            timeoutSeconds: 3
      volumes:
        - name: spire-config
          configMap:
            name: spire-agent
        - name: spire-bundle
          configMap:
            name: spire-bundle
        - name: spire-agent-socket
          hostPath:
            path: /run/spire/sockets
            type: DirectoryOrCreate
        - name: spire-agent-token
          projected:
            sources:
            - serviceAccountToken:
                path: spire-agent
                expirationSeconds: 600
                audience: spire-server
