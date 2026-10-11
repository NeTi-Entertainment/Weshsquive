param(
    [ValidateRange(2000, 2100)]
    [int]$Year = 2025,
    [string]$CsvPath,
    [string]$ContainerName = "app-criminalite-db",
    [string]$DatabaseName = $env:POSTGRES_DB,
    [string]$DatabaseUser = $env:POSTGRES_USER,
    [string]$DatabasePassword = $env:POSTGRES_PASSWORD
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($DatabaseName)) { $DatabaseName = "app_criminalite" }
if ([string]::IsNullOrWhiteSpace($DatabaseUser)) { $DatabaseUser = "app" }
if ([string]::IsNullOrWhiteSpace($DatabasePassword)) { $DatabasePassword = "app_dev_password" }

$invariantCulture = [System.Globalization.CultureInfo]::InvariantCulture
$numberStyles = [System.Globalization.NumberStyles]::Float
$categoryCount = 6

function Convert-NullableDecimal {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    return [decimal]::Parse([string]$Value, $numberStyles, $invariantCulture)
}

function Format-NullableNumber {
    param([AllowNull()][object]$Value, [string]$Format = "0.0")

    if ($null -eq $Value) { return "" }
    return ([decimal]$Value).ToString($Format, $invariantCulture)
}

function Get-ScoreBand {
    param([AllowNull()][object]$Score)

    if ($null -eq $Score) { return "Indisponible" }
    $Score = [decimal]$Score
    if ($Score -le 10) { return "0-10" }
    if ($Score -le 35) { return ">10-35" }
    if ($Score -le 50) { return ">35-50" }
    if ($Score -le 65) { return ">50-65" }
    if ($Score -le 85) { return ">65-85" }
    return ">85-100"
}

function Get-ProvenanceLabel {
    param([string]$Code)

    switch ($Code) {
        "published-only" { return "Données communales année cible" }
        "historical-published" { return "Données communales avec historique" }
        "partially-estimated" { return "Partiellement estimé" }
        "estimated-only" { return "Entièrement estimé" }
        default { return "Indisponible" }
    }
}

function Format-Percent {
    param([int]$Count, [int]$Denominator)

    if ($Denominator -eq 0) { return "0.0%" }
    return ((100.0 * $Count / $Denominator).ToString("0.0", $invariantCulture) + "%")
}

