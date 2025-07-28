# Cache System Real Data Test Example
# This demonstrates the cache system working with real GitHub Actions upstream data

Write-Host "🚀 Testing Cache System with Real Upstream Data" -ForegroundColor Green
Write-Host "=" * 60

# Import the updated module
Import-Module .\CacheSourceListBuilder.psm1 -Force

# Test with real upstream report (using local copy)
$upstreamReportPath = ".\test-data\upstream-report.json"
$toolsetPath = "C:\Users\tameddev\Developer\pve-runner-images\images\windows\toolsets\toolset-2022.json"

Write-Host "📥 Loading upstream report from: $upstreamReportPath"
$mockUpstreamReport = @{ 
    Content = Get-Content $upstreamReportPath -Raw | ConvertFrom-Json
    Url = "file://$upstreamReportPath"
    FetchedAt = (Get-Date)
    Version = "windows-2025"
}

Write-Host "📋 Loading toolset from: $toolsetPath"
$toolsets = Get-LocalToolsets -ToolsetPaths @($toolsetPath)

Write-Host "🔍 Extracting tools from upstream report..."
$upstreamTools = Get-UpstreamTools -Report $mockUpstreamReport.Content
Write-Host "   Found $($upstreamTools.Count) upstream tools"

Write-Host "🔗 Finding tool matches..."
$toolMatches = Find-ToolMatches -UpstreamReport $mockUpstreamReport -Toolsets $toolsets
Write-Host "   Found $($toolMatches.Count) tool matches"

Write-Host "📄 Creating source list..."
$sourceListData = @{
    metadata = @{
        generatedAt = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        upstreamReport = @{
            url = $mockUpstreamReport.Url
            fetchedAt = $mockUpstreamReport.FetchedAt.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            version = $mockUpstreamReport.Version
        }
        toolsetFiles = @(
            foreach ($toolset in $toolsets) {
                @{
                    path = $toolset.Path
                    lastModified = $toolset.LastModified.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                }
            }
        )
    }
    sources = @(
        foreach ($match in $toolMatches) {
            @{
                name = $match.Name
                version = $match.Version
                platform = $match.Platform
                arch = $match.Arch
                downloadUrl = $match.DownloadUrl
                size = if ($match.Size) { $match.Size } else { 0 }
                sha256 = if ($match.Sha256) { $match.Sha256 } else { "unknown" }
                matchedFrom = @{
                    upstream = $match.MatchedFrom.Upstream
                    upstreamVersion = $match.MatchedFrom.UpstreamVersion
                    upstreamSource = $match.MatchedFrom.UpstreamSource
                    toolset = $match.MatchedFrom.Toolset
                }
            }
        }
    )
}

# Save the source list
$outputFile = ".\example-cache-sources.json"
$sourceListData | ConvertTo-Json -Depth 10 | Out-File $outputFile -Encoding UTF8

Write-Host "💾 Saved source list to: $outputFile"

# Validate against schema
Write-Host "✅ Validating against JSON schema..."
$isValid = Test-Json -Json (Get-Content $outputFile -Raw) -Schema (Get-Content ".\schemas\source-list-schema.json" -Raw)
if ($isValid) {
    Write-Host "   Schema validation: PASSED" -ForegroundColor Green
} else {
    Write-Host "   Schema validation: FAILED" -ForegroundColor Red
}

Write-Host ""
Write-Host "📊 Summary Statistics:" -ForegroundColor Cyan
Write-Host "   • Upstream tools extracted: $($upstreamTools.Count)"
Write-Host "   • Tool matches found: $($toolMatches.Count)"
Write-Host "   • Toolsets processed: $($toolsets.Count)"
Write-Host "   • Schema validation: $(if($isValid){'✅ PASSED'}else{'❌ FAILED'})"

Write-Host ""
Write-Host "🔧 Sample Tool Categories:" -ForegroundColor Cyan
$upstreamTools | Group-Object Source | ForEach-Object { 
    Write-Host "   • $($_.Name): $($_.Count) tools" 
}

Write-Host ""
Write-Host "📋 Sample Matched Tools:" -ForegroundColor Cyan
$toolMatches | Select-Object -First 8 | ForEach-Object {
    $upstreamStatus = if($_.MatchedFrom.Upstream){'✅'}else{'❌'}
    Write-Host "   • $($_.Name) $($_.Version) $upstreamStatus $(if($_.MatchedFrom.UpstreamVersion){$_.MatchedFrom.UpstreamVersion}else{'N/A'})"
}

Write-Host ""
Write-Host "🎉 Cache System Test Complete!" -ForegroundColor Green
