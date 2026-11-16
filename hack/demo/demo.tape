# Terminal recording of the lab demo for the README, rendered with vhs
# (https://github.com/charmbracelet/vhs).
#
# Render it with hack/demo/record.sh, not with vhs directly: the script checks
# the vhs version, runs vhs from the repository root (the Output paths below
# are relative to it) and exports KUBECONFIG and DEMO_CA_FILE for the demo
# cluster, which the recorded shell inherits.
#
# Recorded length: about one minute. Rendering takes as long as
# hack/demo/up.sh (cluster creation plus the Argo CD sync, which up.sh bounds
# with DEMO_TIMEOUT) plus one to two minutes for the visible commands and the
# video encoding. The long middle part of up.sh is not captured.
#
# Output goes to _out/ (build output); never commit it.

Output _out/demo/recording/demo.gif
Output _out/demo/recording/demo.mp4

Require kind
Require kubectl
Require curl

Set Shell "bash"
Set FontSize 16
Set Width 1400
Set Height 800
Set Padding 16
Set TypingSpeed 25ms

# 1. make demo: create the kind cluster and install the lab platform.
Type "hack/demo/up.sh"
Sleep 500ms
Enter
# Show the first steps (kind cluster, Calico), then stop capturing frames until
# the prompt returns. The timeout covers DEMO_TIMEOUT (default 1500 s) plus
# cluster creation; if it expires vhs fails and record.sh stops.
Sleep 20s
Hide
Wait+Line@45m />$/
Show
# The end of the up.sh output: summary and URLs.
Sleep 6s

Hide
Type "clear"
Enter
Show

# 2. Every Argo CD Application is Synced and Healthy.
Type "kubectl get applications -n argocd"
Sleep 500ms
Enter
Wait
Sleep 5s

# 3. hello-api in dev through the Gateway, TLS verified against the lab CA.
Type 'curl --cacert "$DEMO_CA_FILE" https://hello-api.dev.localtest.me/'
Sleep 500ms
Enter
Wait
Sleep 4s

# 4. Admission policy: a pod with a mutable image tag is denied in stage.
Type "kubectl -n stage run bad --image=nginx:latest --restart=Never"
Sleep 500ms
Enter
Wait
Sleep 6s
