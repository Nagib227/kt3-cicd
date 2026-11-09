$ErrorActionPreference = "Continue"
$script:Root = Split-Path -Parent $PSScriptRoot
$script:Local = Join-Path $script:Root ".local"
$script:Evidence = Join-Path $script:Root "evidence"
New-Item -ItemType Directory -Force -Path $script:Local, $script:Evidence | Out-Null

function Assert-Last([string]$What) {
    if ($LASTEXITCODE -ne 0) { throw "$What failed with exit $LASTEXITCODE" }
}

function Invoke-Kube {
    & kubectl --context kind-campus @args
    Assert-Last "kubectl $($args -join ' ')"
}

function Redact([string]$Text) {
    if (-not $Text) { return "" }
    $Text = $Text -replace "glpat-[A-Za-z0-9_\-]+", "glpat-REDACTED"
    $Text = $Text -replace "glrt-[A-Za-z0-9_\-]+", "glrt-REDACTED"
    $Text = $Text -replace "PRIVATE-TOKEN: \S+", "PRIVATE-TOKEN: REDACTED"
    $Text = $Text -replace "root:[^@\s]+@", "root:REDACTED@"
    return $Text
}

function Get-GitlabPod {
    $name = & kubectl --context kind-campus -n gitlab get pod -l app=gitlab -o jsonpath="{.items[0].metadata.name}"
    Assert-Last "get gitlab pod"
    if (-not $name) { throw "GitLab pod not found" }
    return $name
}

function Send-PodFile([string]$LocalPath, [string]$RemotePath) {
    $pod = Get-GitlabPod
    & cmd.exe /c "kubectl --context kind-campus -n gitlab exec -i $pod -c gitlab -- sh -c `"cat > $RemotePath`" < `"$LocalPath`""
    Assert-Last "copy to $RemotePath"
}

function Receive-PodFile([string]$RemotePath, [string]$LocalPath) {
    $pod = Get-GitlabPod
    $text = & kubectl --context kind-campus -n gitlab exec $pod -c gitlab -- cat $RemotePath
    Assert-Last "read $RemotePath"
    if ($null -eq $text) { $text = "" }
    if ($text -is [System.Array]) { $text = $text -join "`n" }
    [System.IO.File]::WriteAllText($LocalPath, ([string]$text).TrimEnd() + "`n", [Text.UTF8Encoding]::new($false))
}

function Get-LabToken {
    return (Get-Content -Raw (Join-Path $script:Local "gitlab-token.txt")).Trim()
}

function Invoke-GitlabApi {
    param(
        [string]$Method,
        [string]$ApiPath,
        [string]$BodyFile
    )
    $token = Get-LabToken
    $pod = Get-GitlabPod
    $curl = "curl -sS -o /tmp/api-out -w '%{http_code}' -X $Method -H 'Host: gitlab.local:8929' -H 'PRIVATE-TOKEN: $token'"
    if ($BodyFile) {
        Send-PodFile $BodyFile "/tmp/api-body.json"
        $curl += " -H 'Content-Type: application/json' --data-binary @/tmp/api-body.json"
    }
    $curl += " 'http://127.0.0.1:8929/api/v4$ApiPath' > /tmp/api-code"
    $sh = Join-Path $script:Local "api.sh"
    [System.IO.File]::WriteAllText($sh, "set -eu`n$curl`n", [Text.UTF8Encoding]::new($false))
    Send-PodFile $sh "/tmp/api.sh"
    & kubectl --context kind-campus -n gitlab exec $pod -c gitlab -- sh /tmp/api.sh
    Assert-Last "gitlab api $Method $ApiPath"
    $codeFile = Join-Path $script:Local "api-code"
    if (Test-Path $codeFile) { Remove-Item $codeFile -Force }
    Receive-PodFile "/tmp/api-code" $codeFile
    $code = (Get-Content -Raw $codeFile).Trim()
    $out = Join-Path $script:Local "api-out"
    if (Test-Path $out) { Remove-Item $out -Force }
    Receive-PodFile "/tmp/api-out" $out
    $body = ""
    if (Test-Path $out) { $body = [System.IO.File]::ReadAllText($out) }
    if ($code -notmatch "^2") {
        throw "GitLab API $Method $ApiPath -> $code`n$(Redact $body)"
    }
    return $body
}

function ConvertTo-LabJson($Object) {
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $ser.MaxJsonLength = 20000000
    $ser.RecursionLimit = 20
    return $ser.Serialize($Object)
}

function Write-LabJson([string]$Path, $Object) {
    $json = ConvertTo-LabJson $Object
    [System.IO.File]::WriteAllText($Path, $json, [Text.UTF8Encoding]::new($false))
}

function Get-ProjectId([string]$Path) {
    $encoded = [uri]::EscapeDataString($Path)
    $raw = Invoke-GitlabApi -Method GET -ApiPath "/projects/$encoded"
    $obj = $raw | ConvertFrom-Json
    return [string]$obj.id
}

function New-GitlabProject([string]$Name) {
    $bodyPath = Join-Path $script:Local "project.json"
    Write-LabJson $bodyPath @{
        name = $Name
        path = $Name
        visibility = "public"
        initialize_with_readme = $false
        default_branch = "main"
    }
    try {
        $raw = Invoke-GitlabApi -Method POST -ApiPath "/projects" -BodyFile $bodyPath
        $obj = $raw | ConvertFrom-Json
        return [string]$obj.id
    } catch {
        if ($_.Exception.Message -match "has already been taken") {
            return Get-ProjectId "root/$Name"
        }
        throw
    }
}

