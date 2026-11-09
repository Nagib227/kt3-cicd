Set-Location (Split-Path -Parent $PSScriptRoot)
. "$PSScriptRoot\lib.ps1"

$commits = Get-Content -Raw (Join-Path $script:Evidence "part2-config-commits.json") | ConvertFrom-Json
if ($commits -isnot [System.Array]) { $commits = @($commits) }
$promo = $commits | Where-Object { $_.title -like "Promote campus-api*" } | Select-Object -First 1
if (-not $promo) { throw "promotion commit is missing" }

Invoke-Kube apply -k (Join-Path $script:Root "infra\argocd")
$patch = Join-Path $script:Local "argocd-cm.json"
[System.IO.File]::WriteAllText($patch, '{"data":{"timeout.reconciliation":"15s"}}', [Text.UTF8Encoding]::new($false))
& kubectl --context kind-campus -n argocd patch configmap argocd-cm --type merge --patch-file $patch
Assert-Last "argocd reconciliation interval"
& kubectl --context kind-campus -n argocd rollout status deployment/argocd-repo-server --timeout=300s
Assert-Last "argocd repo server"
& kubectl --context kind-campus -n argocd rollout status deployment/argocd-redis --timeout=180s
Assert-Last "argocd redis"
& kubectl --context kind-campus -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
Assert-Last "argocd controller"

Invoke-Kube apply -f (Join-Path $script:Root "infra\argocd\application.yaml")
$synced = $false
for ($i = 0; $i -lt 40; $i++) {
    $sync = & kubectl --context kind-campus -n argocd get application campus-api -o jsonpath="{.status.sync.status}"
    $health = & kubectl --context kind-campus -n argocd get application campus-api -o jsonpath="{.status.health.status}"
    Write-Host "argocd $sync $health"
    if ($sync -eq "Synced" -and $health -eq "Healthy") { $synced = $true; break }
    Start-Sleep -Seconds 10
}
if (-not $synced) { throw "ArgoCD did not reach Synced/Healthy" }
$good = & kubectl --context kind-campus -n campus-board get deployment campus-api -o jsonpath="{.spec.template.spec.containers[0].image}"
Assert-Last "desired image"
$status = @"
Дата: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Application: campus-api
Sync: Synced
Health: Healthy
Образ: $good
Config commit: $($promo.short_id) $($promo.title)
"@
[System.IO.File]::WriteAllText((Join-Path $script:Evidence "argocd-status.txt"), $status, [Text.UTF8Encoding]::new($false))

Write-Host "experiment 2: the same manual image change must be repaired"
$started = Get-Date
$sawDrift = $false
$sawOut = $false
$log = New-Object System.Collections.Generic.List[string]
Invoke-Kube -n campus-board set image deployment/campus-api api=localhost:5001/campus-api:manual-drift
for ($i = 0; $i -lt 40; $i++) {
    $imageNow = & kubectl --context kind-campus -n campus-board get deployment campus-api -o jsonpath="{.spec.template.spec.containers[0].image}"
    $sync = & kubectl --context kind-campus -n argocd get application campus-api -o jsonpath="{.status.sync.status}"
    $line = "{0} image={1} sync={2}" -f (Get-Date -Format "HH:mm:ss"), $imageNow, $sync
    $log.Add($line)
    Write-Host $line
    if ($imageNow -eq "localhost:5001/campus-api:manual-drift") { $sawDrift = $true }
    if ($sync -eq "OutOfSync") { $sawOut = $true }
    if ($sawDrift -and $imageNow -eq $good -and $sync -eq "Synced") { break }
    Start-Sleep -Seconds 5
}
if (-not $sawDrift) { throw "manual drift was not observed" }
$final = & kubectl --context kind-campus -n campus-board get deployment campus-api -o jsonpath="{.spec.template.spec.containers[0].image}"
if ($final -ne $good) { throw "ArgoCD did not restore the image. Now: $final expected: $good" }
$exp2 = @"
Дата: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Команда: kubectl set image deployment/campus-api api=localhost:5001/campus-api:manual-drift -n campus-board
Ожидание: ArgoCD видит расхождение и возвращает образ из Git
Старт: $($started.ToString("HH:mm:ss"))
Конец: $(Get-Date -Format "HH:mm:ss")
Образ из Git: $good
Ручная правка замечена: $sawDrift
OutOfSync замечен: $sawOut
Образ после восстановления: $final

Журнал:
$($log -join "`n")

Вывод: то же вмешательство, что в эксперименте 1. На этот раз контроллер сам вернул желаемое состояние.
"@
[System.IO.File]::WriteAllText((Join-Path $script:Evidence "experiment2.txt"), $exp2, [Text.UTF8Encoding]::new($false))
Write-Host "experiment 2 recorded"
