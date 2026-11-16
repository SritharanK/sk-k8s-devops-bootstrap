{{/*
Policy catalogue (workload baseline plus host and privilege controls).

Each entry is rendered by validatingpolicies.yaml once per failure action.
`target` selects the resource rules: `workloads` (pods and pod controllers,
with the podSpec and containers variables) or `services`.

Semantics follow the Pod Security Standards "restricted" profile where the
two overlap: a container inherits runAsNonRoot and seccompProfile from the
pod securityContext unless it sets its own value. Init and ephemeral
containers are covered unless an entry says otherwise.
*/}}
{{- define "kyverno-policies.catalogue" -}}
policies:
  - name: require-run-as-non-root
    title: Require non-root containers
    category: Pod Security
    severity: high
    target: workloads
    description: >-
      Every container must run with runAsNonRoot true, set on the container or
      inherited from the pod, and no securityContext may set runAsUser to 0.
    validations:
      - expression: >-
          variables.containers.all(c,
          c.?securityContext.?runAsNonRoot.orValue(
          variables.podSpec.?securityContext.?runAsNonRoot.orValue(false)) == true)
        message: >-
          runAsNonRoot must be true for every container, including init and
          ephemeral containers, set on the container or on the pod securityContext.
      - expression: >-
          variables.podSpec.?securityContext.?runAsUser.orValue(1) != 0 &&
          variables.containers.all(c, c.?securityContext.?runAsUser.orValue(1) != 0)
        message: runAsUser must not be 0 in the pod or in any container securityContext.

  - name: disallow-privilege-escalation
    title: Disallow privilege escalation
    category: Pod Security
    severity: high
    target: workloads
    description: Every container must set allowPrivilegeEscalation to false.
    validations:
      - expression: >-
          variables.containers.all(c,
          c.?securityContext.?allowPrivilegeEscalation.orValue(true) == false)
        message: allowPrivilegeEscalation must be set to false in every container.

  - name: require-drop-all-capabilities
    title: Require dropping all capabilities
    category: Pod Security
    severity: high
    target: workloads
    description: >-
      Every container must drop ALL capabilities and may add back only
      NET_BIND_SERVICE.
    validations:
      - expression: >-
          variables.containers.all(c,
          'ALL' in c.?securityContext.?capabilities.?drop.orValue([]))
        message: Every container must set securityContext.capabilities.drop to include ALL.
      - expression: >-
          variables.containers.all(c,
          c.?securityContext.?capabilities.?add.orValue([]).all(cap, cap == 'NET_BIND_SERVICE'))
        message: Containers may add back only the NET_BIND_SERVICE capability.

  - name: require-seccomp-profile
    title: Require a seccomp profile
    category: Pod Security
    severity: high
    target: workloads
    description: >-
      The effective seccompProfile.type of every container must be
      RuntimeDefault or Localhost.
    validations:
      - expression: >-
          variables.containers.all(c,
          c.?securityContext.?seccompProfile.?type.orValue(
          variables.podSpec.?securityContext.?seccompProfile.?type.orValue('')) in ['RuntimeDefault', 'Localhost'])
        message: >-
          seccompProfile.type must be RuntimeDefault or Localhost for every
          container, set on the container or on the pod securityContext.

  - name: require-read-only-root-filesystem
    title: Require a read-only root filesystem
    category: Workload Contract
    severity: medium
    target: workloads
    description: >-
      Every container must set readOnlyRootFilesystem to true. Writable paths
      are mounted volumes, for example an emptyDir on /tmp.
    validations:
      - expression: >-
          variables.containers.all(c,
          c.?securityContext.?readOnlyRootFilesystem.orValue(false) == true)
        message: readOnlyRootFilesystem must be true in every container; mount an emptyDir for writable paths.

  - name: require-requests-limits
    title: Require CPU and memory requests and limits
    category: Workload Contract
    severity: medium
    target: workloads
    description: >-
      Every regular and init container must declare CPU and memory requests
      and limits. Ephemeral containers cannot declare resources and are not
      checked.
    variables:
      - name: sizedContainers
        expression: >-
          variables.podSpec.containers + variables.podSpec.?initContainers.orValue([])
    validations:
      - expression: >-
          variables.sizedContainers.all(c,
          ['cpu', 'memory'].all(r, r in c.?resources.?requests.orValue({})))
        message: Every container and init container must set resources.requests for cpu and memory.
      - expression: >-
          variables.sizedContainers.all(c,
          ['cpu', 'memory'].all(r, r in c.?resources.?limits.orValue({})))
        message: Every container and init container must set resources.limits for cpu and memory.

  - name: require-probes
    title: Require readiness and liveness probes
    category: Workload Contract
    severity: medium
    target: workloads
    description: >-
      Every regular container of a long-running workload must define a
      readinessProbe and a livenessProbe. Jobs, CronJobs and pods owned by a
      Job run to completion and are not checked.
    matchConditions:
      - name: long-running-workloads
        expression: >-
          !(object.kind in ['Job', 'CronJob']) &&
          !(object.kind == 'Pod' && object.metadata.?ownerReferences.orValue([]).exists(o, o.kind == 'Job'))
    validations:
      - expression: variables.podSpec.containers.all(c, has(c.readinessProbe))
        message: Every container must define a readinessProbe.
      - expression: variables.podSpec.containers.all(c, has(c.livenessProbe))
        message: Every container must define a livenessProbe.

  - name: require-image-tag-or-digest
    title: Require an immutable image reference
    category: Supply Chain
    severity: medium
    target: workloads
    description: >-
      Every image must carry an explicit tag other than latest, or a sha256
      digest. The tag is read after the last slash, so a registry port is not
      mistaken for a tag.
    validations:
      - expression: >-
          variables.containers.all(c,
          c.image.matches('@sha256:[a-f0-9]{64}$') ||
          c.image.substring(c.image.lastIndexOf('/') + 1).contains(':'))
        message: Every image must carry an explicit tag or a sha256 digest.
      - expression: >-
          variables.containers.all(c,
          c.image.matches('@sha256:[a-f0-9]{64}$') || !c.image.endsWith(':latest'))
        message: The latest tag is not allowed; use an immutable tag or a digest.

  - name: restrict-image-registries
    title: Restrict image registries
    category: Supply Chain
    severity: high
    target: workloads
    description: Every image must come from an allowed registry prefix.
    variables:
      - name: allowedRegistries
        expression: {{ include "kyverno-policies.allowedRegistries" . | squote }}
    validations:
      - expression: >-
          variables.containers.all(c,
          variables.allowedRegistries.exists(r, c.image.startsWith(r)))
        message: {{ printf "Images must come from an allowed registry: %s" (include "kyverno-policies.allowedRegistries" . | fromJsonArray | join ", ") | quote }}

  - name: disallow-privileged-containers
    title: Disallow privileged containers
    category: Pod Security
    severity: high
    target: workloads
    description: No container may run privileged.
    validations:
      - expression: >-
          variables.containers.all(c, c.?securityContext.?privileged.orValue(false) == false)
        message: Privileged containers are not allowed.

  - name: disallow-host-namespaces
    title: Disallow host namespaces and host ports
    category: Pod Security
    severity: high
    target: workloads
    description: >-
      Pods may not share the host network, PID or IPC namespace, and
      containers may not bind host ports.
    validations:
      - expression: >-
          !variables.podSpec.?hostNetwork.orValue(false) &&
          !variables.podSpec.?hostPID.orValue(false) &&
          !variables.podSpec.?hostIPC.orValue(false)
        message: hostNetwork, hostPID and hostIPC must not be enabled.
      - expression: >-
          variables.containers.all(c, c.?ports.orValue([]).all(p, p.?hostPort.orValue(0) == 0))
        message: Containers may not use hostPort.

  - name: disallow-host-path
    title: Disallow hostPath volumes
    category: Pod Security
    severity: high
    target: workloads
    description: Pods may not mount hostPath volumes.
    validations:
      - expression: variables.podSpec.?volumes.orValue([]).all(v, !has(v.hostPath))
        message: hostPath volumes are not allowed.

  - name: restrict-service-external-ips
    title: Restrict Service externalIPs
    category: Network
    severity: high
    target: services
    description: >-
      Services may not set externalIPs, which allow traffic interception
      (CVE-2020-8554). Expose workloads through the platform Gateway.
    validations:
      - expression: object.spec.?externalIPs.orValue([]).size() == 0
        message: Service externalIPs are not allowed; expose workloads through the platform Gateway.
{{- end -}}
