set default-list
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

[confirm('Apply Talos config to ' + node + ' [y|N] ?')]
[doc('Apply Talos config to a node')]
apply-node node *args:
    just talos render-config {{ node }} | talosctl -n {{ node }} apply-config -f /dev/stdin {{ args }}

[confirm('Reboot node ' + node + ' [y|N] ?')]
[doc('Reboot a node')]
reboot-node node *args:
    talosctl -n {{ node }} reboot {{ args }}

[doc('Render Talos config for a node')]
[script]
render-config node:
    export CONTROLPLANE="$(just talos machine-controller {{ node }})"
    export SCHEMATIC="$(just talos schematic-id)"
    talosctl machineconfig patch <(just template "{{ source_directory() }}/machineconfig.yaml.j2") \
        -p @<(just template "{{ source_directory() }}/networking.yaml.j2") \
        -p @<(just template "{{ source_directory() }}/nodes/{{ node }}.yaml.j2")

[confirm('Reset node ' + node + ' [y|N] ?')]
[doc('Reset a node')]
reset-node node *args:
    talosctl -n {{ node }} reset --reboot=true --graceful=false {{ args }}

[confirm('Reset the Talos cluster ... continue?')]
[doc('Reset Talos across the whole cluster')]
reset-cluster:
    talosctl reset --nodes "$(talosctl config info -o json | jq --join-output '[.nodes[]] | join(",")')" --graceful=false

[confirm('Shutdown node ' + node + ' [y|N] ?')]
[doc('Shutdown a node')]
shutdown-node node *args:
    talosctl -n {{ node }} shutdown --force {{ args }}

