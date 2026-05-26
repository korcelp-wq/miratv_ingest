param(
    [string]$Token,
    [string]$InstructionFile,  # Path to .md or .txt doc
    [string]$ProcessName,
    [string]$Domain,
    [string]$Topic,
    [string]$UnitType
)

$endpoint = 'https://miratv.club/_workers/Dog_open.php'
$instructionText = Get-Content $InstructionFile -Raw

$body = @{
    token = $Token
    db    = 'PCDE_memory'
    sql   = "INSERT INTO pcde_procedure_registry (process_name, domain, topic, unit_type, instruction, created_at) VALUES (?, ?, ?, ?, ?, NOW());"
    params = @($ProcessName, $Domain, $Topic, $UnitType, $instructionText)
} | ConvertTo-Json

Invoke-RestMethod -Uri $endpoint -Method Post -Body $body -ContentType 'application/json'
