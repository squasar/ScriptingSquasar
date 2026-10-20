#Requires -Version 5.1
<#
.SYNOPSIS
  Finds registered linked Git worktrees below a directory and removes only clean,
  verified-merged worktrees when -Apply is supplied. Optionally fast-forwards main.
.EXAMPLE
  .\Remove-MergedWorktrees.ps1 -Root 'C:\Dev\github'
.EXAMPLE
  .\Remove-MergedWorktrees.ps1 -Root 'C:\Dev\github' -Fetch -CheckGitHubPRs
.EXAMPLE
  .\Remove-MergedWorktrees.ps1 -Root 'C:\Dev\github' -UpdateMain -CheckGitHubPRs -Apply
.EXAMPLE
  .\Remove-MergedWorktrees.ps1 -Root 'C:\Dev\github' -RecoverOrphanedPaths 'C:\Dev\github\Repo-old-worktree' -Apply
.NOTES
  Worktrees, NOT independent git clones. Dry-run by default.
  Uses origin/main when present, otherwise local main. GitHub PR lookup requires
  GitHub CLI (gh) authenticated, and verifies the exact branch tip SHA and base.
  Never uses git worktree remove --force. Never deletes git branches.
  Invokes removal from the PRIMARY worktree, not the folder being removed.
  -SkipGeneratedDirs excludes known build/cache directories from discovery (opt-in).
  -UpdateMain fetches origin and fast-forwards a CLEAN, checked-out local main
  inside Root only with -Apply. Without -Apply, main update is previewed.
  Every Git invocation enables core.longpaths for that process only. The script
  does not modify system, global, or repository Git configuration.
  -RecoverOrphanedPaths is an explicit legacy-recovery allow-list. It accepts
  exact absolute paths only, also requires -AllowIgnored for removal, and never
  selects orphan folders automatically.
#>
[CmdletBinding()]
param(
    [string]$Root = (Get-Location).Path,
    [switch]$Apply,
    [switch]$Fetch,
    [switch]$UpdateMain,
    [switch]$CheckGitHubPRs,
    [switch]$AllowIgnored,
    [switch]$SkipGeneratedDirs,
    [string[]]$RecoverOrphanedPaths = @(),
    [ValidateSet('Auto','Local','Origin')]
    [string]$MainRef = 'Auto'
)

$ErrorActionPreference = 'Continue'

# Git for Windows keeps long-path support disabled by default. A worktree can
# have a short root path while a nested file still exceeds the legacy Win32
# MAX_PATH limit, causing both status and worktree removal to fail with
# "Filename too long". Enable the Git for Windows long-path implementation for
# every child Git process without persisting or mutating any Git configuration.
$gitCommonArgs = @('-c', 'core.longpaths=true')

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw 'Git bulunamadi. Git for Windows kurup PATH icine ekleyin.'
}
if ($CheckGitHubPRs -and -not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Warning 'gh (GitHub CLI) bulunamadi. Squash merge PR kontrolu devre disi.'
    $CheckGitHubPRs = $false
}

