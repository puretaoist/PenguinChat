<#
  QQ 协议线真机验证的一键入口（三段）

    .\tool\live_check.ps1 -Stage pack            # 离线干跑：组包 + 会话材料，不联网、不需要任何凭据
    .\tool\live_check.ps1 -Stage login           # 第一段：真发登录（子命令 9），成功后存 token.json
    .\tool\live_check.ps1 -Stage login -SliderTicket t03...   # 人工解完滑块后的续传（子命令 2）
    .\tool\live_check.ps1 -Stage session         # 第二段：用 token.json 起会话，验注册 + 心跳

  安全约定
  - uin / 口令只在交互提示里输入，经子进程的**环境变量**传递（不进命令行、不进 shell 历史、
    不落盘），进程结束立即清除。
  - 工具自身的输出只打印长度与指纹；滑验证地址含会话参数，转交他人前请自行涂掉。
  - token.json 是明文会话凭据：不要提交、用完删（脚本结束会提醒）。
  - 真发前会再问一次 yes，并同时要求 QQ_LIVE_CONFIRM 确认串（两道确认，缺一不可）。
#>

[CmdletBinding()]
param(
    [ValidateSet('pack', 'login', 'session')]
    [string] $Stage = 'pack',

    # 票据文件位置（-Stage session 用；-Stage login 成功后写在这里）
    [string] $TokenFile = 'token.json',

    # 心跳轮数（-Stage session）
    [int] $Rounds = 1,

    # 客户端档案名：default / 8.2.11 / 8.9.50 / 9.3.60 / tim4.1.0
    [string] $Profile = 'default',

    # 登录 TLV 清单：official（默认，超集 + guard）/ oicq（参考实现 24 项，排查用）
    [ValidateSet('official', 'oicq')]
    [string] $TlvSet = 'official',

    # 人工解完滑块拿到的 ticket（形如 t03...）；给了它就走子命令 2、不再问口令
    [string] $SliderTicket,

    # -Stage session 结束时发 logout 注册（正常下线）
    [switch] $Logout
)

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

# ---------- 找 dart ----------
$dart = Join-Path $env:USERPROFILE 'scoop/apps/flutter/bin/cache/dart-sdk/bin/dart.exe'
if (-not (Test-Path $dart)) {
    $cmd = Get-Command dart -ErrorAction SilentlyContinue
    if (-not $cmd) { throw '找不到 dart（既没有 scoop 的 flutter dart-sdk，也不在 PATH 里）' }
    $dart = $cmd.Source
}

# 工具输出直接打到控制台（调用方**不要**用 `$null =` 接，否则连子进程的 stdout 一起吞掉），
# 退出码走 $script:ToolExit。工具的参数解析只认 --key=value，不能拆成两个参数。
$script:ToolExit = 0

function Invoke-Tool {
    param([string] $Script, [string[]] $ToolArgs)
    Write-Host ''
    Write-Host "=== dart run $Script $($ToolArgs -join ' ') ===" -ForegroundColor Cyan
    & $dart run $Script @ToolArgs
    $script:ToolExit = $LASTEXITCODE
}

# ---------- pack：离线干跑，不碰网络 ----------
if ($Stage -eq 'pack') {
    Invoke-Tool 'tool/qq8_live_smoke.dart' @(
        "--profile=$Profile", "--tlv-set=$TlvSet"
    )

    # 会话材料用一份合成票据（全零/占位值，不是真凭据）
    $tmp = Join-Path ([IO.Path]::GetTempPath()) 'qq8-fake-token.json'
    if (-not (Test-Path $tmp)) {
        [ordered]@{
            uin        = 10001
            saved_at   = 'dry-run (synthetic, not real credentials)'
            tgt        = '1122334455667788'
            d2         = 'd2d2d2d2d2d2d2d2'
            d2key      = '00112233445566778899aabbccddeeff'
            sig_key    = 'aaaaaaaabbbbbbbbccccccccdddddddd'
            ticket_key = '0102030405060708090a0b0c0d0e0f10'
            srm_token  = '99aabbcc'
        } | ConvertTo-Json | Set-Content -Path $tmp -Encoding ascii
    }
    Invoke-Tool 'tool/qq8_session_live.dart' @("--token-file=$tmp")

    Write-Host ''
    Write-Host '离线干跑完成：上面没有 ✗ 就是组包自洽。' -ForegroundColor Green
    Write-Host '下一步：.\tool\live_check.ps1 -Stage login'
    return
}

