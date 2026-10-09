param(
    [Parameter(Mandatory = $true)][ValidateRange(2000, 2100)][int]$Year,
    [Parameter(Mandatory = $true)][string[]]$SourceUrls,
    [string]$SourceLastModified = "",
    [string]$SourceManifestHash = "",
    [string]$ContainerName = "app-criminalite-db",
    [string]$DatabaseName = $env:POSTGRES_DB,
    [string]$DatabaseUser = $env:POSTGRES_USER,
    [string]$DatabasePassword = $env:POSTGRES_PASSWORD,
    [string]$Source = "dvf-geolocated"
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($DatabaseName)) { $DatabaseName = "app_criminalite" }
if ([string]::IsNullOrWhiteSpace($DatabaseUser)) { $DatabaseUser = "app" }
if ([string]::IsNullOrWhiteSpace($DatabasePassword)) { $DatabasePassword = "app_dev_password" }
if ($SourceUrls.Count -eq 0) { throw "At least one DVF source is required." }

$localSourceCount = @($SourceUrls | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count
$remoteSourceCount = $SourceUrls.Count - $localSourceCount
if ($localSourceCount -gt 0 -and $remoteSourceCount -gt 0) {
    throw "DVF sources must be either all local files or one complete national remote set."
}
if ($remoteSourceCount -gt 0) {
    $uniqueRemoteUrls = @($SourceUrls | Sort-Object -Unique)
    $validRemoteUrls = @($uniqueRemoteUrls | Where-Object {
        $_ -match "^https://files\.data\.gouv\.fr/geo-dvf/.+/$Year/departements/(?!57|67|68|976)[0-9A-Z]{2,3}\.csv\.gz$"
    })
    if ($uniqueRemoteUrls.Count -lt 90 -or $validRemoteUrls.Count -ne $uniqueRemoteUrls.Count) {
        throw "A remote DVF replacement requires one complete national set of official departmental files."
    }
}

function ConvertTo-SqlLiteral {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return "null" }
    return "'" + $Value.Replace("'", "''") + "'"
}

function ConvertTo-SqlIdentifier {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        throw "Unsupported DVF column name '$Value'."
    }
    return '"' + $Value.Replace('"', '""') + '"'
}

