function Get-PhpSrc {
    <#
    .SYNOPSIS
        Stand-in for php-windows-builder's Get-PhpSrc: hand it the patched tree
        in $env:PV_PHP_SRC instead of downloading the php-src tag.
    .DESCRIPTION
        build/build-php-windows.sh copies this over the pinned builder's own
        private/Get-PhpSrc.ps1. Everything else in the builder, the layout its
        configure flags assume included, stays as upstream wrote it. The
        outputs match the original: php-<version>-src beside a zip of it.
    .PARAMETER PhpVersion
        PHP Version
    #>
    [OutputType()]
    param (
        [Parameter(Mandatory = $true, Position=0, HelpMessage='PHP Version')]
        [string] $PhpVersion
    )
    process {
        Add-Type -Assembly "System.IO.Compression.Filesystem"

        $source = $env:PV_PHP_SRC
        if (-not $source -or -not (Test-Path -LiteralPath (Join-Path $source 'main/php_version.h'))) {
            throw "PV_PHP_SRC does not point at a php-src tree"
        }

        $currentDirectory = (Get-Location).Path
        $directoryPath = Join-Path $currentDirectory "php-$PhpVersion-src"
        $srcZipFilePath = Join-Path $currentDirectory "php-$PhpVersion-src.zip"

        Copy-Item -LiteralPath $source -Destination $directoryPath -Recurse
        [System.IO.Compression.ZipFile]::CreateFromDirectory($directoryPath, $srcZipFilePath)
    }
}
