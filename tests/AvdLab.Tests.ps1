# Offline checks: the Bicep compiles and lints clean, and the session host script is sound.
# Needs the Bicep CLI (az bicep install) plus Pester 5+ and PSScriptAnalyzer.

BeforeAll {
    $root   = Join-Path $PSScriptRoot '..'
    $main   = Join-Path $root 'infra/main.bicep'
    $script = Join-Path $root 'scripts/Register-AvdSessionHost.ps1'
    $bicep  = (Get-Command bicep -ErrorAction SilentlyContinue).Source
    if (-not $bicep) { $bicep = Join-Path $HOME '.azure/bin/bicep' }
}

Describe 'Bicep' {
    It 'builds main.bicep' {
        $out = & $bicep build $main --stdout 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($out | Out-String)
    }
    It 'lints with no warnings or errors' {
        $out = & $bicep lint $main 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Not -Match '(Warning|Error) '
    }
    It 'builds the example parameter file' {
        $env:AVD_LOCAL_ADMIN_PASSWORD = 'not-a-real-password'
        try {
            $out = & $bicep build-params (Join-Path $root 'infra/main.bicepparam') --stdout 2>&1
            $LASTEXITCODE | Should -Be 0 -Because ($out | Out-String)
        } finally { Remove-Item Env:AVD_LOCAL_ADMIN_PASSWORD }
    }
}

Describe 'Register-AvdSessionHost.ps1' {
    It 'parses' {
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }
    It 'has help with a synopsis and an example' {
        $help = Get-Help $script -Full
        $help.Synopsis | Should -Not -BeNullOrEmpty
        @($help.Examples.Example).Count | Should -BeGreaterThan 0
    }
    It 'requires a registration token' {
        $param = (Get-Command $script).Parameters['RegistrationToken']
        $param.Attributes.Where({ $_ -is [System.Management.Automation.ParameterAttribute] }).Mandatory | Should -BeTrue
    }
    It 'passes PSScriptAnalyzer' {
        $issues = Invoke-ScriptAnalyzer -Path $script -Severity Warning, Error
        $issues | ForEach-Object { Write-Host "$($_.Line) $($_.RuleName) $($_.Message)" }
        $issues | Should -BeNullOrEmpty
    }
}
