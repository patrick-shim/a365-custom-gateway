$script:RepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Common.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Azure.psm1') -Force
Import-Module (Join-Path $script:RepositoryRoot 'bootstrap/modules/Entra.psm1') -Force

Describe 'Purview automation certificate Entra credential window' {
    InModuleScope Entra {
        BeforeAll {
            $script:windowRsa = [Security.Cryptography.RSA]::Create(2048)
            $script:newWindowCertificate = {
                param([datetimeoffset]$NotBefore, [datetimeoffset]$NotAfter)
                $request = [Security.Cryptography.X509Certificates.CertificateRequest]::new(
                    'CN=a365gw-purview-automation-window-test',
                    $script:windowRsa,
                    [Security.Cryptography.HashAlgorithmName]::SHA256,
                    [Security.Cryptography.RSASignaturePadding]::Pkcs1)
                return $request.CreateSelfSigned($NotBefore, $NotAfter)
            }
            $script:asOffset = {
                param([datetime]$Value)
                return [datetimeoffset]::new($Value.ToUniversalTime(), [timespan]::Zero)
            }
            $script:parseOffset = {
                param([string]$Value)
                return [datetimeoffset]::Parse(
                    $Value,
                    [cultureinfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind)
            }
        }

        AfterAll {
            if ($script:windowRsa) {
                $script:windowRsa.Dispose()
                $script:windowRsa = $null
            }
        }

        It 'keeps the requested window inside the certificate validity and under one year' {
            $certificate = & $script:newWindowCertificate `
                -NotBefore ([datetimeoffset]::UtcNow.AddMinutes(-5)) `
                -NotAfter ([datetimeoffset]::UtcNow.AddYears(1))
            try {
                $window = Get-BootstrapPurviewCertificateCredentialWindow -Certificate $certificate
                $start = & $script:parseOffset ([string]$window.startDateTime)
                $end = & $script:parseOffset ([string]$window.endDateTime)

                $start | Should -BeGreaterOrEqual (& $script:asOffset $certificate.NotBefore)
                $end | Should -BeLessOrEqual (& $script:asOffset $certificate.NotAfter)
                $end | Should -BeLessOrEqual $start.AddYears(1)
                $end | Should -BeGreaterThan ([datetimeoffset]::UtcNow)
            }
            finally { $certificate.Dispose() }
        }

        It 'emits whole-second UTC timestamps that the certificate validity can represent' {
            $certificate = & $script:newWindowCertificate `
                -NotBefore ([datetimeoffset]::UtcNow.AddMinutes(-5)) `
                -NotAfter ([datetimeoffset]::UtcNow.AddYears(1))
            try {
                $window = Get-BootstrapPurviewCertificateCredentialWindow -Certificate $certificate

                [string]$window.startDateTime |
                    Should -MatchExactly '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
                [string]$window.endDateTime |
                    Should -MatchExactly '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
            }
            finally { $certificate.Dispose() }
        }

        It 'no longer requests the rejected window that outlived the certificate and exceeded one year' {
            $requestedNotBefore = [datetimeoffset]::UtcNow.AddMinutes(-5)
            $requestedNotAfter = [datetimeoffset]::UtcNow.AddYears(1)
            $certificate = & $script:newWindowCertificate `
                -NotBefore $requestedNotBefore -NotAfter $requestedNotAfter
            try {
                # The rejected payload sent the round-trip generation values directly.
                $previousStart = & $script:parseOffset ($requestedNotBefore.ToString('O'))
                $previousEnd = & $script:parseOffset ($requestedNotAfter.ToString('O'))
                $previousEnd | Should -BeGreaterThan (& $script:asOffset $certificate.NotAfter)
                $previousEnd | Should -BeGreaterThan $previousStart.AddYears(1)

                $window = Get-BootstrapPurviewCertificateCredentialWindow -Certificate $certificate
                $start = & $script:parseOffset ([string]$window.startDateTime)
                $end = & $script:parseOffset ([string]$window.endDateTime)
                $end | Should -Not -BeGreaterThan (& $script:asOffset $certificate.NotAfter)
                $end | Should -Not -BeGreaterThan $start.AddYears(1)
            }
            finally { $certificate.Dispose() }
        }

        It 'clamps the window to a certificate that expires before the maximum' {
            $certificate = & $script:newWindowCertificate `
                -NotBefore ([datetimeoffset]::UtcNow.AddMinutes(-5)) `
                -NotAfter ([datetimeoffset]::UtcNow.AddDays(10))
            try {
                $window = Get-BootstrapPurviewCertificateCredentialWindow -Certificate $certificate

                (& $script:parseOffset ([string]$window.startDateTime)) |
                    Should -Be (& $script:asOffset $certificate.NotBefore)
                (& $script:parseOffset ([string]$window.endDateTime)) |
                    Should -Be (& $script:asOffset $certificate.NotAfter)
            }
            finally { $certificate.Dispose() }
        }

        It 'refuses a certificate that cannot produce a currently valid window' {
            $certificate = & $script:newWindowCertificate `
                -NotBefore ([datetimeoffset]::UtcNow.AddDays(-40)) `
                -NotAfter ([datetimeoffset]::UtcNow.AddDays(-30))
            try {
                { Get-BootstrapPurviewCertificateCredentialWindow -Certificate $certificate } |
                    Should -Throw -ExpectedMessage '*credential window*'
            }
            finally { $certificate.Dispose() }
        }
    }
}
