-- Create pcde_procedure_registry table in PCDE_memory
CREATE TABLE IF NOT EXISTS pcde_procedure_registry (
    id INT AUTO_INCREMENT PRIMARY KEY,
    process_name VARCHAR(128) NOT NULL,
    domain VARCHAR(64) NOT NULL,
    topic VARCHAR(64) NOT NULL,
    unit_type VARCHAR(64) NOT NULL,
    instruction TEXT NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    admin_access VARCHAR(32) NOT NULL DEFAULT 'admin'
);