$query = @"
begin transaction read only;
with active_snapshot as (
    select snapshot_id from search_metrics_active where singleton
), target_cities as (
    select
        comparative.snapshot_id,
        comparative.city_insee_code,
        city.name as city_name,
        comparative.population,
        comparative.comparative_index as current_score,
        comparative.comparative_index_status,
        comparative.comparative_index_provenance,
        comparative.effective_basket_category_count,
        comparative.basket_index_coverage,
        comparative.published_basket_category_count,
        comparative.historical_published_basket_category_count,
        comparative.estimated_basket_category_count,
        comparative.low_volume_cap_applied
    from active_snapshot active
    join search_metrics_city_year_comparative comparative
      on comparative.snapshot_id = active.snapshot_id
     and comparative.year = $Year
    join cities city on city.insee_code = comparative.city_insee_code
), category_rows as (
    select
        target.snapshot_id,
        target.city_insee_code,
        anchor.category_code,
        anchor.availability_bit::integer as availability_bit,
        anchor.rate_denominator,
        anchor.count_unit,
        anchor.anchor_rate_per_1000,
        coalesce(category_snapshot.category_label, category.label, anchor.category_code) as category_label,
        category_snapshot.publication_status::text as target_publication_status,
        category_snapshot.incident_count as target_incident_count,
        category_snapshot.rate_per_1000 as target_rate_per_1000,
        category_snapshot.count_unit as target_count_unit,
        category_snapshot.rate_denominator as target_rate_denominator,
        category_snapshot.complement_info_taux as target_complement_rate,
        category_snapshot.category_exposure_score as exposure_score,
        category_snapshot.category_exposure_source_year as exposure_source_year,
        category_snapshot.category_exposure_rate_per_1000 as exposure_rate,
        category_snapshot.category_exposure_source as exposure_source
    from target_cities target
    cross join exposure_index_category_anchors anchor
    left join search_metrics_city_year_category category_snapshot
      on category_snapshot.snapshot_id = target.snapshot_id
     and category_snapshot.city_insee_code = target.city_insee_code
     and category_snapshot.year = $Year
     and category_snapshot.category_code = anchor.category_code
    left join crime_categories category on category.code = anchor.category_code
), baseline_components as (
    select
        row.*,
        case
            when row.target_publication_status = 'published'
              and row.target_rate_per_1000 is not null
              and row.target_rate_per_1000 >= 0
              and row.target_count_unit = row.count_unit
              and row.target_rate_denominator = row.rate_denominator
                then round(least(100::numeric, row.target_rate_per_1000 / row.anchor_rate_per_1000 * 100), 4)
            when row.target_publication_status = 'masked'
              and row.target_complement_rate is not null
              and row.target_complement_rate >= 0
              and row.target_count_unit = row.count_unit
              and row.target_rate_denominator = row.rate_denominator
                then round(least(100::numeric, row.target_complement_rate / row.anchor_rate_per_1000 * 100), 4)
            else null
        end as baseline_component_score
    from category_rows row
), baseline_summary as (
    select
        city_insee_code,
        count(baseline_component_score)::integer as baseline_component_count,
        avg(baseline_component_score) as baseline_average_score,
        count(*) filter (where target_publication_status = 'published')::integer
            as target_published_count,
        count(*) filter (
            where category_code in (
                'ssmsi-78384436563146dc6167ea53b7b5e0cd',
                'ssmsi-bf6b19b3e53b90f6594ec2e8303c5778'
            )
              and target_publication_status = 'published'
              and target_count_unit = 'Infraction'
              and target_incident_count is not null
        ) = 2 as has_two_published_infraction_counts,
        sum(target_incident_count) filter (
            where category_code in (
                'ssmsi-78384436563146dc6167ea53b7b5e0cd',
                'ssmsi-bf6b19b3e53b90f6594ec2e8303c5778'
            )
              and target_publication_status = 'published'
              and target_count_unit = 'Infraction'
              and target_incident_count is not null
        ) as target_published_infraction_count
    from baseline_components
    group by city_insee_code
), components_json as (
    select
        city_insee_code,
        jsonb_agg(jsonb_build_object(
            'category_code', category_code,
            'category_label', category_label,
            'availability_bit', availability_bit,
            'count_unit', count_unit,
            'rate_denominator', rate_denominator,
            'exposure_score', exposure_score,
            'exposure_source_year', exposure_source_year,
            'exposure_rate', exposure_rate,
            'exposure_source', exposure_source
        ) order by availability_bit)::text as components_json
    from category_rows
    group by city_insee_code
)
select
    target.snapshot_id,
    target.city_insee_code,
    target.city_name,
    target.population,
    target.current_score,
    target.comparative_index_status,
    target.comparative_index_provenance,
    coalesce(target.effective_basket_category_count, 0) as effective_basket_category_count,
    target.basket_index_coverage,
    target.published_basket_category_count,
    target.historical_published_basket_category_count,
    target.estimated_basket_category_count,
    target.low_volume_cap_applied,
    case
        when baseline.baseline_component_count < 3 then null
        when baseline.has_two_published_infraction_counts
          and baseline.target_published_infraction_count < 10
          and baseline.target_published_count >= 5
          and baseline.baseline_average_score > 35 then 35::numeric
        else round(baseline.baseline_average_score, 1)
    end as baseline_score,
    baseline.baseline_component_count,
    components.components_json
from target_cities target
join baseline_summary baseline using (city_insee_code)
join components_json components using (city_insee_code)
order by target.city_insee_code;
commit;
"@