function Normalize-Path([string]$Value) {
    $v = [IO.Path]::GetFullPath($Value)
    $driveRoot = [IO.Path]::GetPathRoot($v)
    if ($v -eq $driveRoot) { return $v }
    return $v.TrimEnd([char[]]@('\','/'))
}

$resolvedRoot = Resolve-Path -LiteralPath $Root -ErrorAction Stop
$rootPath = Normalize-Path $resolvedRoot.ProviderPath
if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
    throw "Klasor bulunamadi: $Root"
}
$prefix = $rootPath
if (-not ($prefix.EndsWith('\') -or $prefix.EndsWith('/'))) {
    $prefix += [IO.Path]::DirectorySeparatorChar
}
function Test-InRoot([string]$Candidate) {
    try {
        $full = Normalize-Path $Candidate
        return $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Convert-ToExtendedPath([string]$Value) {
    $full = Normalize-Path $Value
    if ($full.StartsWith('\\', [StringComparison]::Ordinal)) {
        return '\\?\UNC\' + $full.Substring(2)
    }
    return '\\?\' + $full
}

function Test-DirectoryLongPath([string]$Value) {
    try { return [IO.Directory]::Exists((Convert-ToExtendedPath $Value)) }
    catch { return $false }
}

function Test-ReparsePoint([string]$Value) {
    $attributes = [IO.File]::GetAttributes((Convert-ToExtendedPath $Value))
    return (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Test-ContainsGitMarker([string]$Value, [switch]$AllowRootGitFile) {
    $root = Convert-ToExtendedPath $Value
    $pendingDirectories = [Collections.Generic.Stack[string]]::new()
    $pendingDirectories.Push($root)
    while ($pendingDirectories.Count -gt 0) {
        $current = $pendingDirectories.Pop()
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($current)) {
            $attributes = [IO.File]::GetAttributes($entry)
            $isDirectory = ($attributes -band [IO.FileAttributes]::Directory) -ne 0
            $isReparsePoint = ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            if ([IO.Path]::GetFileName($entry) -ieq '.git') {
                $allowedRootFile = $AllowRootGitFile -and ($current -ieq $root) -and
                                   -not $isDirectory -and -not $isReparsePoint
                if (-not $allowedRootFile) { return $true }
            }
            if ($isDirectory -and -not $isReparsePoint) {
                $pendingDirectories.Push($entry)
            }
        }
    }
    return $false
}

function Remove-DirectoryTreeLongPath([string]$Value, [switch]$AllowRootGitFile) {
    # This deliberately avoids Remove-Item: Windows PowerShell 5.1 can hand its
    # provider a MAX_PATH-limited path. Extended-length .NET paths are used for
    # every filesystem operation, and reparse points are unlinked, never walked.
    $root = Convert-ToExtendedPath $Value
    $rootAttributes = [IO.File]::GetAttributes($root)
    if (($rootAttributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Kok hedef reparse point; fiziksel silme reddedildi: $Value"
    }

    $pendingDirectories = [Collections.Generic.Stack[string]]::new()
    $deleteDirectories = [Collections.Generic.Stack[string]]::new()
    $pendingDirectories.Push($root)
    while ($pendingDirectories.Count -gt 0) {
        $current = $pendingDirectories.Pop()
        $deleteDirectories.Push($current)
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($current)) {
            $attributes = [IO.File]::GetAttributes($entry)
            $isDirectory = ($attributes -band [IO.FileAttributes]::Directory) -ne 0
            $isReparsePoint = ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            if ([IO.Path]::GetFileName($entry) -ieq '.git') {
                $allowedRootFile = $AllowRootGitFile -and ($current -ieq $root) -and
                                   -not $isDirectory -and -not $isReparsePoint
                if (-not $allowedRootFile) {
                    throw "Silme sirasinda .git bulundu; islem durduruldu: $entry"
                }
            }
            if ($isDirectory) {
                if ($isReparsePoint) {
                    [IO.Directory]::Delete($entry, $false)
                } else {
                    $pendingDirectories.Push($entry)
                }
            } else {
                if (($attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) {
                    $writableAttributes = [IO.FileAttributes]($attributes -band (-bnot [IO.FileAttributes]::ReadOnly))
                    [IO.File]::SetAttributes($entry, $writableAttributes)
                }
                [IO.File]::Delete($entry)
            }
        }
    }
    while ($deleteDirectories.Count -gt 0) {
        [IO.Directory]::Delete($deleteDirectories.Pop(), $false)
    }
}

function Read-Worktrees([string]$Repo) {
    $lines = @(& git @gitCommonArgs -C $Repo worktree list --porcelain 2>$null)
    if ($LASTEXITCODE -ne 0) { throw "Worktree listesi alinamadi: $Repo" }
    $result = [Collections.Generic.List[object]]::new()
    $item = $null
    foreach ($line in $lines) {
        if ($line -match '^worktree (.+)$') {
            if ($null -ne $item) { $result.Add($item) }
            $item = [pscustomobject]@{
                Path = $Matches[1]; Branch = ''; Head = ''; Bare = $false
                Locked = $false; Prunable = $false; Detached = $false
            }
        } elseif ($null -ne $item) {
            if ($line -match '^branch (.+)$') { $item.Branch = $Matches[1] }
            elseif ($line -match '^HEAD (.+)$') { $item.Head = $Matches[1] }
            elseif ($line -match '^locked(?: |$)') { $item.Locked = $true }
            elseif ($line -match '^prunable(?: |$)') { $item.Prunable = $true }
            elseif ($line -eq 'bare') { $item.Bare = $true }
            elseif ($line -eq 'detached') { $item.Detached = $true }
        }
    }
    if ($null -ne $item) { $result.Add($item) }
    return $result.ToArray()
}

function Get-GitHubRepo([string]$Repo) {
    $url = @(& git @gitCommonArgs -C $Repo remote get-url origin 2>$null)
    if ($LASTEXITCODE -ne 0 -or $url.Count -eq 0) { return $null }
    $u = $url[0].Trim()
    # Accepted: git@github.com:owner/repo.git, https://github.com/owner/repo.git,
    # ssh://git@github.com/owner/repo.git
    if ($u -match '^(?:https?://github\.com/|ssh://git@github\.com/|git@github\.com:)([^/\s]+)/([^/\s]+?)(?:\.git)?/?$') {
        return ($Matches[1] + '/' + $Matches[2])
    }
    return $null
}

function Test-GitHubMergedPR([string]$GitHubRepo, [string]$Branch, [string]$Head) {
    if (-not $GitHubRepo -or -not $Head -or -not $CheckGitHubPRs) { return $null }
    $shortName = $Branch.Substring('refs/heads/'.Length)
    try {
        $json = (& gh pr list --repo $GitHubRepo --state merged --base main --head $shortName --json 'number,headRefOid,baseRefName,mergedAt,url' --limit 500 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "GitHub PR sorgusu basarisiz: $GitHubRepo ($shortName). Atlandi."
            return $null
        }
        if ([string]::IsNullOrWhiteSpace($json)) { return $null }
        foreach ($pr in @($json | ConvertFrom-Json)) {
            if (($pr.baseRefName -eq 'main') -and $pr.mergedAt -and
                ($pr.headRefOid -eq $Head)) {
                return "GitHub merged PR #$($pr.number) (HEAD SHA dogrulandi)"
            }
        }
    } catch {
        Write-Warning "PR sorgulanamadi: $GitHubRepo ($shortName): $($_.Exception.Message)"
    }
    return $null
}

Write-Host "[BASLIYOR] Kok klasor: $rootPath"
if ($Apply) {
    Write-Host '[MOD] GERCEK KALDIRMA - sadece temiz ve merge dogrulanmis linked worktree' -ForegroundColor Yellow
} else {
    Write-Host '[MOD] ONIZLEME - hicbir klasor silinmeyecek' -ForegroundColor Cyan
}
if ($AllowIgnored) {
    Write-Warning 'AllowIgnored aktif: ignore edilen DOSYALAR korunmaz; worktree kaldirilirken silinebilir.'
}
if ($SkipGeneratedDirs) {
    Write-Warning 'SkipGeneratedDirs aktif: node_modules, .dart_tool, .next vb. klasorler altindaki depolar da TARANMAZ.'
}

$pending = [Collections.Generic.Stack[string]]::new()
$pending.Push($rootPath)
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$repositories = [Collections.Generic.List[string]]::new()
$visited = 0

# Scan every physical subdirectory (except Git internals and reparse points).
while ($pending.Count -gt 0) {
    $directory = $pending.Pop()
    $visited++
    if (($visited % 500) -eq 0) {
        Write-Host "[TARAMA] $visited klasor incelendi, $($repositories.Count) Git deposu bulundu"
    }
    $marker = Join-Path $directory '.git'
    $isBare = (Test-Path -LiteralPath (Join-Path $directory 'HEAD') -PathType Leaf) -and
              (Test-Path -LiteralPath (Join-Path $directory 'objects') -PathType Container)
    if ((Test-Path -LiteralPath $marker) -or $isBare) {
        $commonOutput = @(& git @gitCommonArgs -C $directory rev-parse --git-common-dir 2>$null)
        if ($LASTEXITCODE -eq 0 -and $commonOutput.Count -gt 0) {
            try {
                $commonDir = $commonOutput[0].Trim()
                if (-not [IO.Path]::IsPathRooted($commonDir)) {
                    $commonDir = Join-Path $directory $commonDir
                }
                $key = Normalize-Path $commonDir
                if ($seen.Add($key)) {
                    $repositories.Add($directory)
                    Write-Host "[REPO BULUNDU] $directory"
                }
            } catch {
                Write-Warning "Git dizini okunamadi: $directory"
            }
        }
    }
    try {
        $children = [IO.Directory]::GetDirectories($directory)
    } catch {
        Write-Warning "Klasore erisilemiyor: $directory"
        continue
    }
    foreach ($child in $children) {
        $childName = [IO.Path]::GetFileName($child)
        if ($childName -eq '.git') { continue }
        if ($SkipGeneratedDirs -and $childName -in @('node_modules','.dart_tool','.next','.gradle','.venv','venv','__pycache__','.pub-cache','build','dist','coverage','.turbo')) { continue }
        try {
            if (([IO.File]::GetAttributes($child) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                continue
            }
            $pending.Push($child)
        } catch {
            Write-Warning "Atlanan klasor: $child"
        }
    }
}

Write-Host "[TARAMA BITTI] $visited klasor incelendi, $($repositories.Count) benzersiz Git deposu bulundu."
$eligibleCount = 0
$removedCount = 0
$fallbackRemovedCount = 0
$skippedCount = 0
$totalSecondary = 0
$orphanEligibleCount = 0
$orphanRemovedCount = 0
$orphanSkippedCount = 0

foreach ($repo in $repositories) {
    Write-Host "`n[REPO] $repo" -ForegroundColor Cyan
    $fetchSucceeded = $false
    if ($Fetch -or $UpdateMain) {
        $remotes = @(& git @gitCommonArgs -C $repo remote 2>$null)
        if ($LASTEXITCODE -eq 0 -and ($remotes -contains 'origin')) {
            Write-Host '[FETCH] origin guncelleniyor...'
            & git @gitCommonArgs -C $repo fetch --no-tags origin 2>&1 | ForEach-Object { Write-Host "  $_" }
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Fetch basarisiz: $repo. Depoda hicbir worktree silinmeyecek."
            } else {
                $fetchSucceeded = $true
            }
        } else {
            Write-Host '[FETCH ATLANDI] origin remote bulunamadi.' -ForegroundColor DarkYellow
        }
    }

    if (($Fetch -or $UpdateMain) -and -not $fetchSucceeded) {
        Write-Warning "[REPO ATLANDI] Fetch basarisiz: merge kontrolunde bayat origin/main kullanilmadi. $repo"
        continue
    }

    $base = $null
    $candidates = if ($MainRef -eq 'Local') { @('refs/heads/main') }
                  elseif ($MainRef -eq 'Origin') { @('refs/remotes/origin/main') }
                  else { @('refs/remotes/origin/main','refs/heads/main') }
    foreach ($candidate in $candidates) {
        & git @gitCommonArgs -C $repo show-ref --verify --quiet $candidate 2>$null
        if ($LASTEXITCODE -eq 0) { $base = $candidate; break }
    }
    Write-Host "[ANA DAL] $(if ($base) { $base } else { '(yok)' })"
    $ghRepo = $null
    if ($CheckGitHubPRs) {
        $ghRepo = Get-GitHubRepo $repo
        if (-not $ghRepo) { Write-Host '[GITHUB PR] origin GitHub adresi degil veya tespit edilemedi.' }
    }

    try { $worktrees = @(Read-Worktrees $repo) }
    catch {
        Write-Warning $_.Exception.Message
        continue
    }
    Write-Host "[WORKTREE] Kayitli: $($worktrees.Count)"

    # Git for Windows cannot remove a directory while the git.exe process's
    # current directory (-C) IS that same directory. Repository discovery may
    # have found a secondary worktree first. Always anchor removal at the
    # registered PRIMARY worktree (entry 0 from --porcelain).
    $controlPath = $null
    if ($worktrees.Count -gt 0 -and -not $worktrees[0].Bare -and
        -not $worktrees[0].Prunable -and
        (Test-DirectoryLongPath $worktrees[0].Path)) {
        try { $controlPath = Normalize-Path $worktrees[0].Path } catch {}
    }
    if ($controlPath) {
        Write-Host "[GIT KONTROL DIZINI] $controlPath"
    } else {
        Write-Warning 'Birincil worktree yok / erisilemiyor. Silme islemleri korunacak.'
    }

    # Update local main only if requested and only via a clean, checked-out main
    # worktree under Root. origin/main is refreshed by fetch above.
    if ($UpdateMain) {
        & git @gitCommonArgs -C $repo show-ref --verify --quiet refs/heads/main 2>$null
        $hasLocalMain = $LASTEXITCODE -eq 0
        & git @gitCommonArgs -C $repo show-ref --verify --quiet refs/remotes/origin/main 2>$null
        $hasRemoteMain = $LASTEXITCODE -eq 0
        $mainWorktree = @($worktrees | Where-Object {
            $_.Branch -eq 'refs/heads/main' -and -not $_.Prunable -and -not $_.Bare
        } | Select-Object -First 1)

        if (-not $fetchSucceeded) {
            Write-Host '[MAIN ATLANDI] origin basariyla fetch edilmedigi icin main guncellenmedi.' -ForegroundColor DarkYellow
        } elseif (-not $hasLocalMain -or -not $hasRemoteMain) {
            Write-Host '[MAIN ATLANDI] main veya origin/main referansi bulunamadi.' -ForegroundColor DarkYellow
        } elseif ($mainWorktree.Count -eq 0) {
            Write-Host '[MAIN ATLANDI] main dalinin checkout edildigi worktree bulunamadi.' -ForegroundColor DarkYellow
        } elseif ($mainWorktree[0].Locked) {
            Write-Host '[MAIN ATLANDI] main worktree kilitli.' -ForegroundColor DarkYellow
        } else {
            $mainPath = $mainWorktree[0].Path
            $mainFull = $null
            try { $mainFull = Normalize-Path $mainPath } catch {}
            if (-not $mainFull -or
                -not (($mainFull -eq $rootPath) -or (Test-InRoot $mainFull))) {
                Write-Host "[MAIN ATLANDI] main kok klasor disinda: $mainPath" -ForegroundColor DarkYellow
            } elseif (-not (Test-DirectoryLongPath $mainPath)) {
                Write-Host "[MAIN ATLANDI] main klasoru bulunamadi: $mainPath" -ForegroundColor DarkYellow
            } else {
                & git @gitCommonArgs -C $repo merge-base --is-ancestor refs/heads/main refs/remotes/origin/main 2>$null
                if ($LASTEXITCODE -ne 0) {
                    Write-Host '[MAIN ATLANDI] Yerel main origin/main dalindan ayrilmis; otomatik merge/reset yok.' -ForegroundColor DarkYellow
                } else {
                    $localHead = @(& git @gitCommonArgs -C $repo rev-parse refs/heads/main 2>$null)
                    $remoteHead = @(& git @gitCommonArgs -C $repo rev-parse refs/remotes/origin/main 2>$null)
                    if ($localHead.Count -eq 0 -or $remoteHead.Count -eq 0) {
                        Write-Host '[MAIN ATLANDI] Commit SHA okunamadi.' -ForegroundColor DarkYellow
                    } elseif ($localHead[0].Trim() -eq $remoteHead[0].Trim()) {
                        Write-Host "[MAIN] Zaten guncel: $mainPath"
                    } else {
                        $mainChanges = @(& git @gitCommonArgs -C $mainPath status --porcelain=v1 --untracked-files=all 2>$null)
                        if ($LASTEXITCODE -ne 0 -or $mainChanges.Count -gt 0) {
                            Write-Host "[MAIN ATLANDI] main temiz degil: $mainPath" -ForegroundColor DarkYellow
                        } elseif (-not $Apply) {
                            Write-Host "[MAIN GUNCELLENEBILIR] $mainPath | fast-forward origin/main" -ForegroundColor Cyan
                        } else {
                            Write-Host "[MAIN GUNCELLENIYOR] $mainPath | fast-forward origin/main"
                            & git @gitCommonArgs -C $mainPath merge --ff-only refs/remotes/origin/main 2>&1 | ForEach-Object { Write-Host "  $_" }
                            if ($LASTEXITCODE -eq 0) {
                                Write-Host "[MAIN GUNCELLENDI] $mainPath" -ForegroundColor Green
                            } else {
                                Write-Warning "Main guncellenemedi: $mainPath. Zorlama uygulanmadi."
                            }
                        }
                    }
                }
            }
        }
    }

    for ($i = 0; $i -lt $worktrees.Count; $i++) {
        $wt = $worktrees[$i]
        $path = $wt.Path
        $branch = $wt.Branch
        # Git always lists the primary worktree first; never remove it.
        if ($i -eq 0) {
            Write-Host "[KORUNDU: ana worktree] $path"
            continue
        }
        $totalSecondary++
        $reason = $null
        if ($wt.Bare) { $reason = 'bare repo' }
        elseif ($branch -eq 'refs/heads/main') { $reason = 'main dali' }
        elseif ($wt.Locked) { $reason = 'kilitli' }
        elseif ($wt.Prunable) { $reason = 'klasor kayip / prunable (yalniz metadata)' }
        elseif ($wt.Detached -or -not $branch.StartsWith('refs/heads/')) { $reason = 'detached veya dal belirsiz' }
        elseif (-not (Test-InRoot $path)) { $reason = 'kok klasor disinda' }
        elseif (-not (Test-DirectoryLongPath $path)) { $reason = 'worktree klasoru yok' }
        elseif (Test-ReparsePoint $path) { $reason = 'worktree koku reparse point' }
        if ($reason) {
            $skippedCount++
            Write-Host "[ATLANDI: $reason] $path [$branch]" -ForegroundColor DarkYellow
            continue
        }

        $mergeReason = $null
        if ($base) {
            & git @gitCommonArgs -C $repo merge-base --is-ancestor $branch $base 2>$null
            if ($LASTEXITCODE -eq 0) { $mergeReason = "Git gecmisi: $base" }
        }
        if (-not $mergeReason -and $ghRepo) {
            $mergeReason = Test-GitHubMergedPR $ghRepo $branch $wt.Head
        }
        if (-not $mergeReason) {
            $skippedCount++
            Write-Host "[ATLANDI: merge dogrulanamadi] $path [$branch]" -ForegroundColor DarkYellow
            continue
        }
        $branchName = $branch.Substring('refs/heads/'.Length)
        Write-Host "[WORKTREE] $branchName - main'e merge edilmis ($mergeReason)"

        # --ignored is intentional: by default even ignored data is protected.
        $statusArgs = $gitCommonArgs + @('-C', $path, 'status', '--porcelain=v1', '--untracked-files=all')
        if (-not $AllowIgnored) { $statusArgs += '--ignored=matching' }
        $changes = @(& git @statusArgs 2>$null)
        if ($LASTEXITCODE -ne 0) {
            $skippedCount++
            Write-Host "[ATLANDI: git status hatasi] $path [$branch]" -ForegroundColor DarkYellow
            continue
        }
        if ($changes.Count -gt 0) {
            $skippedCount++
            $sample = ($changes | Select-Object -First 2) -join '; '
            Write-Host "[ATLANDI: temiz degil] $path [$branch] | $sample" -ForegroundColor DarkYellow
            continue
        }

        $eligibleCount++
        if (-not $Apply) {
            Write-Host "[KALDIRILABILIR] $path [$branch] | $mergeReason" -ForegroundColor Green
            continue
        }
        if (-not $controlPath) {
            $skippedCount++
            Write-Host "[ATLANDI: kontrol worktree bulunamadi] $path" -ForegroundColor DarkYellow
            continue
        }
        # Crucial Windows protection: do not delete the git.exe -C directory.
        if ($controlPath -ieq (Normalize-Path $path)) {
            $skippedCount++
            Write-Host "[ATLANDI: kendi calisma dizini] $path" -ForegroundColor DarkYellow
            continue
        }
        Write-Host "[KALDIRILIYOR] $path | $mergeReason"
        # Avoid an unattended agent hanging forever on Git for Windows (y/n)
        # prompts if antivirus/IDE still has a file handle open.
        $oldGitAskYesNo = $env:GIT_ASK_YESNO
        try {
            $env:GIT_ASK_YESNO = 'false'
            & git @gitCommonArgs -C $controlPath worktree remove -- $path
            $removeExitCode = $LASTEXITCODE
        } finally {
            $env:GIT_ASK_YESNO = $oldGitAskYesNo
        }
        if ($removeExitCode -eq 0) {
            $removedCount++
            Write-Host "[KALDIRILDI] $path" -ForegroundColor Green
        } else {
            # Git for Windows can remove the administrative worktree record and
            # only then fail while unlinking a long nested path. Direct cleanup
            # is permitted solely when this exact path passed every check above
            # and Git now proves that it is no longer registered.
            $metadataCheckSucceeded = $false
            $stillRegistered = $true
            try {
                $remainingWorktrees = @(Read-Worktrees $controlPath)
                $metadataCheckSucceeded = $true
                $stillRegistered = $false
                foreach ($remainingWorktree in $remainingWorktrees) {
                    try {
                        if ((Normalize-Path $remainingWorktree.Path) -ieq (Normalize-Path $path)) {
                            $stillRegistered = $true
                            break
                        }
                    } catch {
                        $stillRegistered = $true
                        break
                    }
                }
            } catch {
                Write-Warning "Git kaldiramadi ve metadata yeniden okunamadi: $path. Fiziksel silme reddedildi."
            }

            if (-not $metadataCheckSucceeded) {
                # Conservative default: an unverifiable target is left intact.
            } elseif ($stillRegistered) {
                Write-Warning "Git kaldiramadi; worktree halen kayitli: $path (force KULLANILMADI)"
            } elseif (-not (Test-DirectoryLongPath $path)) {
                $removedCount++
                Write-Host "[KALDIRILDI] Git hata kodu dondurdu ancak klasor ve metadata artik yok: $path" -ForegroundColor Green
            } else {
                try {
                    if (Test-ReparsePoint $path) {
                        throw "Kok hedef reparse point"
                    }
                    if (Test-ContainsGitMarker $path -AllowRootGitFile) {
                        throw "Klasor agacinda .git bulundu"
                    }
                    Write-Warning "Git kaydi kaldirdi fakat klasoru tam silemedi; dogrulanmis hedef uzun-yol API'siyle tamamlaniyor: $path"
                    Remove-DirectoryTreeLongPath $path -AllowRootGitFile
                    if (Test-DirectoryLongPath $path) {
                        throw 'Fiziksel klasor kaldirma sonrasinda halen mevcut'
                    }
                    $removedCount++
                    $fallbackRemovedCount++
                    Write-Host "[KALDIRILDI: UZUN-YOL TAMAMLAMA] $path" -ForegroundColor Green
                } catch {
                    Write-Warning "Git kaydi kaldirdi ancak fiziksel kalinti guvenle temizlenemedi: $path | $($_.Exception.Message)"
                }
            }
        }
    }
}

if ($RecoverOrphanedPaths.Count -gt 0) {
    Write-Host "`n[YETIM KALINTI KURTARMA] Yalnizca acikca verilen tam yollar incelenecek." -ForegroundColor Cyan
    $primaryRepositories = [Collections.Generic.List[string]]::new()
    $primaryRepositorySet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($repo in $repositories) {
        try {
            $registeredWorktrees = @(Read-Worktrees $repo)
            if ($registeredWorktrees.Count -gt 0 -and -not $registeredWorktrees[0].Bare -and
                -not $registeredWorktrees[0].Prunable -and
                (Test-DirectoryLongPath $registeredWorktrees[0].Path)) {
                $primaryPath = Normalize-Path $registeredWorktrees[0].Path
                if ($primaryRepositorySet.Add($primaryPath)) {
                    $primaryRepositories.Add($primaryPath)
                }
            }
        } catch {
            Write-Warning "Yetim kalinti icin ana worktree okunamadi: $repo | $($_.Exception.Message)"
        }
    }

    $requestedOrphanSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($requestedPath in @($RecoverOrphanedPaths)) {
        $candidatePath = $null
        $ownerRepository = $null
        $reason = $null

        if ([string]::IsNullOrWhiteSpace($requestedPath)) {
            $reason = 'bos yol'
        } elseif ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($requestedPath)) {
            $reason = 'wildcard yasak; tam yol gerekli'
        } elseif (-not [IO.Path]::IsPathRooted($requestedPath)) {
            $reason = 'mutlak yol gerekli'
        } else {
            try { $candidatePath = Normalize-Path $requestedPath }
            catch { $reason = 'yol normalize edilemedi' }
        }

        if (-not $reason -and -not $requestedOrphanSet.Add($candidatePath)) {
            $reason = 'ayni hedef birden fazla verildi'
        }
        if (-not $reason -and -not $AllowIgnored) {
            $reason = 'metadata olmadigi icin icerik siniflandirilamaz; -AllowIgnored gerekli'
        }
        if (-not $reason -and -not (Test-InRoot $candidatePath)) {
            $reason = 'kok klasor disinda'
        }
        if (-not $reason) {
            try {
                $candidateParentInfo = [IO.Directory]::GetParent($candidatePath)
                $candidateParent = Normalize-Path $candidateParentInfo.FullName
                if ($candidateParent -ine $rootPath) {
                    $reason = 'yalnizca Root altindaki dogrudan kardes klasorler kabul edilir'
                }
            } catch { $reason = 'ust klasor dogrulanamadi' }
        }
        if (-not $reason -and -not (Test-DirectoryLongPath $candidatePath)) {
            $reason = 'klasor bulunamadi'
        }
        if (-not $reason) {
            try {
                if (Test-ReparsePoint $candidatePath) { $reason = 'kok hedef reparse point' }
            } catch { $reason = 'klasor nitelikleri okunamadi' }
        }

        $candidateName = if ($candidatePath) { [IO.Path]::GetFileName($candidatePath) } else { $requestedPath }
        if (-not $reason -and
            $candidateName -match '(?i)(^|[-_.])(preservation|preserve|backup|archive|yedek)([-_.]|$)') {
            $reason = 'koruma/yedek adi tasiyor; bu script tarafindan silinmez'
        }

        if (-not $reason) {
            $longestOwnerNameLength = -1
            foreach ($primaryRepository in $primaryRepositories) {
                try {
                    $primaryParentInfo = [IO.Directory]::GetParent($primaryRepository)
                    $primaryParent = Normalize-Path $primaryParentInfo.FullName
                    $primaryName = [IO.Path]::GetFileName($primaryRepository)
                    if ($primaryParent -ieq $rootPath -and
                        $candidateName.StartsWith($primaryName + '-', [StringComparison]::OrdinalIgnoreCase) -and
                        $primaryName.Length -gt $longestOwnerNameLength) {
                        $ownerRepository = $primaryRepository
                        $longestOwnerNameLength = $primaryName.Length
                    }
                } catch {}
            }
            if (-not $ownerRepository) {
                $reason = 'adi, Root altindaki kayitli bir ana repo ile eslesmiyor'
            }
        }

        if (-not $reason) {
            try {
                foreach ($registeredWorktree in @(Read-Worktrees $ownerRepository)) {
                    if ((Normalize-Path $registeredWorktree.Path) -ieq $candidatePath) {
                        $reason = 'halen kayitli worktree; normal guvenli akis kullanilmali'
                        break
                    }
                }
            } catch { $reason = 'Git worktree kaydi yeniden dogrulanamadi' }
        }
        if (-not $reason) {
            try {
                if (Test-ContainsGitMarker $candidatePath) {
                    $reason = 'klasor agacinda .git bulundu'
                }
            } catch { $reason = 'klasor agaci eksiksiz incelenemedi' }
        }

        if ($reason) {
            $orphanSkippedCount++
            Write-Host "[YETIM ATLANDI: $reason] $requestedPath" -ForegroundColor DarkYellow
            continue
        }

        $orphanEligibleCount++
        if (-not $Apply) {
            Write-Host "[YETIM KALDIRILABILIR] $candidatePath | ana repo: $ownerRepository" -ForegroundColor Green
            continue
        }

        try {
            Write-Host "[YETIM KALINTI KALDIRILIYOR] $candidatePath | ana repo: $ownerRepository"
            Remove-DirectoryTreeLongPath $candidatePath
            if (Test-DirectoryLongPath $candidatePath) {
                throw 'Fiziksel klasor kaldirma sonrasinda halen mevcut'
            }
            $orphanRemovedCount++
            Write-Host "[YETIM KALINTI KALDIRILDI] $candidatePath" -ForegroundColor Green
        } catch {
            $orphanSkippedCount++
            Write-Warning "Yetim kalinti guvenle kaldirilamadi: $candidatePath | $($_.Exception.Message)"
        }
    }
}

Write-Host "`n[SONUC] Repo: $($repositories.Count) | Linked worktree: $totalSecondary | Kaldirilabilir: $eligibleCount | Kaldirilan: $removedCount | Atlanan: $skippedCount" -ForegroundColor Cyan
Write-Host "[UZUN-YOL TAMAMLAMA] Kaldirilan: $fallbackRemovedCount" -ForegroundColor Cyan
Write-Host "[YETIM KALINTI] Kaldirilabilir: $orphanEligibleCount | Kaldirilan: $orphanRemovedCount | Atlanan: $orphanSkippedCount" -ForegroundColor Cyan
Write-Host 'Not: Bagimsiz git clone klasorleri ve branch''ler silinmez. Kayitsiz/eski' -NoNewline
Write-Host " worktree klasorleri kendiliginden secilmez; yalnizca -RecoverOrphanedPaths tam-yol listesiyle incelenir."