function Expand-DvfSource {
    param([string]$Location, [string]$WorkDirectory, [int]$Index)

    $inputPath = $Location
    if (-not (Test-Path -LiteralPath $Location -PathType Leaf)) {
        $uri = [uri]$Location
        if ($uri.Scheme -ne "https" -or $uri.Host -ne "files.data.gouv.fr" -or -not $uri.AbsolutePath.StartsWith("/geo-dvf/")) {
            throw "DVF downloads must come from https://files.data.gouv.fr/geo-dvf/."
        }
        $inputPath = Join-Path $WorkDirectory "source-$Index.download"
        Invoke-WebRequest -Uri $Location -OutFile $inputPath -TimeoutSec 300
    }

    $sourceSha256 = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $rawPath = Join-Path $WorkDirectory "source-$Index.raw"
    $sourceStream = [System.IO.File]::OpenRead($inputPath)
    try {
        $magic = New-Object byte[] 2
        $read = $sourceStream.Read($magic, 0, 2)
        $sourceStream.Position = 0
        $isGzip = $read -eq 2 -and $magic[0] -eq 0x1f -and $magic[1] -eq 0x8b
        $targetStream = [System.IO.File]::Create($rawPath)
        try {
            if ($isGzip) {
                $gzip = [System.IO.Compression.GZipStream]::new($sourceStream, [System.IO.Compression.CompressionMode]::Decompress)
                try { $gzip.CopyTo($targetStream) }
                finally { $gzip.Dispose() }
            }
            else {
                $sourceStream.CopyTo($targetStream)
            }
        }
        finally { $targetStream.Dispose() }
    }
    finally { $sourceStream.Dispose() }

    if ((Get-Item -LiteralPath $rawPath).Length -eq 0) { throw "DVF source '$Location' is empty." }

    $csvPath = Join-Path $WorkDirectory "source-$Index.csv"
    $encodings = @(
        [System.Text.UTF8Encoding]::new($false, $true),
        [System.Text.Encoding]::GetEncoding(1252)
    )
    $transcoded = $false
    foreach ($encoding in $encodings) {
        try {
            $reader = [System.IO.StreamReader]::new($rawPath, $encoding, $true, 65536)
            try {
                $writer = [System.IO.StreamWriter]::new($csvPath, $false, [System.Text.UTF8Encoding]::new($false), 65536)
                try {
                    $buffer = New-Object char[] 65536
                    while (($count = $reader.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $writer.Write($buffer, 0, $count)
                    }
                }
                finally { $writer.Dispose() }
            }
            finally { $reader.Dispose() }
            $transcoded = $true
            break
        }
        catch [System.Text.DecoderFallbackException] {
            if (Test-Path -LiteralPath $csvPath) { Remove-Item -LiteralPath $csvPath -Force }
        }
    }
    if (-not $transcoded) { throw "DVF source '$Location' is neither valid UTF-8 nor Windows-1252." }

    return [pscustomobject]@{ CsvPath = $csvPath; SourceSha256 = $sourceSha256 }
}

function Read-CsvHeader {
    param([string]$Path)
    Add-Type -AssemblyName Microsoft.VisualBasic
    $parser = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new($Path, [System.Text.Encoding]::UTF8, $true)
    try {
        $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
        $parser.SetDelimiters(",")
        $parser.HasFieldsEnclosedInQuotes = $true
        return @($parser.ReadFields() | ForEach-Object { $_.Trim().TrimStart([char]0xfeff) })
    }
    finally { $parser.Dispose() }
}

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "app-criminalite-dvf-$PID"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

try {
    $csvFiles = @()
    $sourceFileSha256 = @()
    $header = $null
    for ($index = 0; $index -lt $SourceUrls.Count; $index++) {
        $expanded = Expand-DvfSource -Location $SourceUrls[$index] -WorkDirectory $workDir -Index $index
        $csvPath = $expanded.CsvPath
        $currentHeader = @(Read-CsvHeader -Path $csvPath)
        if ($currentHeader.Count -eq 0) { throw "DVF source '$($SourceUrls[$index])' has no header." }
        if ($null -eq $header) { $header = $currentHeader }
        elseif (($header -join "`n") -ne ($currentHeader -join "`n")) {
            throw "DVF resources do not share the same schema. No data was imported."
        }
        $csvFiles += $csvPath
        $sourceFileSha256 += [ordered]@{ url = $SourceUrls[$index]; sha256 = $expanded.SourceSha256 }
    }

    $requiredColumns = @(
        "id_mutation", "date_mutation", "nature_mutation", "valeur_fonciere",
        "code_commune", "type_local", "surface_reelle_bati"
    )
    foreach ($requiredColumn in $requiredColumns) {
        if ($header -notcontains $requiredColumn) {
            throw "DVF CSV is missing required column '$requiredColumn'. No data was imported."
        }
    }
    $lotIdentityColumns = if ($header -contains "lot1_numero") {
        @(1..5 | ForEach-Object { "lot${_}_numero" })
    }
    else {
        @(1..5 | ForEach-Object { "lot_${_}_numero" })
    }
    if ($header -notcontains "id_local") {
        $fallbackIdentityColumns = @(
            "numero_disposition", "adresse_numero", "adresse_code_voie"
        ) + $lotIdentityColumns + @("nombre_pieces_principales")
        foreach ($identityColumn in $fallbackIdentityColumns) {
            if ($header -notcontains $identityColumn) {
                throw "DVF CSV needs either id_local or fallback identity column '$identityColumn'. No data was imported."
            }
        }
    }

    $manifestMaterial = @($sourceFileSha256 | ForEach-Object { "$($_.url)|$($_.sha256)" } | Sort-Object)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($manifestMaterial -join "`n"))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $contentManifestHash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant() }
    finally { $sha.Dispose() }

    $copyCommands = @()
    for ($index = 0; $index -lt $csvFiles.Count; $index++) {
        $containerPath = "/tmp/dvf-property-$Year-$index.csv"
        docker cp $csvFiles[$index] "${ContainerName}:$containerPath"
        if ($LASTEXITCODE -ne 0) { throw "Could not copy DVF resource $index into '$ContainerName'." }
        $copyCommands += "\copy dvf_raw from '$containerPath' with (format csv, header true, delimiter ',', quote '""', encoding 'UTF8')"
    }

    $columnDefinitions = ($header | ForEach-Object { "$(ConvertTo-SqlIdentifier $_) text" }) -join ",`n    "
    $localIdExpression = if ($header -contains "id_local") {
        "nullif(trim(id_local), '')"
    }
    else {
$lot1Column = $lotIdentityColumns[0]
$lot2Column = $lotIdentityColumns[1]
$lot3Column = $lotIdentityColumns[2]
$lot4Column = $lotIdentityColumns[3]
$lot5Column = $lotIdentityColumns[4]
@"
case trim(type_local)
    when 'Appartement' then concat_ws('|',
        'apartment', coalesce(trim(numero_disposition), ''),
        coalesce(trim(adresse_numero), ''), coalesce(trim(adresse_code_voie), ''),
        coalesce(trim($lot1Column), ''), coalesce(trim($lot2Column), ''),
        coalesce(trim($lot3Column), ''), coalesce(trim($lot4Column), ''),
        coalesce(trim($lot5Column), ''), coalesce(trim(surface_reelle_bati), ''),
        coalesce(trim(nombre_pieces_principales), ''))
    when 'Maison' then concat_ws('|',
        'house', coalesce(trim(numero_disposition), ''),
        coalesce(trim(adresse_numero), ''), coalesce(trim(adresse_code_voie), ''),
        coalesce(trim(surface_reelle_bati), ''), coalesce(trim(nombre_pieces_principales), ''))
    else null
end
"@
    }
    $sourceLiteral = ConvertTo-SqlLiteral $Source
    $lastModifiedLiteral = ConvertTo-SqlLiteral $SourceLastModified
    $catalogManifestHashLiteral = ConvertTo-SqlLiteral $SourceManifestHash
    $contentManifestHashLiteral = ConvertTo-SqlLiteral $contentManifestHash
    $metadata = @{
        sourceUrls = @($SourceUrls)
        sourceLastModified = $SourceLastModified
        sourceManifestHash = $SourceManifestHash
        sourceFileSha256 = @($sourceFileSha256)
        contentManifestHash = $contentManifestHash
        sourceColumns = @($header)
    } | ConvertTo-Json -Compress -Depth 5
    $metadataLiteral = ConvertTo-SqlLiteral $metadata
    $productionCoverageGuard = if (($SourceUrls | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }).Count -eq $SourceUrls.Count -and $SourceUrls.Count -ge 50) {
@"
    if (select count(*) from dvf_raw) < 100000 then
        raise exception 'DVF source appears incomplete: fewer than 100000 raw rows';
    end if;
"@
    } else { "" }

    $sql = @"