$arguments = @(
    "exec", "-e", "PGPASSWORD=$DatabasePassword", $ContainerName,
    "psql", "-X", "-q", "--csv", "-v", "ON_ERROR_STOP=1",
    "-U", $DatabaseUser, "-d", $DatabaseName, "-c", $query
)
$bandOrder = @("0-10", ">10-35", ">35-50", ">50-65", ">65-85", ">85-100", "Indisponible")
$provenanceOrder = @(
    "Données communales année cible",
    "Données communales avec historique",
    "Partiellement estimé",
    "Entièrement estimé",
    "Indisponible"
)
$flagGroups = @(
    @{ Label = "Score <=35 avec au moins une composante >=85" },
    @{ Label = "Score <=35 avec au moins deux composantes >=65" },
    @{ Label = "Score >50 avec toutes les composantes disponibles <=35" },
    @{ Label = "Couverture exactement 3/6" },
    @{ Label = "Historique modifie le score d'au moins 15 points" }
)
$bandCounts = @{}
$provenanceCounts = @{}
$provenanceBandCounts = @{}
$flagCounts = @{}
$flagPreviews = @{}
foreach ($band in $bandOrder) { $bandCounts[$band] = 0 }
foreach ($provenance in $provenanceOrder) {
    $provenanceCounts[$provenance] = 0
    $provenanceBandCounts[$provenance] = @{}
    foreach ($band in $bandOrder) { $provenanceBandCounts[$provenance][$band] = 0 }
}
foreach ($flagGroup in $flagGroups) {
    $flagCounts[$flagGroup.Label] = 0
    $flagPreviews[$flagGroup.Label] = [System.Collections.Generic.List[object]]::new()
}
$selected = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
$bottomTen = [System.Collections.Generic.List[object]]::new()
$topTen = [System.Collections.Generic.List[object]]::new()
$totalCities = 0

function Add-BoundedCandidate {
    param(
        [System.Collections.Generic.List[object]]$List,
        [object]$Candidate,
        [ValidateSet("ascending", "descending")][string]$Order
    )

    $insertAt = $List.Count
    for ($index = 0; $index -lt $List.Count; $index++) {
        $existing = $List[$index]
        $scoreComparison = [decimal]::Compare([decimal]$Candidate.Score, [decimal]$existing.Score)
        if ($scoreComparison -eq 0) {
            $nameComparison = [string]::Compare([string]$Candidate.Name, [string]$existing.Name, [System.StringComparison]::OrdinalIgnoreCase)
            if ($nameComparison -eq 0) {
                $nameComparison = [string]::Compare([string]$Candidate.Code, [string]$existing.Code, [System.StringComparison]::Ordinal)
            }
            $comesBefore = $nameComparison -lt 0
        } elseif ($Order -eq "ascending") {
            $comesBefore = $scoreComparison -lt 0
        } else {
            $comesBefore = $scoreComparison -gt 0
        }

        if ($comesBefore) { $insertAt = $index; break }
    }

    if ($insertAt -lt 10) {
        $List.Insert($insertAt, $Candidate)
        if ($List.Count -gt 10) { $List.RemoveAt(10) }
    }
}

