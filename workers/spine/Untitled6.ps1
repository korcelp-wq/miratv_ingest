# Run this in PowerShell to teach your AI about stored procedures

cd C:\miratv_ingest\dashboard

# Teaching Round 1: The Concept
.\Query.ps1 -Sql @"
INSERT INTO pcde_ai_memory 
(agent_name, memory_type, key_data, confidence, created_at)
VALUES 
('homegrown_ai', 'architecture', 
 'Stored procedures are the ONLY way to communicate between components. Never use direct SQL. Call sp_get_active_working_memory() to see active sessions.', 
 1.0, NOW())
"@

# Teaching Round 2: Available Procedures
.\Query.ps1 -Sql @"
INSERT INTO pcde_ai_memory 
(agent_name, memory_type, key_data, confidence, created_at)
VALUES 
('homegrown_ai', 'tool', 
 'Procedure: sp_get_active_working_memory(db: pcde_memory) - Returns all active working memory sessions. No parameters needed.',
 1.0, NOW())
"@

# Teaching Round 3: How to Call Them
.\Query.ps1 -Sql @"
INSERT INTO pcde_ai_memory 
(agent_name, memory_type, key_data, confidence, created_at)
VALUES 
('homegrown_ai', 'pattern', 
 'To call a stored procedure: Invoke-DogOpenProcedure -ProcedureName "sp_name" -Db "database" -Params @(param1, param2). Example: Invoke-DogOpenProcedure -ProcedureName "sp_get_active_working_memory" -Db "pcde_memory"',
 1.0, NOW())
"@

# Teaching Round 4: Why This Matters
.\Query.ps1 -Sql @"
INSERT INTO pcde_ai_memory 
(agent_name, memory_type, key_data, confidence, created_at)
VALUES 
('homegrown_ai', 'principle', 
 'Direct SQL is for humans only. AI agents must use stored procedures for: 1) Security (whitelisted procs only), 2) Governance (every call is audited), 3) Stability (procs don't change, tables might)',
 0.98, NOW())
"@

# Teaching Round 5: Example - Get Failures
.\Query.ps1 -Sql @"
INSERT INTO pcde_ai_memory 
(agent_name, memory_type, key_data, confidence, created_at)
VALUES 
('homegrown_ai', 'example', 
 'To check recent failures: Create procedure sp_get_recent_failures() in pcde_memory that SELECTs from pcde_procedure_failure. Then call it via Invoke-DogOpenProcedure.',
 0.95, NOW())
"@

# Teaching Round 6: Security Contract
.\Query.ps1 -Sql @"
INSERT INTO pcde_ai_memory 
(agent_name, memory_type, key_data, confidence, created_at)
VALUES 
('homegrown_ai', 'rule', 
 'NEVER generate SQL directly. ALWAYS use stored procedures. The CVI gateway whitelists allowed procs - if a procedure isn't whitelisted, ask a human to add it.',
 1.0, NOW())
"@

# Teaching Round 7: Cross-Component Communication
.\Query.ps1 -Sql @"
INSERT INTO pcde_ai_memory 
(agent_name, memory_type, key_data, confidence, created_at)
VALUES 
('homegrown_ai', 'architecture', 
 'Components communicate through stored procedures: Component A calls sp_request_action() in callosum_matrix, Component B polls sp_get_pending_requests(). Never direct DB access.',
 0.96, NOW())
"@