# ---------- login：真发登录 ----------
if ($Stage -eq 'login') {
    $uin = Read-Host '测试号 uin（不要用主号）'
    if (-not $uin) { throw 'uin 不能为空' }

    # 滑验证续传（子命令 2）不需要口令：盐来自上一条响应，body 里没有 0x106。
    $plain = $null
    if (-not $SliderTicket) {
        $secure = Read-Host '口令（输入不回显；只经子进程环境变量传递）' -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        } finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    } else {
        Write-Host "滑验证提交模式（子命令 2）：不需要口令，盐自动读上一条响应的 0x104"
    }

    if ((Read-Host "确认真实发送到生产服务器？输入 yes 继续") -ne 'yes') {
        Write-Host '已取消。' -ForegroundColor Yellow
        return
    }

    $code = 0
    try {
        $env:QQ_LIVE_UIN = $uin
        if ($plain) { $env:QQ_LIVE_PWD = $plain }
        $env:QQ_LIVE_CONFIRM = 'I_UNDERSTAND_THE_RISK'
        $loginArgs = @(
            '--send', "--save-token=$TokenFile", "--profile=$Profile",
            "--tlv-set=$TlvSet", '--export-log'
        )
        if ($SliderTicket) { $loginArgs += "--slider-ticket=$SliderTicket" }
        Invoke-Tool 'tool/qq8_live_smoke.dart' $loginArgs
    } finally {
        $plain = $null
        Remove-Item Env:QQ_LIVE_PWD, Env:QQ_LIVE_UIN, Env:QQ_LIVE_CONFIRM -ErrorAction SilentlyContinue
    }
    $code = $script:ToolExit

    Write-Host ''
    switch ($code) {
        0 {
            Write-Host "登录被接受，票据已存 $TokenFile" -ForegroundColor Green
            Write-Host "接着验会话：.\tool\live_check.ps1 -Stage session -TokenFile $TokenFile"
        }
        1 { Write-Host '未成功（type≠0 或解析失败）。看上面的判读与响应结构诊断；不要马上重试。' -ForegroundColor Red }
        2 { Write-Host '被闸门拦下（缺确认串 / 缺口令）。' -ForegroundColor Yellow }
        3 { Write-Host '被限流器拒绝：10 分钟内最多 3 次、失败后冷却翻倍。等冷却过去再跑。' -ForegroundColor Yellow }
        default { Write-Host "退出码 $code" }
    }
    Write-Host ''
    Write-Host "⚠ $TokenFile 是明文会话凭据：别提交，验完 Remove-Item $TokenFile" -ForegroundColor DarkYellow
    return
}

# ---------- session：真发注册 + 心跳 ----------
if (-not (Test-Path $TokenFile)) { throw "票据文件不存在：$TokenFile（先跑 -Stage login）" }
if ((Read-Host '确认真实发送（注册 + 心跳）？输入 yes 继续') -ne 'yes') {
    Write-Host '已取消。' -ForegroundColor Yellow
    return
}

$env:QQ_LIVE_CONFIRM = 'I_UNDERSTAND_THE_RISK'
try {
    $sessionArgs = @(
        '--send', "--token-file=$TokenFile",
        "--rounds=$Rounds", "--profile=$Profile", '--export-log'
    )
    if ($Logout) { $sessionArgs += '--logout' }
    Invoke-Tool 'tool/qq8_session_live.dart' $sessionArgs
} finally {
    Remove-Item Env:QQ_LIVE_CONFIRM -ErrorAction SilentlyContinue
}
$code = $script:ToolExit

Write-Host ''
if ($code -eq 0) {
    Write-Host '注册与心跳全通 —— 端到端成立' -ForegroundColor Green
} else {
    Write-Host '有失败项：判读表见工具输出，把上面整段贴回来我来看。' -ForegroundColor Red
}
Write-Host ''
Write-Host "⚠ 验完删票据：Remove-Item $TokenFile" -ForegroundColor DarkYellow