function Add-AuditRecord {
    param([Parameter(Mandatory = $true)][object]$Record)

    $score = Convert-NullableDecimal $record.current_score
    $baselineScore = Convert-NullableDecimal $record.baseline_score
    $components = @($record.components_json | ConvertFrom-Json)
    $componentScores = [System.Collections.Generic.List[decimal]]::new()
    foreach ($component in $components) {
        $componentScore = Convert-NullableDecimal $component.exposure_score
        if ($null -ne $componentScore) { $componentScores.Add([decimal]$componentScore) }
    }
    $provenanceCode = [string]$record.comparative_index_provenance
    $provenanceLabel = Get-ProvenanceLabel $provenanceCode
    if ($null -eq $score) { $provenanceLabel = "Indisponible" }

    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $score -and $score -le 35 -and @($componentScores | Where-Object { $_ -ge 85 }).Count -ge 1) {
        $reasons.Add("Score <=35 avec au moins une composante >=85")
    }
    if ($null -ne $score -and $score -le 35 -and @($componentScores | Where-Object { $_ -ge 65 }).Count -ge 2) {
        $reasons.Add("Score <=35 avec au moins deux composantes >=65")
    }
    if ($null -ne $score -and $score -gt 50 -and $componentScores.Count -gt 0 -and
        @($componentScores | Where-Object { $_ -gt 35 }).Count -eq 0) {
        $reasons.Add("Score >50 avec toutes les composantes disponibles <=35")
    }
    $coverage = [int]$record.effective_basket_category_count
    if ($null -ne $score -and $coverage -eq 3) {
        $reasons.Add("Couverture exactement 3/6")
    }

    $historyDelta = $null
    if ($null -ne $score -and $null -ne $baselineScore -and
        [int]$record.historical_published_basket_category_count -gt 0) {
        $historyDelta = [math]::Round([decimal]::Abs($score - $baselineScore), 1)
        if ($historyDelta -ge 15) {
            $reasons.Add("Historique modifie le score d'au moins 15 points")
        }
    }

    $row = [ordered]@{
        city_name = [string]$record.city_name
        city_code = [string]$record.city_insee_code
        population = if ([string]::IsNullOrWhiteSpace([string]$record.population)) { "" } else { [string]$record.population }
        score = Format-NullableNumber $score "0.0"
        score_band = Get-ScoreBand $score
        coverage_count = [string]$record.effective_basket_category_count
        coverage_total = [string]$categoryCount
        coverage_percent = Format-NullableNumber ([decimal]$record.effective_basket_category_count * 100 / $categoryCount) "0.0"
        global_provenance = $provenanceLabel
        global_provenance_code = $provenanceCode
        comparative_index_status = [string]$record.comparative_index_status
        baseline_score = Format-NullableNumber $baselineScore "0.0"
        baseline_coverage_count = [string]$record.baseline_component_count
        history_delta = Format-NullableNumber $historyDelta "0.0"
        low_volume_cap_applied = if ([string]$record.low_volume_cap_applied -in @("t", "true")) { "true" } else { "false" }
        audit_reasons = ($reasons -join "; ")
        report_sections = ""
    }

    foreach ($component in $components) {
        $bit = [int]$component.availability_bit
        $row["component_${bit}_category_code"] = [string]$component.category_code
        $row["component_${bit}_category_label"] = [string]$component.category_label
        $row["component_${bit}_score"] = Format-NullableNumber (Convert-NullableDecimal $component.exposure_score) "0.0000"
        $row["component_${bit}_rate_per_1000"] = Format-NullableNumber (Convert-NullableDecimal $component.exposure_rate) "0.000000"
        $row["component_${bit}_source_year"] = if ($null -eq $component.exposure_source_year) { "" } else { [string]$component.exposure_source_year }
        $row["component_${bit}_source"] = if ($null -eq $component.exposure_source) { "unavailable" } else { [string]$component.exposure_source }
        $row["component_${bit}_count_unit"] = [string]$component.count_unit
        $row["component_${bit}_rate_denominator"] = [string]$component.rate_denominator
    }

    $city = [pscustomobject]@{
        Name = [string]$record.city_name
        Code = [string]$record.city_insee_code
        Population = $row.population
        Score = $score
        Band = $row.score_band
        Coverage = $coverage
        Provenance = $provenanceLabel
        ProvenanceCode = $provenanceCode
        Reasons = $reasons.ToArray()
        ExportRow = [pscustomobject]$row
    }

    $script:totalCities++
    $script:bandCounts[$city.Band]++
    $script:provenanceCounts[$city.Provenance]++
    $script:provenanceBandCounts[$city.Provenance][$city.Band]++

    foreach ($flagGroup in $script:flagGroups) {
        if ($city.Reasons -contains $flagGroup.Label) {
            $script:flagCounts[$flagGroup.Label]++
            if ($script:flagPreviews[$flagGroup.Label].Count -lt 20) {
                $script:flagPreviews[$flagGroup.Label].Add($city)
            }
        }
    }

    if ($city.Reasons.Count -gt 0) {
        $city.ExportRow.report_sections = "Anomalie"
        $script:selected[$city.Code] = $city
    }
    if ($null -ne $score -and $coverage -ge 5) {
        Add-BoundedCandidate -List $script:bottomTen -Candidate $city -Order "ascending"
        Add-BoundedCandidate -List $script:topTen -Candidate $city -Order "descending"
    }
}