function Send-Commit([string]$ProjectId, [string]$Message, $Actions) {
    $bodyPath = Join-Path $script:Local "commit.json"
    Write-LabJson $bodyPath @{
        branch = "main"
        commit_message = $Message
        actions = $Actions
    }
    $raw = Invoke-GitlabApi -Method POST -ApiPath "/projects/$ProjectId/repository/commits" -BodyFile $bodyPath
    return ($raw | ConvertFrom-Json)
}

function New-FileAction([string]$RepoPath, [string]$LocalPath, [string]$Action) {
    $content = [System.IO.File]::ReadAllText($LocalPath)
    return @{ action = $Action; file_path = $RepoPath; content = $content }
}

function Wait-Pipeline([string]$ProjectId, [string]$PipelineId) {
    for ($i = 0; $i -lt 150; $i++) {
        $raw = Invoke-GitlabApi -Method GET -ApiPath "/projects/$ProjectId/pipelines/$PipelineId"
        $obj = $raw | ConvertFrom-Json
        Write-Host "pipeline $PipelineId $($obj.status)"
        if ($obj.status -in @("success", "failed", "canceled", "skipped")) { return $obj }
        Start-Sleep -Seconds 10
    }
    throw "pipeline $PipelineId timed out"
}

function Get-LatestPipeline([string]$ProjectId) {
    $raw = Invoke-GitlabApi -Method GET -ApiPath "/projects/$ProjectId/pipelines?per_page=1"
    if (-not $raw -or $raw.Trim() -eq "[]") { return $null }
    $arr = $raw | ConvertFrom-Json
    if ($null -eq $arr) { return $null }
    if ($arr -isnot [System.Array]) { $arr = @($arr) }
    return $arr[0]
}

function Wait-NewPipeline([string]$ProjectId, [string]$BeforeId) {
    for ($i = 0; $i -lt 30; $i++) {
        $next = Get-LatestPipeline $ProjectId
        if ($next -and [string]$next.id -ne $BeforeId) { return $next }
        Start-Sleep -Seconds 3
    }
    throw "no new pipeline appeared"
}

function Save-PipelineEvidence([string]$ProjectId, [string]$PipelineId, [string]$Prefix) {
    $raw = Invoke-GitlabApi -Method GET -ApiPath "/projects/$ProjectId/pipelines/$PipelineId/jobs"
    $jobs = $raw | ConvertFrom-Json
    if ($jobs -isnot [System.Array]) { $jobs = @($jobs) }
    $summary = @()
    foreach ($job in $jobs) {
        $summary += "$($job.stage) $($job.name) $($job.status)"
        $trace = Invoke-GitlabApi -Method GET -ApiPath "/projects/$ProjectId/jobs/$($job.id)/trace"
        $file = Join-Path $script:Evidence "$Prefix-$($job.name).txt"
        [System.IO.File]::WriteAllText($file, (Redact $trace), [Text.UTF8Encoding]::new($false))
    }
    $sumFile = Join-Path $script:Evidence "$Prefix-jobs.txt"
    [System.IO.File]::WriteAllText($sumFile, ($summary -join "`n"), [Text.UTF8Encoding]::new($false))
    return $jobs
}

function Set-CoreDnsHost([string]$Ip) {
    $current = (& kubectl --context kind-campus -n kube-system get configmap coredns -o jsonpath="{.data.Corefile}") -join "`n"
    Assert-Last "read coredns"
    if ($current -match [regex]::Escape($Ip) -and $current -match "gitlab\.local") {
        & kubectl --context kind-campus -n kube-system rollout status deployment coredns --timeout=120s
        Assert-Last "coredns ready"
        return
    }
    $core = @"
.:53 {
    errors
    health {
       lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    hosts {
       $Ip gitlab.local
       fallthrough
    }
    prometheus :9153
    forward . /etc/resolv.conf {
       max_concurrent 1000
    }
    cache 30 {
       disable success cluster.local
       disable denial cluster.local
    }
    loop
    reload
    loadbalance
}
"@
    $path = Join-Path $script:Local "Corefile"
    [System.IO.File]::WriteAllText($path, $core.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    & kubectl --context kind-campus -n kube-system create configmap coredns --from-file=Corefile=$path --dry-run=client -o yaml | kubectl --context kind-campus apply -f -
    Assert-Last "apply coredns"
    & kubectl --context kind-campus -n kube-system rollout restart deployment coredns
    Assert-Last "restart coredns"
    & kubectl --context kind-campus -n kube-system rollout status deployment coredns --timeout=180s
    Assert-Last "coredns ready"
}

function Ensure-HostsLine {
    $hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
    $line = "127.0.0.1 gitlab.local"
    $text = Get-Content $hosts -ErrorAction SilentlyContinue
    if ($text -notcontains $line) {
        try {
            Add-Content -Path $hosts -Value $line -ErrorAction Stop
            Write-Output "hosts updated"
        } catch {
            Write-Output "hosts file was not changed: add '$line' yourself before opening the GitLab page"
        }
    }
}
