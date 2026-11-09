# КТ3. CI/CD и GitOps

Локальный стенд CampusBoard: один kind-кластер, GitLab CE Omnibus в одном поде, GitLab Runner с Kubernetes executor, registry `kind-registry` и Argo CD core без веб-интерфейса. Облачный кластер не использовался. У Docker около 8 ГБ памяти, поэтому выбран один под Omnibus, а не набор подов Helm-чарта.

## Push и pull

Один и тот же приём: `kubectl set image deployment/campus-api api=localhost:5001/campus-api:manual-drift -n campus-board`.

В части 1 пайплайн сам делает `kubectl set image`. После ручной подмены образ `manual-drift` остался на месте 90 секунд, с 12:31:18 до 12:32:48. Контроллера, который вернул бы желаемое состояние, нет. Это push-модель: кластер хранит то, что в него последний раз записали, и сам с Git не сверяется.

В части 2 пайплайн больше не вызывает kubectl. Роль на выкладку у раннера снята. Job `promote` только коммитит digest в `campus-config`. Argo CD читает этот репозиторий. Та же подмена в 12:50:19 дала `OutOfSync`, в 12:50:24 образ снова стал `localhost:5001/campus-api@sha256:f8009d301996af9364c3dc3950d2f4933348496c27cd36acec9b2ee8ea3cc2ca`, статус `Synced`. Это pull-модель: желаемое состояние лежит в Git, а контроллер возвращает к нему живой кластер.

## Что стоит в кластере

| Часть | Где |
| --- | --- |
| GitLab CE 17.11.7, один под | namespace `gitlab`, http://gitlab.local:8929 |
| Runner 17.11.4, Kubernetes executor | namespace `gitlab-runner` |
| Registry | `kind-registry:5000` внутри сети kind, с хоста `127.0.0.1:5001` |
| Приложение | namespace `campus-board`, Deployment `campus-api` |
| Argo CD 2.13.5 core | namespace `argocd`, Application `campus-api` |

Репозитории внутри GitLab: `root/campus-app` и `root/campus-config`. Образ собирает kaniko, не `docker build` на хосте. В GitOps-конфиге образ записан digest, не тегом `latest`.

Пароль root и токен раннера лежат только в `.local/` и в Secret кластера. В Git и в журнал они не входят.

## Журнал

| Файл | Что доказывает |
| --- | --- |
| `evidence/part1-red-test.txt` | тест `test_ready` упал: `True is not false` |
| `evidence/part1-red-jobs.txt` | `build` и `deploy` получили `skipped` |
| `evidence/part1-green-build.txt` | kaniko отправил образ в registry |
| `evidence/part1-green-deploy.txt` | пайплайн выполнил `kubectl set image` |
| `evidence/part1-deployed.txt` | в кластере тег commit `22830c4f7075e8f114dfd947672deb8f5335460b`, `/ready` ответил |
| `evidence/experiment1.txt` | ручной тег остался без самовосстановления |
| `evidence/part2-jobs.txt` | есть `test`, `build`, `promote`, job `deploy` нет |
| `evidence/part2-config-diff.json` | коммит меняет только digest |
| `evidence/argocd-status.txt` | `Synced` и `Healthy` |
| `evidence/experiment2.txt` | `OutOfSync`, затем возврат digest за несколько секунд |

Digest части 1, который запушил kaniko: `sha256:7c42e0fa441161ef881e534f6d46eb366ba94e6a6f9cc3e1e6927345f72eef81`. Digest, который CI закоммитил в config-repo: `sha256:f8009d301996af9364c3dc3950d2f4933348496c27cd36acec9b2ee8ea3cc2ca`. Config commit `b5f544a6`.

## Как открыть стенд

Кластер `kind-campus`. API с этой машины доступен как `https://127.0.0.1:16443`: порт `59160` из старого kubeconfig попал в исключённый диапазон Windows, поэтому рядом работает прокси `kind-api-proxy`.

GitLab с хоста:

```powershell
kubectl -n gitlab port-forward svc/gitlab 8929:8929
```

В `C:\Windows\System32\drivers\etc\hosts` нужна строка `127.0.0.1 gitlab.local`. Без прав администратора файл не изменился. Логин `root`, пароль в `kt3-cicd\.local\gitlab-root.txt`.

Повторить стенд: `ci\01-gitlab.ps1`, затем `ci\02-part1.ps1`, затем `ci\03-part2.ps1`. Каталог `.local/` скрипты создают сами.

Убрать стенд, не трогая кластер целиком:

```powershell
kubectl delete ns gitlab gitlab-runner campus-board argocd
docker rm -f kind-api-proxy
```

`kind delete cluster --name campus` удалит и стенд КТ2 в том же кластере.

## Что ещё нужно

Сделан локальный контур на 25 баллов: тесты блокируют сборку, kaniko, push-деплой, config-repo, Argo CD и оба эксперимента. До максимума этой шкалы не хватает только защиты: стенд надо показать преподавателю. Сам репозиторий оценку «продемонстрировано» не ставит.

До большой контрольной на 100 баллов в этом проекте нет следующего.

- Отдельные среды `dev` и `stage`. Сейчас один namespace `campus-board`.
- Promotion через pull request: ветка, review, CODEOWNERS, merge. Сейчас CI пушит в `main` config-repo напрямую.
- Полный DAG: lint, integration, secret scan и policy на запросе; на основной ветке scan, SBOM, provenance и подпись. Сейчас есть unit-тест, kaniko и promote.
- Один digest, проверенный до выкладки, в обеих средах. Сборка для GitOps идёт заново и даёт другой digest, чем push-прогон.
- Подпись образа и проверка подписи до promotion. Неподписанный digest ничем не блокируется.
- OIDC и короткая cloud identity. В кластере нет отказа чужой ветке и нет разделения прав verify и package.
- Секреты вне Git через Lockbox или аналог. Сейчас пароль GitLab только в локальном файле и Secret кластера.
- Drift с безопасной меткой, отдельный случай Synced и Degraded, и prune объекта, удалённого из Git. Есть только возврат образа.
- Canary или blue-green: порог, окно, abort и revert commit. `kubectl set image` на плохой тег не считается таким релизом.
- Журнал T01–T12 большой контрольной: run id, approver, analysis window, время обнаружения и восстановления, оценка затрат и cleanup.
- Managed PostgreSQL. API базы не использует.
- Метрики и логи, по которым принимается решение о релизе.
- Публичный стенд. Ссылки GitHub открывают код и журнал, не работающее приложение.

## Ограничения стенда

Плата 0, кластер один и локальный. Зеркало `cr.yandex` не отдало `argocd:v2.13.5`, поэтому контроллер взят с `quay.io/argoproj/argocd:v2.13.5`, Redis с `mirror.gcr.io`. Argo CD без UI. Один узел kind не показывает отказ ноды.