$processInfo = [System.Diagnostics.ProcessStartInfo]::new()
$processInfo.FileName = (Get-Command docker -ErrorAction Stop).Source
$processInfo.UseShellExecute = $false
$processInfo.RedirectStandardOutput = $true
$processInfo.RedirectStandardError = $true
$processInfo.StandardOutputEncoding = [System.Text.Encoding]::UTF8
$processInfo.StandardErrorEncoding = [System.Text.Encoding]::UTF8
$processInfo.CreateNoWindow = $true
foreach ($argument in $arguments) { $processInfo.ArgumentList.Add([string]$argument) }

$databaseProcess = [System.Diagnostics.Process]::new()
$databaseProcess.StartInfo = $processInfo
if (-not $databaseProcess.Start()) { throw "Could not start the read-only database query." }
$stderrTask = $databaseProcess.StandardError.ReadToEndAsync()
try {
    $reader = $databaseProcess.StandardOutput
    $headerLine = $reader.ReadLine()
    if ($null -eq $headerLine) {
        $databaseProcess.WaitForExit()
        $errorText = $stderrTask.GetAwaiter().GetResult()
        throw "Read-only exposure calibration query returned no CSV header. $errorText"
    }

    $headers = $headerLine.TrimStart([char]0xFEFF).Split(',')
    while ($null -ne ($line = $reader.ReadLine())) {
        foreach ($record in (ConvertFrom-Csv -InputObject $line -Header $headers -Delimiter ',')) {
            Add-AuditRecord -Record $record
        }
    }

    $databaseProcess.WaitForExit()
    $errorText = $stderrTask.GetAwaiter().GetResult()
    if ($databaseProcess.ExitCode -ne 0) {
        throw "Read-only exposure calibration query failed: $errorText"
    }
} finally {
    if (-not $databaseProcess.HasExited) {
        $databaseProcess.Kill()
        $databaseProcess.WaitForExit()
    }
    $databaseProcess.Dispose()
}

if ($totalCities -eq 0) {
    throw "No active-snapshot comparative metrics were found for $Year. Check that the year is imported and its snapshot is active."
}

Write-Host "Audit de calibration de l'indice d'exposition - $Year"
Write-Host "Communes analysées : $totalCities"
Write-Host "Bandes de score (pourcentage du total) :"
foreach ($band in $bandOrder) {
    $count = $bandCounts[$band]
    Write-Host ("  {0,-14} {1,7}  {2,6}" -f $band, $count, (Format-Percent $count $totalCities))
}

Write-Host "Distribution par provenance globale (pourcentage du groupe) :"
foreach ($provenance in $provenanceOrder) {
    $groupCount = $provenanceCounts[$provenance]
    if ($groupCount -eq 0) { continue }
    Write-Host ("  {0} ({1})" -f $provenance, $groupCount)
    foreach ($band in $bandOrder) {
        $count = $provenanceBandCounts[$provenance][$band]
        if ($count -gt 0) {
            Write-Host ("    {0,-14} {1,7}  {2,6}" -f $band, $count, (Format-Percent $count $groupCount))
        }
    }
}

$bottomTen = @($bottomTen)
$topTen = @($topTen)

