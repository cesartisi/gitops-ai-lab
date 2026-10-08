param([switch]$MostrarSenha)

$ErrorActionPreference = 'Stop'
$labRoot = Split-Path $PSScriptRoot -Parent
$labState = Join-Path $labRoot '.lab-local'
$dockerBins = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\resources\bin'),
    (Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin')
) | Where-Object { Test-Path $_ }
$env:Path = (@((Join-Path $labState 'bin')) + $dockerBins + @($env:Path)) -join ';'
$env:KUBECONFIG = Join-Path $labState 'kubeconfig'
if (!(Test-Path $env:KUBECONFIG)) { throw 'Kubeconfig local ausente. Crie primeiro o cluster gitops-lab.' }
$kubectl = (Get-Command kubectl -ErrorAction Stop).Source
& $kubectl --context kind-gitops-lab get nodes
if ($LASTEXITCODE -ne 0) { throw 'Cluster indisponivel. Inicie o Docker Desktop e tente novamente.' }

$forwards = @(
    @{Name='argocd'; Namespace='argocd'; Service='argocd-server'; Port=8080; Target=443},
    @{Name='staging'; Namespace='embedding-api-staging'; Service='embedding-api'; Port=9000; Target=80},
    @{Name='prod'; Namespace='embedding-api-prod'; Service='embedding-api'; Port=9001; Target=80}
)
foreach ($forward in $forwards) {
    $listeners = @(Get-NetTCPConnection -LocalPort $forward.Port -State Listen -ErrorAction SilentlyContinue)
    if ($listeners.Count -gt 0) {
        foreach ($listener in $listeners) {
            $owner = Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)"
            if ($owner.Name -ne 'kubectl.exe' -or $owner.CommandLine -notmatch 'kind-gitops-lab' -or $owner.CommandLine -notmatch $forward.Namespace) {
                throw "Porta $($forward.Port) ocupada por outro processo."
            }
        }
        continue
    }
    $name = $forward.Name
    $process = Start-Process -FilePath $kubectl -ArgumentList @('--context','kind-gitops-lab','-n',$forward.Namespace,'port-forward',"svc/$($forward.Service)","$($forward.Port):$($forward.Target)",'--address','127.0.0.1') -WindowStyle Hidden -PassThru -RedirectStandardOutput "$labState\$name.stdout.log" -RedirectStandardError "$labState\$name.stderr.log"
    $process.Id | Set-Content "$labState\$name.pid"
    $ready = $false
    for ($attempt=0; $attempt -lt 20; $attempt++) {
        if (Get-NetTCPConnection -LocalPort $forward.Port -State Listen -ErrorAction SilentlyContinue) { $ready=$true; break }
        if ($process.HasExited) { throw "Falha no port-forward $name. Consulte .lab-local/$name.stderr.log." }
        Start-Sleep -Milliseconds 500
    }
    if (!$ready) { throw "Timeout no port-forward $name." }
}
Write-Host 'Argo CD: https://localhost:8080 (usuario: admin)'
Write-Host 'Staging: http://localhost:9000/info'
Write-Host 'Producao: http://localhost:9001/info'
if ($MostrarSenha) {
    $raw = & $kubectl --context kind-gitops-lab -n argocd get secret argocd-initial-admin-secret -o json
    if ($LASTEXITCODE -ne 0) { throw 'Nao foi possivel obter a senha inicial.' }
    $secret = $raw | ConvertFrom-Json
    Write-Host ('Senha inicial: ' + [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($secret.data.password)))
}
