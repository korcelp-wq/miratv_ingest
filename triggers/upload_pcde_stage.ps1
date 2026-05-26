param(
    [string]$Token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
)

$FilePath = "C:\MiraTV_infrastructure\PARAMS_DOCS\MyAdmin SQL Dump2.txt"

$instruction = Get-Content $FilePath -Raw

$body = @{
    token = "WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY"
    database  = "xpdgxfsp_pcde_memory"
    sql   = @"
}
INSERT INTO pcde_procedure_registry_stage_ip
(
    process_name,
    domain,
    topic,
    unit_type,
    instruction,
    created_at,
    admin_access,
    source_db,
    source_table,
    provenance,
    status,
    error_count,
    vector_count
)
VALUES (?, ?, ?, ?, ?, NOW(), 'admin', ?, ?, 'file_import', 'staged', 0, 0);
"@
    params = @(
        "mysql_admin_dump_import",
        "database",
        "mysql_dump",
        "instruction",
        $instruction,
        "phpMyAdmin",
        "multiple_tables"
    )
} | ConvertTo-Json -Depth 6

Invoke-RestMethod `
    -Uri "https://miratv.club/_workers/api/series/dog_open.php?token=WYWIQAB5ICKL2VUW9PW98IYF2JMNF9XY" `
    -Method POST `
    -ContentType "application/json" `
    -Body $body