Write-Host "Communes aux scores les plus faibles (couverture >=5/6) :"
if ($bottomTen.Count -eq 0) { Write-Host "  Aucune commune admissible." }
foreach ($city in $bottomTen) {
    Write-Host ("  {0} ({1})  {2}/100  {3}/6  {4}" -f $city.Name, $city.Code, (Format-NullableNumber $city.Score "0.0"), $city.Coverage, $city.Provenance)
}
Write-Host "Communes aux scores les plus élevés (couverture >=5/6) :"
if ($topTen.Count -eq 0) { Write-Host "  Aucune commune admissible." }
foreach ($city in $topTen) {
    Write-Host ("  {0} ({1})  {2}/100  {3}/6  {4}" -f $city.Name, $city.Code, (Format-NullableNumber $city.Score "0.0"), $city.Coverage, $city.Provenance)
}

Write-Host "Cas a inspecter :"
foreach ($flagGroup in $flagGroups) {
    $previewCities = $flagPreviews[$flagGroup.Label]
    Write-Host ("  {0}: {1}" -f $flagGroup.Label, $flagCounts[$flagGroup.Label])
    foreach ($city in $previewCities) {
        Write-Host ("    {0} ({1})  score={2}  couverture={3}/6  population={4}" -f $city.Name, $city.Code, (Format-NullableNumber $city.Score "0.0"), $city.Coverage, $city.Population)
    }
    if ($flagCounts[$flagGroup.Label] -gt 20) { Write-Host ("    ... {0} autres dans le CSV" -f ($flagCounts[$flagGroup.Label] - 20)) }
}

foreach ($city in $bottomTen) {
    if ($selected.ContainsKey($city.Code)) {
        $selected[$city.Code].ExportRow.report_sections += "; Top/bottom 10"
    } else {
        $city.ExportRow.report_sections = "Top/bottom 10"
        $selected[$city.Code] = $city
    }
}
foreach ($city in $topTen) {
    if ($selected.ContainsKey($city.Code)) {
        if ($selected[$city.Code].ExportRow.report_sections -notmatch "Top/bottom 10") {
            $selected[$city.Code].ExportRow.report_sections += "; Top/bottom 10"
        }
    } else {
        $city.ExportRow.report_sections = "Top/bottom 10"
        $selected[$city.Code] = $city
    }
}

$resolvedCsvPath = if ([string]::IsNullOrWhiteSpace($CsvPath)) {
    Join-Path (Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..")).Path "reports") "exposure-calibration-$Year.csv"
} elseif ([System.IO.Path]::IsPathRooted($CsvPath)) {
    $CsvPath
} else {
    Join-Path (Get-Location).Path $CsvPath
}
$csvDirectory = Split-Path -Parent $resolvedCsvPath
if (-not (Test-Path -LiteralPath $csvDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $csvDirectory -Force | Out-Null
}

$exportRows = @($selected.Values | Sort-Object { $_.ExportRow.city_code } | ForEach-Object { $_.ExportRow })
if ($exportRows.Count -gt 0) {
    $exportRows | Export-Csv -LiteralPath $resolvedCsvPath -NoTypeInformation -Encoding utf8
} else {
    $headers = @(
        "city_name", "city_code", "population", "score", "score_band", "coverage_count", "coverage_total",
        "coverage_percent", "global_provenance", "global_provenance_code", "comparative_index_status",
        "baseline_score", "baseline_coverage_count", "history_delta", "low_volume_cap_applied",
        "audit_reasons", "report_sections"
    )
    foreach ($bit in 0..5) {
        $headers += @(
            "component_${bit}_category_code", "component_${bit}_category_label", "component_${bit}_score",
            "component_${bit}_rate_per_1000", "component_${bit}_source_year", "component_${bit}_source",
            "component_${bit}_count_unit", "component_${bit}_rate_denominator"
        )
    }
    Set-Content -LiteralPath $resolvedCsvPath -Value ($headers -join ",") -Encoding utf8
}

Write-Host "Lignes détail/anomalies exportées : $($exportRows.Count)"
Write-Host "CSV : $resolvedCsvPath"
Write-Host "Lecture seule : requête exécutée dans une transaction PostgreSQL READ ONLY; aucune reconstruction d'instantané."
