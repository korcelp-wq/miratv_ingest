
# How to Use Dog_open.php (CVI) for Registry Communication


## ⚠️ Governance Restriction
**This endpoint is intended for AI agent, admin, and local automation use.**
For all other access patterns, refer to CVI documentation and (when available) stored procedure communication guides for proper integration.

## Purpose
This guide explains how to use the Dog_open.php endpoint (CVI) to communicate with registry databases, including uploading and retrieving instructions or operational metadata.


## 1. Endpoint
- **URL:** https://miratv.club/_workers/api/series/dog_open.php
- **Method:** HTTP POST
- **Content-Type:** application/json
- **Authentication:** token (required)

---

## 2. Uploading Data (Example)
Send a JSON body with these fields:
- `token`: Your ingest token
- `db`: Target database (e.g., PCDE_memory)
- `sql`: Parameterized SQL (use ? for values)
- `params`: Array of values for the SQL statement

### Example PowerShell
```
$body = @{
    token = 'YOUR_TOKEN'
    db    = 'PCDE_memory'
    sql   = "INSERT INTO pcde_procedure_registry (process_name, domain, topic, unit_type, instruction, created_at) VALUES (?, ?, ?, ?, ?, NOW());"
    params = @('dog_open_usage', 'governance', 'cvi_access', 'guide', 'How to use Dog_open.php for direct, governed DB access. POST JSON: token, db, sql, params. SQL must be parameterized. All actions are logged and auditable.')
} | ConvertTo-Json

Invoke-RestMethod -Uri 'https://miratv.club/_workers/api/series/dog_open.php' -Method Post -Body $body -ContentType 'application/json'
```

---

## 3. Retrieving Data (Example)
Send a JSON body with a SELECT statement:
- `sql`: e.g., "SELECT * FROM pcde_procedure_registry WHERE process_name = ?;"
- `params`: e.g., @('dog_open_usage')

### Example PowerShell
```
$body = @{
    token = 'YOUR_TOKEN'
    db    = 'PCDE_memory'
    sql   = "SELECT * FROM pcde_procedure_registry WHERE process_name = ?;"
    params = @('dog_open_usage')
} | ConvertTo-Json

Invoke-RestMethod -Uri 'https://miratv.club/_workers/api/series/dog_open.php' -Method Post -Body $body -ContentType 'application/json'
```

---

## 4. Security & Audit
- All actions require a valid token.
- All SQL must be parameterized (no direct string interpolation).
- All actions are logged and auditable by system governance.
- **Direct use is restricted to AI/admin/automation only.**

---

## 5. Troubleshooting
- 403 Forbidden: Check your token.
- Table not found: Ensure the table exists in the target DB.
- SQL error: Check your SQL and params for correctness.

---

## 6. Contact
For endpoint or schema issues, contact the system architect or registry owner.
