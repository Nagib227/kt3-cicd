Set-Location (Split-Path -Parent $PSScriptRoot)
. "$PSScriptRoot\lib.ps1"

function Reset-Project([string]$Name) {
    try {
        $existing = Get-ProjectId "root/$Name"
        Invoke-GitlabApi -Method DELETE -ApiPath "/projects/$existing" | Out-Null
        Start-Sleep -Seconds 2
    } catch {
        if ($_.Exception.Message -notmatch "404") { throw }
    }
    return New-GitlabProject $Name
}

function New-AppActions([string]$Mode, [string]$TestPath) {
    $root = Join-Path $script:Root "campus-app"
    $files = @(
        @{ path = "app.py"; file = (Join-Path $root "app.py") },
        @{ path = "test_app.py"; file = $TestPath },
        @{ path = "Dockerfile"; file = (Join-Path $root "Dockerfile") },
        @{ path = ".dockerignore"; file = (Join-Path $root ".dockerignore") },
        @{ path = ".gitlab-ci.yml"; file = (Join-Path $root ".gitlab-ci.yml") },
        @{ path = "k8s/deployment.yaml"; file = (Join-Path $root "k8s\deployment.yaml") },
        @{ path = "k8s/service.yaml"; file = (Join-Path $root "k8s\service.yaml") }
    )
    $actions = @()
    foreach ($item in $files) {
        $actions += New-FileAction $item.path $item.file $Mode
    }
    return $actions
}

$projectId = Reset-Project "campus-app"
$broken = Join-Path $script:Local "test_app_broken.py"
$good = [System.IO.File]::ReadAllText((Join-Path $script:Root "campus-app\test_app.py"))
$bad = $good.Replace("self.assertTrue(app.ready())", "self.assertFalse(app.ready())")
[System.IO.File]::WriteAllText($broken, $bad, [Text.UTF8Encoding]::new($false))

$before = Get-LatestPipeline $projectId
$beforeId = if ($before) { [string]$before.id } else { "" }
Send-Commit $projectId "Break the ready test on purpose" (New-AppActions "create" $broken) | Out-Null
$failed = Wait-NewPipeline $projectId $beforeId
$failedRun = Wait-Pipeline $projectId ([string]$failed.id)
$failedJobs = Save-PipelineEvidence $projectId ([string]$failed.id) "part1-red"
if ($failedRun.status -ne "failed") { throw "broken test did not fail the pipeline: $($failedRun.status)" }
$build = @($failedJobs | Where-Object { $_.name -eq "build" })
if ($build.Count -lt 1 -or $build[0].status -ne "skipped") { throw "build was not skipped after the broken test" }
Write-Host "red pipeline $($failed.id) blocked the build"

$beforeId = [string]$failed.id
Send-Commit $projectId "Restore the ready test" (New-AppActions "update" (Join-Path $script:Root "campus-app\test_app.py")) | Out-Null
$green = Wait-NewPipeline $projectId $beforeId
$greenRun = Wait-Pipeline $projectId ([string]$green.id)
Save-PipelineEvidence $projectId ([string]$green.id) "part1-green" | Out-Null
if ($greenRun.status -ne "success") { throw "green pipeline failed: $($greenRun.status)" }

$image = & kubectl --context kind-campus -n campus-board get deployment campus-api -o jsonpath="{.spec.template.spec.containers[0].image}"
Assert-Last "get deployed image"
$sha = [string]$green.sha
if ($image -notmatch [regex]::Escape($sha)) { throw "running image '$image' does not contain commit $sha" }
$pod = & kubectl --context kind-campus -n campus-board get pod -l app=campus-api -o jsonpath="{.items[0].metadata.name}"
$smoke = & kubectl --context kind-campus -n campus-board exec $pod -- python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/ready').read().decode())"
Assert-Last "smoke"
$stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$deployed = @"
Дата: $stamp
Команда: kubectl get deployment campus-api -n campus-board
Ожидание: образ с тегом commit $sha
Факт: $image
Smoke: $smoke
Вывод: пайплайн сам выложил образ
"@
[System.IO.File]::WriteAllText((Join-Path $script:Evidence "part1-deployed.txt"), $deployed, [Text.UTF8Encoding]::new($false))

Write-Host "experiment 1: manual image change must stay"
$started = Get-Date
Invoke-Kube -n campus-board set image deployment/campus-api api=localhost:5001/campus-api:manual-drift
Start-Sleep -Seconds 90
$drift = & kubectl --context kind-campus -n campus-board get deployment campus-api -o jsonpath="{.spec.template.spec.containers[0].image}"
Assert-Last "read drifted image"
if ($drift -ne "localhost:5001/campus-api:manual-drift") { throw "push model repaired the drift: $drift" }
$exp1 = @"
Дата: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Команда: kubectl set image deployment/campus-api api=localhost:5001/campus-api:manual-drift -n campus-board
Ожидание: через 90 секунд ручная правка остаётся, контроллер её не откатывает
Старт: $($started.ToString("HH:mm:ss"))
Образ до эксперимента: $image
Образ через 90 секунд: $drift
Вывод: расхождение осталось. В push-модели кластер сам не возвращается к желаемому состоянию.
"@
[System.IO.File]::WriteAllText((Join-Path $script:Evidence "experiment1.txt"), $exp1, [Text.UTF8Encoding]::new($false))
Write-Host "experiment 1 recorded"