[doc('Show Thunderbolt mesh status for a node')]
[script]
tb-status node:
    echo "==> thunderbolt bus ({{ node }})"
    talosctl -n {{ node }} list /sys/bus/thunderbolt/devices
    echo "==> thunderbolt-net links ({{ node }})"
    talosctl -n {{ node }} get links -o json \
        | jq -r 'select(.spec.driver == "thunderbolt-net")
            | [(.spec.alias // .metadata.id), .metadata.id, .spec.busPath, .spec.operationalState,
               (if ((.spec.flags // "") | test("LOWER_UP")) then "carrier" else "NO-CARRIER" end)]
            | @tsv' \
        | column -t

[confirm('Re-negotiate Thunderbolt links on ' + node + ' [y|N] ?')]
[doc('Software replug of a Thunderbolt link (domain: all|0|1, mode: rebind|pci)')]
[script]
tb-reset node domain='all' mode='rebind':
    [[ "{{ mode }}" =~ ^(rebind|pci)$ ]] || { echo "mode must be rebind or pci"; exit 1; }
    [[ "{{ domain }}" =~ ^(all|[0-9]+)$ ]] || { echo "domain must be all or a domain number"; exit 1; }
    hostname="$(just talos machine-hostname {{ node }})"
    pod="tb-reset-${hostname}"
    trap 'kubectl -n default delete pod "$pod" --ignore-not-found --wait=false' EXIT
    kubectl -n default delete pod "$pod" --ignore-not-found
    sed -e "s|@POD@|${pod}|g" -e "s|@NODE@|${hostname}|g" <<'EOF' | kubectl -n default apply -f -
    apiVersion: v1
    kind: Pod
    metadata:
      name: "@POD@"
      labels:
        app.kubernetes.io/name: tb-reset
    spec:
      nodeName: "@NODE@"
      hostNetwork: true
      restartPolicy: Never
      tolerations:
        - operator: Exists
      containers:
        - name: tb-reset
          image: mirror.gcr.io/alpine:latest
          securityContext:
            privileged: true
          env:
            - name: DOMAIN
              value: "{{ domain }}"
            - name: MODE
              value: "{{ mode }}"
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -eu
              DRV=/sys/bus/pci/drivers/thunderbolt
              TB=/sys/bus/thunderbolt/devices

              if [ "$DOMAIN" = "all" ]; then
                  targets=""
                  for entry in "$DRV"/????:??:??.?; do
                      [ -e "$entry" ] || continue
                      targets="$targets $(basename "$entry")"
                  done
                  want="\-1$"
              else
                  link="$TB/domain$DOMAIN"
                  [ -e "$link" ] || { echo "domain$DOMAIN not present on this host"; exit 1; }
                  targets="$(basename "$(dirname "$(readlink -f "$link")")")"
                  want="^$DOMAIN-1$"
              fi
              [ -n "${targets# }" ] || { echo "no thunderbolt host controllers bound"; exit 1; }

              echo "==> host controllers:$targets  mode=$MODE"
              echo "==> before"; ls -1 "$TB"

              for bdf in $targets; do
                  if [ "$MODE" = "pci" ]; then
                      echo "--> pci remove $bdf"; echo 1 > "/sys/bus/pci/devices/$bdf/remove"
                  else
                      echo "--> unbind $bdf"; echo "$bdf" > "$DRV/unbind"
                  fi
              done

              sleep 3

              if [ "$MODE" = "pci" ]; then
                  echo "--> pci rescan"; echo 1 > /sys/bus/pci/rescan
              else
                  for bdf in $targets; do
                      echo "--> bind $bdf"; echo "$bdf" > "$DRV/bind"
                  done
              fi

              echo "==> waiting up to 60s for XDomain re-discovery"
              i=0
              while [ "$i" -lt 30 ]; do
                  sleep 2
                  if ls -1 "$TB" 2>/dev/null | grep -qE "$want"; then break; fi
                  i=$((i + 1))
              done

              echo "==> after"; ls -1 "$TB"
              for path in /sys/class/net/*; do
                  [ -L "$path/device/driver" ] || continue
                  case "$(readlink "$path/device/driver")" in
                      */thunderbolt-net) ;;
                      *) continue ;;
                  esac
                  echo "    $(basename "$path") operstate=$(cat "$path/operstate") carrier=$(cat "$path/carrier" 2>/dev/null || echo none)"
              done
    EOF
    kubectl -n default logs -f pod/"$pod" --pod-running-timeout=2m
    kubectl -n default wait pod/"$pod" --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s
    just talos tb-status {{ node }}

[confirm('Upgrade Kubernetes to ' + version + ' [y|N] ?')]
[doc('Upgrade Kubernetes version on the cluster')]
upgrade-k8s version:
    talosctl -n "$(talosctl config info -o yaml | yq -e '.endpoints[0]')" upgrade-k8s --to {{ version }}

[confirm('Upgrade node ' + node + ' [y|N] ?')]
[doc('Upgrade Talos version on a node')]
upgrade-node node *args:
    talosctl -n "{{ node }}" upgrade -i "$(just talos machine-image)" -m powercycle --timeout=10m {{ args }}

[doc('Generate a Talos schematic')]
[script]
schematic-id:
    export CONFIG_EARLY="$(just talos config-early)"
    curl -sX POST --data-binary @<(just template "{{ source_directory() }}/schematic.yaml.j2") "https://factory.talos.dev/schematics" | jq -r '.id'

[private]
machine-hostname node:
    just template "{{ source_directory() }}/nodes/{{ node }}.yaml.j2" | yq -e 'select(.kind == "HostnameConfig") | .hostname'

[private]
machine-controller node:
    just template "{{ source_directory() }}/nodes/{{ node }}.yaml.j2" | yq -e 'select(.machine) | (.machine.type == "controlplane") // ""'

[private]
[script]
machine-image:
    export SCHEMATIC="$(just talos schematic-id)"
    just template "{{ source_directory() }}/machineconfig.yaml.j2" | yq -e 'select(.machine) | .machine.install.image'

[private]
config-early:
    just template "{{ source_directory() }}/networking.yaml.j2" | zstd --compress --ultra -22 | base64 -w 0
