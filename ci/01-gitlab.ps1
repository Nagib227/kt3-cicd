Set-Location (Split-Path -Parent $PSScriptRoot)
. "$PSScriptRoot\lib.ps1"

$registryNet = docker inspect kind-registry --format "{{range `$k, `$v := .NetworkSettings.Networks}}{{`$k}} {{end}}"
if ($registryNet -notmatch "kind") {
    docker network connect kind kind-registry
    Assert-Last "connect registry to kind"
}

$image = docker exec campus-control-plane ctr -n k8s.io images ls
if (($image -join "`n") -notmatch "gitlab-ce:17.11.7-ce.0") {
    Write-Output "pulling gitlab image"
    docker exec campus-control-plane ctr -n k8s.io images pull docker.io/gitlab/gitlab-ce:17.11.7-ce.0
    Assert-Last "pull gitlab"
}

$passFile = Join-Path $script:Local "gitlab-root.txt"
if (-not (Test-Path $passFile)) {
    $chars = ([char[]](48..57 + 65..90 + 97..122))
    $pass = -join (1..24 | ForEach-Object { $chars | Get-Random })
    [System.IO.File]::WriteAllText($passFile, $pass, [Text.UTF8Encoding]::new($false))
}
$pass = (Get-Content -Raw $passFile).Trim()
$template = Get-Content -Raw "infra\omnibus.rb.template"
$config = $template.Replace("ROOT_PASSWORD", $pass)
$configPath = Join-Path $script:Local "omnibus.rb"
[System.IO.File]::WriteAllText($configPath, $config, [Text.UTF8Encoding]::new($false))

Invoke-Kube apply -f "infra\rbac.yaml"
Invoke-Kube create namespace gitlab --dry-run=client -o yaml | kubectl --context kind-campus apply -f -
Assert-Last "namespace gitlab"
& kubectl --context kind-campus -n gitlab create secret generic gitlab-omnibus-config --from-file=config=$configPath --dry-run=client -o yaml | kubectl --context kind-campus apply -f -
Assert-Last "gitlab secret"
Invoke-Kube apply -f "infra\gitlab.yaml"

$ip = & kubectl --context kind-campus -n gitlab get svc gitlab -o jsonpath="{.spec.clusterIP}"
Assert-Last "gitlab cluster ip"
Set-CoreDnsHost $ip
Ensure-HostsLine

Write-Output "waiting for GitLab readiness"
Invoke-Kube -n gitlab rollout status deployment/gitlab --timeout=1500s

$ruby = @'
user = User.find_by_username("root")
raise "root user is missing" if user.nil?
PersonalAccessToken.where(user_id: user.id, name: "lab").update_all(revoked: true)
raw = "glpat-" + SecureRandom.hex(20)
pat = PersonalAccessToken.new(user: user, name: "lab", scopes: ["api", "read_repository", "write_repository"], expires_at: 30.days.from_now)
pat.set_token(raw)
pat.save!
File.write("/tmp/lab-token", raw)
'@
$rubyPath = Join-Path $script:Local "token.rb"
[System.IO.File]::WriteAllText($rubyPath, $ruby, [Text.UTF8Encoding]::new($false))
Send-PodFile $rubyPath "/tmp/token.rb"
$pod = Get-GitlabPod
& kubectl --context kind-campus -n gitlab exec $pod -c gitlab -- gitlab-rails runner /tmp/token.rb
Assert-Last "create gitlab token"
$tokenPath = Join-Path $script:Local "gitlab-token.txt"
Receive-PodFile "/tmp/lab-token" $tokenPath
& kubectl --context kind-campus -n gitlab exec $pod -c gitlab -- rm -f /tmp/lab-token /tmp/token.rb | Out-Null
$token = (Get-Content -Raw $tokenPath).Trim()
if ($token -notmatch "^glpat-") { throw "GitLab token was not created" }

$runnerBody = Join-Path $script:Local "runner.json"
Write-LabJson $runnerBody @{
    runner_type = "instance_type"
    description = "kubernetes"
    run_untagged = $true
    locked = $false
}
$runnerRaw = Invoke-GitlabApi -Method POST -ApiPath "/user/runners" -BodyFile $runnerBody
$runner = $runnerRaw | ConvertFrom-Json
$runnerToken = [string]$runner.token
if (-not $runnerToken) { throw "runner token missing" }
[System.IO.File]::WriteAllText((Join-Path $script:Local "runner-token.txt"), $runnerToken, [Text.UTF8Encoding]::new($false))

$toml = @"
concurrent = 1
check_interval = 5
state_file = "/tmp/runner-state"

[[runners]]
  name = "kubernetes"
  url = "http://gitlab.local:8929"
  token = "$runnerToken"
  executor = "kubernetes"
  [runners.kubernetes]
    namespace = "gitlab-runner"
    image = "mirror.gcr.io/library/python:3.13-slim"
    service_account = "gitlab-runner"
    poll_timeout = 600
    cpu_request = "100m"
    memory_request = "128Mi"
    memory_limit = "1280Mi"
    privileged = false
    pull_policy = ["if-not-present"]
"@
$tomlPath = Join-Path $script:Local "config.toml"
[System.IO.File]::WriteAllText($tomlPath, $toml, [Text.UTF8Encoding]::new($false))
& kubectl --context kind-campus -n gitlab-runner create secret generic gitlab-runner-config --from-file=config.toml=$tomlPath --dry-run=client -o yaml | kubectl --context kind-campus apply -f -
Assert-Last "runner secret"
Invoke-Kube apply -f "infra\runner.yaml"
Invoke-Kube -n gitlab-runner rollout status deployment/gitlab-runner --timeout=180s

$images = @(
    "docker.io/gitlab/gitlab-runner:alpine-v17.11.4",
    "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:x86_64-v17.11.4",
    "mirror.gcr.io/library/python:3.13-slim",
    "mirror.gcr.io/library/alpine:3.20",
    "gcr.io/kaniko-project/executor:v1.23.2-debug"
)
foreach ($img in $images) {
    Write-Output "pull $img"
    docker exec campus-control-plane ctr -n k8s.io images pull $img
    Assert-Last "pull $img"
}

Write-Output "gitlab and runner are ready"