\set ON_ERROR_STOP on
begin;

create temp table dvf_raw (
    $columnDefinitions
) on commit drop;

$($copyCommands -join "`n")

do `$guard`$
begin
    if not exists (select 1 from dvf_raw) then
        raise exception 'DVF source contains no data rows';
    end if;
    if exists (
        select 1 from dvf_raw
        where date_mutation ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
          and extract(year from date_mutation::date) <> $Year
    ) then
        raise exception 'DVF source contains a mutation outside requested year $Year';
    end if;
$productionCoverageGuard
end
`$guard`$;

delete from property_sale_observations
where source_system = $sourceLiteral and source_year = $Year;

insert into import_batches(source_system, source_url, source_year, status, metadata, completed_at)
values ($sourceLiteral, $(ConvertTo-SqlLiteral $SourceUrls[0]), $Year, 'completed', $metadataLiteral::jsonb, now())
returning id as import_batch_id \gset

create temp table dvf_normalized on commit drop as
select
    nullif(trim(id_mutation), '') as mutation_id,
    case when date_mutation ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then date_mutation::date end as mutation_date,
    nullif(trim(nature_mutation), '') as mutation_nature,
    case
        when replace(replace(trim(valeur_fonciere), ' ', ''), ',', '.') ~ '^[0-9]+(?:\.[0-9]+)?$'
        then replace(replace(trim(valeur_fonciere), ' ', ''), ',', '.')::numeric
    end as sale_value,
    nullif(trim(code_commune), '') as city_insee_code,
    $localIdExpression as local_id,
    case trim(type_local)
        when 'Appartement' then 'apartment'
        when 'Maison' then 'house'
        else null
    end as property_type,
    case
        when replace(replace(trim(surface_reelle_bati), ' ', ''), ',', '.') ~ '^[0-9]+(?:\.[0-9]+)?$'
        then replace(replace(trim(surface_reelle_bati), ' ', ''), ',', '.')::numeric
    end as built_area
