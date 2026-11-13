#Requires -Version 5.1

<#
.SYNOPSIS
Creates a per-file Git contribution report for a selected author.

.DESCRIPTION
Fetches a remote branch, reads non-merge commits matching the supplied author,
groups numeric line changes by file, and exports the result to CSV. It also
prints the most frequently changed files and a category summary.

.PARAMETER Author
Author name or email pattern passed to git log --author. This value is required
so the script never embeds a personal identity.

.PARAMETER Remote
Git remote to fetch. The default is origin.

.PARAMETER Branch
Remote branch to inspect. The default is main.

.PARAMETER OutputPath
CSV output path. The default is .\file-impact.csv.

.PARAMETER Top
Number of files to show in the console ranking. The default is 30.

.PARAMETER NoFetch
Skips git fetch and uses the currently available remote-tracking reference.

.EXAMPLE
.\ShowStats.ps1 -Author 'developer@example.com'

.EXAMPLE
.\ShowStats.ps1 -Author 'Developer Name' -Branch develop -Top 20 `
    -OutputPath '.\developer-impact.csv'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Author,

    [ValidateNotNullOrEmpty()]
    [string]$Remote = 'origin',

    [ValidateNotNullOrEmpty()]
    [string]$Branch = 'main',

    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = '.\file-impact.csv',

    [ValidateRange(1, 1000)]
    [int]$Top = 30,

    [switch]$NoFetch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = @(& git @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Git command failed: git $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)"
    }

    return $output
}

$insideWorkTree = @(Invoke-Git -Arguments @('rev-parse', '--is-inside-work-tree'))
if ($insideWorkTree[-1] -ne 'true') {
    throw 'Run this script from inside a Git working tree.'
}

$remotes = @(Invoke-Git -Arguments @('remote'))
if ($Remote -notin $remotes) {
    throw "Git remote '$Remote' was not found. Available remotes: $($remotes -join ', ')"
}

$null = Invoke-Git -Arguments @('check-ref-format', '--branch', $Branch)

if (-not $NoFetch) {
    Write-Host "Fetching $Remote/$Branch..."
    $null = Invoke-Git -Arguments @('fetch', $Remote, $Branch)
}

$targetRef = "$Remote/$Branch"
$null = Invoke-Git -Arguments @('rev-parse', '--verify', "$targetRef^{commit}")

$stats = @{}
$currentCommit = ''
$logArguments = @(
    '-c', 'core.quotepath=false',
    'log', $targetRef,
    '--no-merges',
    "--author=$Author",
    '--format=@@COMMIT:%H',
    '--numstat'
)

Invoke-Git -Arguments $logArguments | ForEach-Object {
    $line = $_

    if ($line -match '^@@COMMIT:([a-fA-F0-9]{40})') {
        $currentCommit = $matches[1]
    }
    elseif ($line -match '^(\d+)\t(\d+)\t(.+)$') {
        $added = [long]$matches[1]
        $deleted = [long]$matches[2]
        $file = $matches[3]

        if (-not $stats.ContainsKey($file)) {
            $stats[$file] = @{
                File = $file
                Added = 0L
                Deleted = 0L
                Commits = [System.Collections.Generic.HashSet[string]]::new()
            }
        }

        $stats[$file].Added += $added
        $stats[$file].Deleted += $deleted
        [void]$stats[$file].Commits.Add($currentCommit)
    }
}

if ($stats.Count -eq 0) {
    throw "No numeric file changes were found for author pattern '$Author' on $targetRef."
}

$report = @(
    foreach ($item in $stats.Values) {
        $file = $item.File

        $category = switch -Regex ($file) {
            '(^|/)(test|tests|androidTest|integration_test|__tests__)/|(\.test|\.spec)\.|Test\.(kt|java)$' {
                'TEST'; break
            }
            '(^|/)(docs?)/|\.md$' {
                'DOCUMENTATION'; break
            }
            '^\.github/|^ci/' {
                'CI'; break
            }
            default {
                'SOURCE_OR_OTHER'
            }
        }

        [PSCustomObject]@{
            File = $file
            Category = $category
            Commits = $item.Commits.Count
            Added = $item.Added
            Deleted = $item.Deleted
            Net = $item.Added - $item.Deleted
            TotalChanges = $item.Added + $item.Deleted
        }
    }
) | Sort-Object TotalChanges -Descending

$outputDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($OutputPath))
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    throw "Output directory does not exist: $outputDirectory"
}

$report | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host "`nTOP $Top FILES:"
$report |
    Select-Object -First $Top |
    Format-Table File, Commits, Added, Deleted, Net -AutoSize

Write-Host "`nCATEGORY SUMMARY:"
$report |
    Group-Object Category |
    ForEach-Object {
        [PSCustomObject]@{
            Category = $_.Name
            Files = $_.Count
            Added = ($_.Group | Measure-Object Added -Sum).Sum
            Deleted = ($_.Group | Measure-Object Deleted -Sum).Sum
        }
    } | Format-Table -AutoSize

Write-Host "`nTOTAL:"
Write-Host "Files affected: $($report.Count)"
Write-Host "Lines added: $(($report | Measure-Object Added -Sum).Sum)"
Write-Host "Lines deleted: $(($report | Measure-Object Deleted -Sum).Sum)"
Write-Host "Report: $((Resolve-Path -LiteralPath $OutputPath).Path)"
