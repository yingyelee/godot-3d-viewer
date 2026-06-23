# Cloudflare Pages 部署脚本
# 用法:
#   1) 在 Godot 里:Project → Export → Web → Export Project,保存到 build/index.html
#   2) 双击运行此脚本(或者 powershell -File deploy_cloudflare.ps1)
#   3) 提交并推送到 GitHub,Cloudflare Pages 会自动部署

$ErrorActionPreference = "Stop"

$projectRoot = $PSScriptRoot
$buildDir    = Join-Path $projectRoot "build"
$headersSrc  = Join-Path $projectRoot "_headers"
$headersDst  = Join-Path $buildDir    "_headers"

# 1) 检查 build 目录里有没有 index.html
if (-not (Test-Path (Join-Path $buildDir "index.html"))) {
    Write-Host "[!] build/index.html 不存在" -ForegroundColor Red
    Write-Host "    请先在 Godot 里:Project > Export > Web > Export Project,保存到 build/index.html" -ForegroundColor Yellow
    exit 1
}

# 2) 拷贝 _headers 到 build 目录
if (-not (Test-Path $headersSrc)) {
    Write-Host "[!] 项目根目录没有 _headers 文件" -ForegroundColor Red
    exit 1
}
Copy-Item -Force $headersSrc $headersDst
Write-Host "[OK] 拷贝 _headers -> build/_headers" -ForegroundColor Green

# 3) 删除 .vercel 残留(之前是 Vercel 部署,避免 Cloudflare 误识别)
$vercelDir = Join-Path $buildDir ".vercel"
if (Test-Path $vercelDir) {
    Remove-Item -Recurse -Force $vercelDir
    Write-Host "[OK] 删除 build/.vercel 残留" -ForegroundColor Green
}
$vercelEnv = Join-Path $buildDir ".env.local"
if (Test-Path $vercelEnv) {
    Remove-Item -Force $vercelEnv
    Write-Host "[OK] 删除 build/.env.local 残留" -ForegroundColor Green
}

# 4) Git 提交 + 推送(可选)
Push-Location $projectRoot
try {
    $gitStatus = git status --porcelain 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[i] 当前目录不是 git 仓库,跳过提交" -ForegroundColor Yellow
    } elseif ([string]::IsNullOrWhiteSpace($gitStatus)) {
        Write-Host "[i] 没有改动需要提交" -ForegroundColor Yellow
    } else {
        $msg = Read-Host "请输入 commit 消息(直接回车用 'deploy: update build')"
        if ([string]::IsNullOrWhiteSpace($msg)) { $msg = "deploy: update build" }
        git add build _headers
        git commit -m $msg
        git push
        Write-Host "[OK] 已推送到 GitHub,Cloudflare Pages 会自动部署" -ForegroundColor Green
    }
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "===== 部署完成 =====" -ForegroundColor Cyan
Write-Host "Cloudflare Pages 控制台:https://dash.cloudflare.com/?to=/:account/pages" -ForegroundColor Cyan