from dvf_raw;

create temp table dvf_eligible on commit drop as
with mutation_summary as (
    select
        mutation_id,
        min(mutation_date) as mutation_date,
        min(mutation_nature) as mutation_nature,
        min(sale_value) as sale_value,
        min(city_insee_code) as city_insee_code,
        min(property_type) filter (where property_type is not null) as property_type,
        min(built_area) filter (where property_type is not null) as built_area,
        count(distinct mutation_date) as date_count,
        count(distinct mutation_nature) as nature_count,
        count(distinct sale_value) as sale_value_count,
        count(distinct city_insee_code) as city_count,
        count(distinct local_id) filter (where property_type is not null) as residential_local_count,
        count(distinct property_type) filter (where property_type is not null) as property_type_count,
        count(distinct built_area) filter (where property_type is not null) as built_area_count
    from dvf_normalized
    where mutation_id is not null
    group by mutation_id
)
select summary.*
from mutation_summary summary
join cities city on city.insee_code = summary.city_insee_code
where summary.date_count = 1
  and extract(year from summary.mutation_date) = $Year
  and summary.nature_count = 1
  and summary.mutation_nature in ('Vente', U&'Vente en l''\00E9tat futur d''ach\00E8vement', 'Adjudication')
  and summary.sale_value_count = 1
  and summary.sale_value > 0
  and summary.city_count = 1
  and summary.residential_local_count = 1
  and summary.property_type_count = 1
  and summary.built_area_count = 1
  and summary.built_area > 0;

insert into property_sale_observations(
    source_system, source_year, mutation_id, city_insee_code, mutation_date,
    mutation_nature, property_type, sale_value, built_area, import_batch_id
)
select
    $sourceLiteral, $Year, eligible.mutation_id, eligible.city_insee_code,
    eligible.mutation_date, eligible.mutation_nature, eligible.property_type,
    eligible.sale_value, eligible.built_area, :import_batch_id
from dvf_eligible eligible;

update import_batches
set metadata = metadata || jsonb_build_object(
    'rawRowCount', (select count(*) from dvf_raw),
    'rawMutationCount', (select count(distinct mutation_id) from dvf_normalized),
    'retainedMutationCount', (select count(*) from dvf_eligible),
    'excludedMutationCount', (select count(distinct mutation_id) from dvf_normalized) - (select count(*) from dvf_eligible),
    'catalogLastModified', $lastModifiedLiteral,
    'catalogManifestHash', $catalogManifestHashLiteral,
    'contentManifestHash', $contentManifestHashLiteral
)
where id = :import_batch_id;

select refresh_property_market_metrics($Year::smallint);
commit;
"@

    $sqlPath = Join-Path $workDir "import-dvf.sql"
    [System.IO.File]::WriteAllText($sqlPath, $sql, [System.Text.UTF8Encoding]::new($false))
    docker cp $sqlPath "${ContainerName}:/tmp/import-dvf-property.sql"
    if ($LASTEXITCODE -ne 0) { throw "Could not copy generated DVF SQL into '$ContainerName'." }

    docker exec -e "PGPASSWORD=$DatabasePassword" $ContainerName `
        psql -v ON_ERROR_STOP=1 -U $DatabaseUser -d $DatabaseName -f "/tmp/import-dvf-property.sql"
    if ($LASTEXITCODE -ne 0) { throw "DVF property sale import failed; the previous year remains active." }
}
finally {
    if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
}
